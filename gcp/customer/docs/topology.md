# Arbium customer GCP topology

This document tracks the current customer GCP deployment topology. Keep it updated when Terraform modules, runtime data paths, or ownership boundaries change.

## Current slice: GCP foundation + Cloud SQL + optional GPU node path

## Ownership boundaries

Terraform owns GCP primitives:

- VPC, subnet, Cloud NAT, firewall rules.
- Private Service Access allocation + service networking peering.
- GKE cluster, node pools, addons.
- IAM service accounts needed for GKE/node bootstrap.
- Workload Identity pool binding at the cluster level.
- Cloud SQL PostgreSQL instance, database, admin user.
- Secret Manager secret containers (app secrets and Cloud SQL admin password).

Terraform does **not** own:

- Secret *values*. Operators populate those out-of-band.
- Arbium/ChainDB Kubernetes workloads. Helm owns those.
- Application migration execution. The migration runner flow is still being finalized.
- Customer DNS / managed SSL behavior beyond optionally exporting a load balancer address.

## Network topology

```text
Internet / operator workstation
  -> Public GKE API endpoint (restricted by master_authorized_networks)

VPC: arbium-<env>
  Subnet: arbium-<env>-nodes (regional, in <region>)
    Primary CIDR for node IPs
    Secondary range: pods
    Secondary range: services
    Private Google Access: enabled

  Cloud NAT (regional)
    -> outbound egress for private nodes (image pulls, Sentry, etc.)

  Private Service Access peering (servicenetworking.googleapis.com)
    -> Cloud SQL private IP
```

Defaults:

- Subnet (nodes): `10.81.0.0/20`
- Pods: `10.84.0.0/14`
- Services: `10.82.0.0/20`
- PSA: `10.83.0.0/20`

GCP subnets are regional, not per-AZ. One subnet covers all zones in the region.

## Cloud NAT

A single regional Cloud NAT serves the whole VPC. It logs errors only by default. Cost is roughly $0.045/hr plus per-GB egress.

## Private Service Access

A `/20` global address allocation is reserved for service-producer peering. This is the range Cloud SQL (and AlloyDB, if swapped in) draws private IPs from. Existing-range collisions are the common reason apply fails the first time on an account that has used PSA before — adjust `psa_cidr` per environment.

## GKE topology

```text
GKE: arbium-<env>
  Type: Standard, regional
  Endpoint: public (restricted) + private
  Workload Identity pool: <project>.svc.id.goog
  Release channel: REGULAR

  Node pool: general
    Machine type: e2-standard-2 (default)
    Autoscaling: 1..3 per zone
    Purpose: edge functions, scheduler jobs, migrations, system add-ons

  Node pool: embedder-gpu (optional)
    Machine type: g2-standard-4
    Accelerator: 1x nvidia-l4
    Autoscaling: 0..1 per zone
    Taints:
      workload=embedder:NoSchedule
      nvidia.com/gpu=present:NoSchedule
    Purpose: GPU-backed HTTP embedder
```

Addons installed:

- HTTP load balancing
- Horizontal Pod Autoscaling
- GCE persistent disk CSI driver

Other addons (Filestore CSI, etc.) are off by default. Enable per environment if needed.

Workload Identity is enabled cluster-wide, which is the GCP equivalent of AWS IRSA. Pods bind to a GCP service account via a KSA annotation:

```yaml
serviceAccount:
  edgeFns:
    annotations:
      iam.gke.io/gcp-service-account: arbium-edgefns@<project>.iam.gserviceaccount.com
```

The chart already takes ServiceAccount annotations as values, so no chart change is required.

## Cloud SQL topology

```text
GKE pods (general pool)
  -> Cloud SQL Postgres 16 private IP (peered via PSA)
       database: chaindb
       admin user: chaindb_admin (password in Secret Manager)
       pgvector flag enabled at instance level
```

Defaults:

- Engine: PostgreSQL 16
- Tier: `db-custom-2-7680` (2 vCPU, 7.5 GB)
- Availability: ZONAL (single-zone). Switch to REGIONAL for HA.
- Storage: 20 GB SSD, autoresize up to 200 GB.
- Backups: nightly, 7-day retention, point-in-time recovery enabled.
- Maintenance: Sundays 08:00 region time.

The instance is created with a random 4-character suffix (e.g. `arbium-prod-pg-a1b2`) because Cloud SQL reserves deleted instance names for 7 days; the suffix lets apply/destroy/apply cycles work without collisions.

## Secrets topology

Terraform creates empty Secret Manager containers:

- `arbium-<env>-db`
- `arbium-<env>-scheduler`
- `arbium-<env>-scim`
- `arbium-<env>-sentry`
- `arbium-<env>-registry`
- `arbium-<env>-gemini`

Cloud SQL also creates a master-password secret:

- `arbium-<env>-cloudsql-admin`

Operators populate values out of band:

```bash
echo -n "<value>" | gcloud secrets versions add \
  arbium-<env>-<name> --data-file=- --project=<project-id>
```

Do not put secret values in `.tfvars`, Terraform state, committed Helm values, or anywhere in the repo.

## Runtime topology

```text
Arbium client / operator smoke test
  -> arbium-edge-fns service on GKE
       -> Cloud SQL Postgres private IP
       -> arbium-embedder service on GKE GPU node pool
       -> Gemini API for drain-batch (until Bedrock/Vertex AI swap)

Kubernetes CronJobs
  -> arbium-edge-fns /functions/v1 scheduled endpoints
  -> Authorization: Bearer $CHAINDB_SCHEDULER_TOKEN
```

## Operational notes

After Terraform apply completes:

```bash
gcloud container clusters get-credentials \
  $(terraform output -raw cluster_name) \
  --region <region> \
  --project <project-id>

kubectl get nodes
```

Expected result:

- One or more general nodes.
- One GPU node only if `gpu_node_enabled = true` and quota is available.

Destroy the environment when no longer needed:

```bash
cd infra/gcp/customer
terraform destroy -var-file=envs/<environment>.tfvars
```
