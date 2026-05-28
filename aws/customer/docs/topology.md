# Arbium customer AWS topology

This document tracks the current customer AWS deployment topology. Keep it updated when Terraform modules, runtime data paths, or ownership boundaries change.

## Current slice: AWS foundation + Aurora + GPU node path

Environment naming is controlled by Terraform variables:

- `name_prefix`: resource prefix, e.g. `arbium`
- `environment`: environment name, e.g. `customer-qa`
- EKS cluster: `<name_prefix>-<environment>`
- VPC: `<name_prefix>-<environment>`
- Secrets prefix: `<name_prefix>/<environment>/*`

## Ownership boundaries

Terraform owns AWS primitives:

- VPC, subnets, route tables, internet gateway, NAT gateway.
- VPC endpoints for AWS services.
- EKS cluster, managed node groups, core EKS add-ons.
- Aurora PostgreSQL Serverless v2.
- IAM roles needed for EKS/node bootstrap.
- EKS OIDC provider for later IRSA roles.
- Secrets Manager secret containers.
- RDS-managed master user secret for Aurora.
- Optional ACM certificate request and DNS validation record outputs for the customer's DNS provider.

Terraform does **not** own:

- Secret values. Operators populate those out-of-band.
- Arbium/ChainDB Kubernetes workloads. Helm owns those.
- Application migration execution. Driven by the Helm chart (Flyway-based `chaindb-migrate` runs as an initContainer on edge-fns pods and/or as an optional pre-install Helm hook).
- Arbium Ingress/ALB creation. Helm owns the Ingress resource and AWS Load Balancer Controller creates the ALB.
- Final customer app DNS (`chaindb.customer.com -> ALB hostname`), because the ALB hostname exists only after Helm reconciliation.

## Network topology

```text
Internet / operator workstation
  -> optional public EKS API endpoint

VPC: <name_prefix>-<environment> (default 10.81.0.0/16)
  public subnets, one per AZ
    -> Internet Gateway
    -> NAT Gateway (single NAT by default; one per AZ for production)
    -> internet-facing ALB if Helm enables Ingress

  private subnets, one per AZ
    -> EKS managed nodes
    -> Aurora PostgreSQL
    -> S3 Gateway Endpoint via private route tables
    -> Interface Endpoints for AWS APIs
```

Subnet defaults in `envs/example.tfvars`:

- Private subnets: `10.81.0.0/20`, `10.81.16.0/20`, `10.81.32.0/20`
- Public subnets: `10.81.240.0/24`, `10.81.241.0/24`, `10.81.242.0/24`
- NAT: single NAT gateway for cost control in disposable environments.

Production: switch to one NAT gateway per AZ with `single_nat_gateway = false`, and resize VPC/subnet CIDRs to avoid overlap with any existing VPCs you may want to peer with.

## VPC endpoints

The foundation creates an S3 gateway endpoint plus configurable interface endpoints.

Default interface endpoints:

- `sts`
- `secretsmanager`
- `logs`
- `ecr.api`
- `ecr.dkr`
- `bedrock-runtime`
- `bedrock`

Endpoint availability can vary by region. If `terraform apply` fails because a service endpoint does not exist in the chosen region, remove that service name from `interface_endpoint_services` for that environment.

## EKS topology

```text
EKS: <name_prefix>-<environment>
  managed node group: general
    instance types: m6i.large by default
    purpose: edge functions, scheduler jobs, migrations, system add-ons

  managed node group: embedder-gpu
    instance type: g4dn.xlarge by default
    desired size: 0 (keep zero until the account has GPU vCPU quota)
    AMI type: AL2_x86_64_GPU
    label: workload=embedder, nvidia.com/gpu.present=true
    taint: workload=embedder:NO_SCHEDULE
    purpose: GPU-backed HTTP embedder
```

Core EKS add-ons installed by Terraform:

- VPC CNI
- CoreDNS
- kube-proxy

EBS CSI is deferred until a workload needs persistent volumes and we add a dedicated IRSA role for the driver.

Cluster addons installed by `addons.tf` (toggleable):

- AWS Load Balancer Controller (`enable_lb_controller`) — turns the chart's Ingress into an ALB.
- External Secrets Operator (`enable_eso`) — backs the chart's `externalSecrets.enabled=true` path against AWS Secrets Manager.
- NVIDIA Device Plugin (`enable_nvidia_device_plugin`) — required so embedder pods can request `nvidia.com/gpu`.

## Aurora topology

```text
EKS edge-fns pods
  -> Aurora PostgreSQL Serverless v2 writer endpoint
       database: chaindb
       required extensions: vector, pgcrypto, pg_trgm, unaccent, pg_stat_statements
```

Aurora defaults from `envs/example.tfvars`:

- Engine: Aurora PostgreSQL 16.13
- Serverless v2: 0.5-4 ACU
- Instances: 1 writer (`db.serverless`)
- Master password: RDS-managed Secrets Manager secret
- Deletion protection: enabled by default (override per env for disposable QA)
- Final snapshot: required by default (override per env for disposable QA)

Direct Aurora is acceptable for low-traffic environments because edge-fns replicas/concurrency are controlled. RDS Proxy is deferred until a workload needs it.

## Runtime choices

- Bedrock is optional; default is Gemini for `drain-batch` LLM calls.
- GPU embedder uses the EKS `embedder-gpu` managed node group when enabled.
- App traffic uses the direct Aurora writer endpoint.

## Secrets topology

Terraform creates empty Secrets Manager containers only:

- `<name_prefix>/<environment>/db`
- `<name_prefix>/<environment>/scheduler`
- `<name_prefix>/<environment>/scim`
- `<name_prefix>/<environment>/sentry`
- `<name_prefix>/<environment>/registry`
- `<name_prefix>/<environment>/gemini`
- `<name_prefix>/<environment>/enrollment`
- `<name_prefix>/<environment>/jwt`

Aurora also creates an RDS-managed master user secret. Use that secret for migration/admin access until least-privilege DB roles are split out.

Operators populate values outside Terraform. Do not put secret values in:

- `.tfvars`
- Terraform state
- Helm values committed to git
- repo files

## Runtime topology

```text
Arbium client / operator smoke test
  -> chaindb-edge-fns service on EKS
       -> Aurora PostgreSQL writer endpoint
       -> embedder service on EKS GPU node
       -> Gemini API for drain-batch

Kubernetes CronJobs
  -> chaindb-edge-fns /functions/v1 scheduled endpoints
  -> Authorization: Bearer $CHAINDB_SCHEDULER_TOKEN
```

## Operational notes

After Terraform apply completes:

```bash
aws eks update-kubeconfig \
  --profile <profile> \
  --region <region> \
  --name <name_prefix>-<environment>

kubectl get nodes
```

Expected result:

- One or more general nodes.
- Zero or more GPU nodes labeled `workload=embedder,nvidia.com/gpu.present=true` and tainted `workload=embedder:NO_SCHEDULE`.

If nodes do not join, inspect:

```bash
aws eks describe-cluster --profile <profile> --region <region> --name <name_prefix>-<environment>
aws eks list-nodegroups --profile <profile> --region <region> --cluster-name <name_prefix>-<environment>
kubectl get events -A
```

Destroy a disposable environment when no longer needed:

```bash
cd infra/aws/customer
AWS_PROFILE=<profile> terraform destroy -var-file=envs/<environment>.tfvars
```
