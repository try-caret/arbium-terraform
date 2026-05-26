# Arbium customer GCP foundation

Terraform root for the customer GCP deployment plan: dedicated VPC, GKE Standard cluster, managed node pools, Cloud NAT egress, Cloud SQL PostgreSQL with Private Service Access, and Secret Manager secret containers.

This root intentionally creates GCP primitives only. Helm owns Arbium/ChainDB Kubernetes workloads — see `charts/arbium/`.

For the architecture rationale and module layout, see [`PLAN.md`](PLAN.md).
For the evolving topology, see [`docs/topology.md`](docs/topology.md).

## What this creates

- Dedicated VPC with a single regional subnet for nodes plus secondary ranges for pods and services.
- Cloud NAT for controlled outbound egress (registry pulls, Sentry, etc.).
- Private Service Access range for Cloud SQL/AlloyDB private peering.
- Firewall rules: internal VPC traffic, Google LB health checks.
- GKE Standard cluster (private nodes, public endpoint by default) with Workload Identity.
- Node pools:
  - `general` — `e2-standard-2` by default.
  - `embedder-gpu` — `g2-standard-4` with one L4 by default. Tainted `workload=embedder:NoSchedule` and `nvidia.com/gpu=present:NoSchedule`.
- Dedicated GKE node service account with least-privilege roles.
- Cloud SQL PostgreSQL 16 with private IP, automated backups, point-in-time recovery, `cloudsql.enable_pgvector` flag set.
- Random-generated Cloud SQL admin password, stored in a Secret Manager secret.
- Empty Secret Manager secret containers for app secrets.

## Usage

```bash
cd infra/gcp/customer
terraform init
terraform fmt -recursive
terraform validate
terraform plan -var-file=envs/<environment>.tfvars
```

For a real customer environment, copy `envs/example.tfvars` to an untracked file and adjust values. Do not put secret values in `.tfvars`.

## Secret handling

Terraform creates empty Secret Manager containers such as:

- `arbium-<env>-db`
- `arbium-<env>-scheduler`
- `arbium-<env>-scim`
- `arbium-<env>-sentry`
- `arbium-<env>-registry`
- `arbium-<env>-gemini`

Cloud SQL adds:

- `arbium-<env>-cloudsql-admin` — the generated admin password.

Operators populate/rotate app secret values outside Terraform.

## Notes / current slice boundaries

- Helm chart/workloads are owned outside Terraform (`charts/arbium/`).
- Migration execution is still manual/temporary until the migration runner flow is finalized.
- App traffic points at the Cloud SQL private IP. The Cloud SQL admin user is intended for migrations/admin only; least-privilege app roles are a later slice.
- AlloyDB is a one-knob swap if a customer's load requires it; Cloud SQL Postgres is the default for cost.
- pgvector is enabled at the instance level via flag; `CREATE EXTENSION vector;` still needs to run against the target database (migration runner responsibility).
