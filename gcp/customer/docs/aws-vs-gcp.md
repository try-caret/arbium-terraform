# AWS vs GCP — what's different for Arbium

Quick reference for operators familiar with the AWS path who are installing on GCP, and vice versa.

## Resource mapping

| Concept | AWS (`infra/aws/customer`) | GCP (`infra/gcp/customer`) |
|---|---|---|
| Cloud account | AWS account ID | GCP project ID |
| Region | `aws_region` (e.g., `us-east-1`) | `region` (e.g., `us-east1`) — note: no dash before number |
| VPC | `aws_vpc` | `google_compute_network` |
| Subnet | `aws_subnet` × N AZs (per-AZ) | `google_compute_subnetwork` × 1 (regional, spans zones) |
| Pod/Service CIDRs | Carved from subnet | Subnet **secondary ranges** (separate concept) |
| NAT | NAT Gateway per AZ | Single regional Cloud NAT |
| Private DB networking | Private subnet | **Private Service Access** allocation + VPC peering |
| AWS service endpoints | VPC interface endpoints (per service) | **Private Google Access** (subnet flag, all `*.googleapis.com`) |
| Kubernetes | EKS managed | GKE Standard |
| Workload→IAM | IRSA via EKS OIDC provider | **Workload Identity** via `<project>.svc.id.goog` pool |
| Node pool | EKS managed node group | GKE node pool |
| GPU instance | `g4dn.xlarge` (T4) | `g2-standard-4` (L4, default) or `n1-standard-4 + nvidia-tesla-t4` |
| Managed Postgres | Aurora Serverless v2 | Cloud SQL Postgres (default) or AlloyDB |
| Secret store | AWS Secrets Manager | GCP Secret Manager |
| Container registry | ECR | Artifact Registry |
| Load balancer / Ingress | ALB Ingress (`alb` class) | GCE Ingress (`gce` class) or Gateway API |
| Public TLS cert | ACM certificate ARN | Google-managed Certificate (referenced by name) |
| WAF | AWS WAFv2 ACL ARN | Cloud Armor security policy |

## Install command differences

**AWS:**
```bash
cd infra/aws/customer
terraform apply -var-file=envs/<env>.tfvars
aws eks update-kubeconfig --name <cluster> --region us-east-1

helm upgrade --install arbium charts/chaindb \
  --namespace arbium --create-namespace \
  -f charts/chaindb/values-aws.yaml \
  -f charts/chaindb/<env>.values.local.yaml
```

(`helm upgrade --install` here is shown against a local checkout; the customer path is `oci://ghcr.io/try-caret/charts/chaindb --version <release-version>`.)

**GCP:**
```bash
cd infra/gcp/customer
# One-time per project:
gcloud services enable compute container sqladmin servicenetworking \
  secretmanager cloudresourcemanager iam serviceusage --project=<project>

terraform apply -var-file=envs/<env>.tfvars
gcloud container clusters get-credentials <cluster> --region us-east1 --project <project>

helm upgrade --install arbium charts/chaindb \
  --namespace arbium --create-namespace \
  -f charts/chaindb/values-gcp.yaml \
  -f charts/chaindb/<env>.values.local.yaml
```

## Things that work the same

- Chart templates: identical. The Ingress template takes generic `ingress.annotations` and is cloud-agnostic — the preset values file is the only difference.
- DATABASE_URL: same shape (`postgres://user:pw@host:5432/chaindb?sslmode=require`).
- Embedder taint: `workload=embedder:NoSchedule` applies on both clouds. GKE adds an extra `nvidia.com/gpu=present:NoSchedule` taint on GPU nodes; the GCP preset tolerates it.
- ServiceAccount annotations: same template field on both clouds. AWS uses `eks.amazonaws.com/role-arn`, GCP uses `iam.gke.io/gcp-service-account`. Set per environment.
- Migration story: same — manual/deferred runner, common DB target.

## Things that are different

- **GPU type.** AWS default is T4 via `g4dn.xlarge`. GCP default is L4 via `g2-standard-4`. L4 is newer and usually cheaper per token of inference.
- **GPU node taints.** GKE auto-applies `nvidia.com/gpu=present:NoSchedule` in addition to our `workload=embedder` taint; the GCP preset adds the matching toleration.
- **Cloud SQL admin password.** GCP doesn't have RDS's "managed master user secret." We generate a random password in Terraform and write it to a Secret Manager secret. AWS reads the RDS-managed secret directly.
- **Public endpoint authorization.** AWS uses an EKS public-access boolean. GCP uses `master_authorized_networks` (CIDR allow-list). Default in both: public endpoint open in `example.tfvars`, tighten in production.
- **Region naming.** `us-east-1` (AWS) vs `us-east1` (GCP). No dash before the number on GCP.
- **Subnet model.** AWS needs 3 private subnets (one per AZ). GCP needs 1 regional subnet with two secondary ranges (pods, services). Smaller blast radius for CIDR planning on GCP.
- **Quotas.** AWS GPU On-Demand defaults to 0 vCPU and needs a quota increase request. GCP regions ship with 8–16 GPUs per type — usually no quota request needed for a single embedder node.

## When to pick which

- **Customer already on AWS:** use `infra/aws/customer`. The path is mature.
- **Customer on GCP:** use `infra/gcp/customer`. Same Helm chart, GCP preset.
- **Customer multi-cloud or unsure:** stand up on GCP first — Cloud SQL is cheaper than Aurora for the same shape, and GCP GPU quota is friendlier for the embedder. Move to AWS if/when an AWS-anchored customer requires it.
