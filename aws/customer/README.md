# Arbium customer AWS foundation

Terraform root for the customer AWS deployment plan: dedicated (or customer-supplied) VPC, EKS cluster, managed node groups, AWS service VPC endpoints, controlled NAT egress, Aurora PostgreSQL, Secrets Manager secret containers, and an optional Terraform-managed public hosted zone + ACM certificate for the Arbium HTTPS ingress.

This root owns the AWS foundation and its Kubernetes controllers. The separate
application Helm release owns Arbium/ChainDB workloads.

See [`INSTALL.md`](INSTALL.md) for the end-to-end install runbook, including the staged DNS workflow (validate the certificate through the customer's authoritative DNS → install the chart → apply the ALB alias → customer delegates the parent domain).

## What this creates

Two network modes, selected per environment:

- **Created network (default):** dedicated VPC across three AZs, private subnets for EKS nodes and Aurora, optional public subnets plus NAT gateway egress, and VPC endpoints (S3 gateway; configurable interface endpoints for STS, Secrets Manager, CloudWatch Logs, ECR, Bedrock Runtime, and Bedrock API where regionally available).
- **Customer-supplied network:** set `existing_network = { vpc_id, private_subnet_ids, public_subnet_ids }` to reference a VPC the customer owns. Terraform validates and reads it — it never creates, imports, retags, or manages its lifecycle. Requires ≥2 private subnets in distinct AZs with VPC DNS support enabled, and public subnets when ingress is internet-facing.

Regardless of network mode:
- Dedicated EKS cluster.
- Managed node groups:
  - `general` for app workloads.
  - `embedder-gpu` tainted `workload=embedder:NO_SCHEDULE` for the HTTP embedder. The default instance is `g4dn.xlarge`; move to `g5`/`g6` only if throughput requires it.
- EKS managed add-ons: VPC CNI, CoreDNS, kube-proxy. EBS CSI is deferred until a workload needs persistent volumes and we add a dedicated IRSA role.
- IAM OIDC provider and workload/controller IRSA roles.
- Aurora PostgreSQL Serverless v2.
- Secrets Manager secret containers only; secret values are populated out-of-band.
- RDS-managed master user secret for Aurora credentials.
- Optional ACM certificate request for the Arbium HTTPS ingress, with DNS validation records output for the customer's DNS provider.

## Usage

State is in S3, one key per environment. The mirror does not ship a
`backend.tf` (it is deployment-specific) — create one at the root, e.g.:

```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket       = "<your-terraform-state-bucket>"
    key          = "aws/customer/<env>/terraform.tfstate"
    region       = "<aws_region>"
    encrypt      = true
    use_lockfile = true
  }
}
```

```bash
cd /path/to/checkout/aws/customer  # internal checkout: infra/aws/customer
terraform init -reconfigure
terraform fmt -recursive
terraform validate
terraform plan -var-file=<your-env>.tfvars
```

Keep environment tfvars and any backend config outside the mirror (they are
excluded from it by design — `*.tfvars`, `backend.tf`, per-deployment state
configs). Do not put secret values in `.tfvars`.

Application Helm values are likewise a per-deployment, out-of-repo file: the
chart is installed from the pinned published release
(`oci://ghcr.io/try-caret/charts/chaindb`, currently **0.6.8**) with the
packaged cloud preset (e.g. the chart's `values-aws.yaml`, obtained via
`helm pull`) plus your local values layered on top.

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
- `enrollment`
- `jwt`

Aurora also creates an RDS-managed master user secret. Use that for migration/admin access until least-privilege DB roles are split out.

Operators must populate/rotate secret values outside Terraform so private values do not enter Terraform state, `.tfvars`, or git.

## Notes / current slice boundaries

- Helm chart/workloads are owned outside Terraform. Application DNS is staged: certificate validation CNAME at the authoritative DNS → chart install → final ALB alias (Terraform-managed zone or the customer's DNS provider) → customer-controlled parent delegation. No existing application record or delegation is ever changed by this root.
- Ingress scheme defaults to `internet-facing`; for internal ingress, set both Terraform `ingress_scheme = "internal"` and chart `ingress.scheme: internal`.
- Fresh schema bootstrap uses the published migrations image; chart initContainers use the same canonical migrations on rollout.
- The current install path points app traffic at the Aurora writer endpoint.
- AWS Load Balancer Controller, External Secrets Operator, and NVIDIA device plugin are installed by Terraform by default and can be disabled for customer-managed equivalents.
- Optional ACM certificate request for the Arbium HTTPS ingress, with DNS validation records output for the customer's DNS provider.
- Optional Terraform-managed public hosted zone (`create_public_hosted_zone`, requires the certificate), owning the zone, its validation record, and the final application ALB alias. Outputs `ingress_zone_id` and the AWS-assigned `ingress_zone_name_servers` — the parent-domain delegation itself remains a customer action. Off by default: existing environments see no DNS additions.
- In created-network mode, endpoint availability varies by region. Remove unavailable services from `interface_endpoint_services`. In supplied-network mode, endpoints remain entirely customer-owned.
- Local regression checks: see [`tests/README.md`](tests/README.md).
