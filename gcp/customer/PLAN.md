# Arbium customer GCP foundation — plan

Sibling of `infra/aws/customer/`. This is the GCP port of the AWS customer foundation.

## Goal

Stand up a clean, repeatable GCP foundation that the same `charts/chaindb` Helm chart can install onto, with the same ownership boundaries as the AWS path: Terraform owns cloud primitives, Helm owns Kubernetes workloads, secret values are populated out-of-band.

## Architecture decisions (defaults — overridable per environment)

| Decision | Choice | Rationale |
|---|---|---|
| Cluster | **GKE Standard** (not Autopilot) | Closer mental model to EKS — explicit node pools, GPU pool, taints. Customers porting from EKS-shaped runbooks have an easier time. Autopilot is a reasonable upgrade later. |
| Database | **Cloud SQL PostgreSQL 16** (not AlloyDB) | Cost-conscious default. AlloyDB ≈ Aurora-Serverless-v2 ergonomics but ~3–4× the price. Cloud SQL Postgres supports pgvector since 2023, fine for ChainDB. AlloyDB is a one-tfvars-knob swap if a customer's load needs it. |
| GPU | **L4 via `g2-standard-4`** | L4 outperforms T4 on transformer inference for similar/lower price. Drop-in replaceable with `n1-standard-4 + nvidia-tesla-t4` if a region lacks L4. |
| Network | **Custom-mode VPC, one regional subnet** | GCP subnets span all zones in a region — much simpler than AWS's per-AZ private subnets. One subnet with secondary ranges for pods+services keeps the design clean. |
| Egress | **Cloud NAT** | Equivalent of AWS NAT Gateway. One Cloud NAT per region serves the whole VPC. |
| Cloud SQL networking | **Private IP only, via Private Service Access** | Matches AWS's private-subnet-only Aurora. Customer apps reach DB via VPC peering; no public surface. |
| GKE API endpoint | **Public endpoint + master authorized networks** | Matches AWS pattern of public EKS endpoint with auth network ranges. Customers can flip to fully-private endpoint via `cluster_endpoint_public_access = false`. |
| Workload identity | **Enabled cluster-wide** | GCP equivalent of IRSA. Pods bind to GSAs via KSA annotations. Same chart serviceAccount.annotations seam works. |
| Secrets | **Secret Manager**, containers only | Operators populate values out-of-band. Same pattern as AWS Secrets Manager. |
| State backend | **Local for now** | When productionizing, swap to GCS backend with versioning + state locking via GCS object versioning (Terraform 1.10+) or a Firestore-backed locker. |
| Region | **us-east1** by default | Co-locates with existing GCS buckets (`chaindb-replay-snapshots`, etc.). |

## Module layout

```
infra/gcp/customer/
├── README.md
├── INSTALL.md
├── PLAN.md                   # this file
├── main.tf                   # wires modules
├── variables.tf              # every knob
├── outputs.tf
├── providers.tf              # google + google-beta + tls
├── versions.tf
├── docs/
│   └── topology.md           # network/GKE/Cloud SQL diagram
├── envs/
│   ├── example.tfvars
│   └── test.tfvars           # tiny throwaway env for live testing
└── modules/
    ├── network/              # VPC, subnet, Cloud NAT, PSA, FW rules
    ├── gke/                  # Cluster, general + GPU node pools, WI
    ├── cloudsql/             # Postgres 16 private-IP
    └── secrets/              # Secret Manager containers
```

## Ownership boundaries (same as AWS path)

Terraform owns:
- VPC, subnet, Cloud NAT, firewall rules, Private Service Access allocation
- GKE cluster, node pools, addons
- IAM service accounts for GKE nodes
- Workload Identity binding *infrastructure* (the GSAs themselves; KSA bindings are values on the chart)
- Cloud SQL instance, database, master user
- Secret Manager secret containers

Terraform does **not** own:
- Secret values (operators populate out-of-band)
- Kubernetes workloads — Helm owns those
- Application DB migrations — same runner story as AWS
- Customer DNS / managed SSL beyond optionally exporting an address

## Mapping AWS → GCP

| AWS | GCP |
|---|---|
| VPC + per-AZ subnets | VPC + regional subnet w/ pod/service secondary ranges |
| Internet Gateway | Implicit (default route to default-internet-gateway) |
| NAT Gateway (per AZ or single) | Cloud NAT (one per region) |
| S3 Gateway Endpoint + interface endpoints | Private Google Access (enables `*.googleapis.com` over private IPs without external traffic) |
| Aurora Serverless v2 (private) | Cloud SQL Postgres 16 (private IP via Private Service Access) |
| EKS managed node group `general` | GKE node pool `general` with autoscaling |
| EKS managed node group `embedder-gpu` (g4dn, taint workload=embedder:NoSchedule) | GKE node pool `embedder-gpu` (g2-standard-4 / L4, taint nvidia.com/gpu=present:NoSchedule + workload=embedder:NoSchedule) |
| EKS OIDC + IRSA | GKE Workload Identity (`<project>.svc.id.goog`) |
| Secrets Manager containers | Secret Manager containers |
| RDS-managed master user secret | Cloud SQL auto-stored password (we mirror by writing initial password into Secret Manager) |

## What I'm testing today (with $ in mind)

To validate the Terraform actually works against live GCP, I'll apply a tiny `envs/test.tfvars`:

- VPC + subnet + Cloud NAT — cheap (~$0.045/hr Cloud NAT)
- Cloud SQL **`db-f1-micro`** shared-CPU tier — ~$0.015/hr
- GKE Standard cluster with **1× `e2-small` node** in the `general` pool — ~$0.10/hr control plane + ~$0.017/hr node
- **GPU node pool desired = 0** — avoid GPU quota concerns + cost during testing
- 6 Secret Manager containers — free at this scale

Estimated test burn: ~**$0.20/hr**. I'll destroy at the end.

## Test run outcome (2026-05-22)

Full apply + verification + destroy executed against `chaindb-494009` — including four real bugs caught and fixed in-tree.

Headline:
- **28 resources** deployed cleanly after fixes.
- GKE control plane up in 8m59s, general node pool up in 1m34s.
- Cloud SQL Postgres 16 RUNNABLE, private IP `10.103.0.3` in the PSA peering range.
- `helm install --dry-run=server` of the Arbium chart against the live GKE cluster **passed** with the GCP preset.
- Cluster passed `kubectl get nodes` with 3 healthy `e2-small` nodes across 3 zones.

## Out of scope for today

- Configuring an actual customer environment (no real ACM/managed-cert wiring).
- Helm chart preset files (`values-gcp.yaml`) — separate change, doesn't block this.
- GCS Terraform state backend — local state for this proof.
- IAP-only bastion or fully-private GKE endpoint — flippable via variables.
- Cloud Armor + GCP-side WAF — flippable later.

## Open questions to revisit after testing

- Whether to enable Workload Identity Federation for the Terraform service account itself (cleaner than user creds for CI).
- Whether to enable Anthos Service Mesh / Cloud DNS for kubectl convenience.
- Whether to ship pgvector enablement as a Terraform `null_resource` or leave to migrations.
