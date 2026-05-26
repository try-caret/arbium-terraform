# Arbium customer AWS foundation

Terraform root for the customer AWS deployment plan: dedicated VPC, EKS cluster, managed node groups, AWS service VPC endpoints, controlled NAT egress, Aurora PostgreSQL, and Secrets Manager secret containers.

This root intentionally creates AWS primitives only. Helm owns Arbium/ChainDB Kubernetes workloads in later slices.

For the evolving infrastructure topology, see [`docs/topology.md`](docs/topology.md).

## What this creates

- Dedicated VPC across three AZs by default.
- Private subnets for EKS nodes and Aurora.
- Optional public subnets plus NAT gateway egress for non-private-data destinations such as image registry pulls and metadata-only Sentry telemetry.
- VPC endpoints:
  - S3 gateway endpoint.
  - Configurable interface endpoints for STS, Secrets Manager, CloudWatch Logs, ECR, Bedrock Runtime, and Bedrock API where regionally available.
- Dedicated EKS cluster.
- Managed node groups:
  - `general` for app workloads.
  - `embedder-gpu` tainted `workload=embedder:NO_SCHEDULE` for the HTTP embedder. The default instance is `g4dn.xlarge`; move to `g5`/`g6` only if throughput requires it.
- EKS managed add-ons: VPC CNI, CoreDNS, kube-proxy. EBS CSI is deferred until a workload needs persistent volumes and we add a dedicated IRSA role.
- IAM OIDC provider for future IRSA roles.
- Aurora PostgreSQL Serverless v2.
- Secrets Manager secret containers only; secret values are populated out-of-band.
- RDS-managed master user secret for Aurora credentials.

## Usage

```bash
cd infra/aws/customer
terraform init
terraform fmt -recursive
terraform validate
terraform plan -var-file=envs/example.tfvars
```

For a real customer environment, copy `envs/example.tfvars` to an environment-specific tfvars file and adjust values. Do not put secret values in `.tfvars`.

## Secret handling

Terraform creates empty Secrets Manager containers using this naming pattern:

```text
<name_prefix>/<environment>/<secret_name>
```

Default secret names:

- `db`
- `scheduler`
- `scim`
- `sentry`
- `registry`
- `gemini`

Aurora also creates an RDS-managed master user secret. Use that for migration/admin access until least-privilege DB roles are split out.

Operators must populate/rotate secret values outside Terraform so private values do not enter Terraform state, `.tfvars`, or git.

## Notes / current slice boundaries

- Helm chart/workloads are owned outside Terraform.
- Migration execution is still manual/temporary until the migration runner flow is finalized.
- The current install path points app traffic at the Aurora writer endpoint.
- AWS Load Balancer Controller, External Secrets Operator, and NVIDIA device plugin will be installed by Helm/operator flow in later slices unless customer standards require Terraform ownership.
- Endpoint availability varies by region. If a selected endpoint service is unavailable in the target region, remove it from `interface_endpoint_services` in that environment's tfvars.
