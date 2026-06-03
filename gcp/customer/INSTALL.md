# Arbium GCP install — operator runbook

End-to-end install of Arbium/ChainDB on a fresh GCP project. Targets
chart **0.1.4+** (cloud-agnostic, GHCR-published, schema migrations as
edge-fns initContainer).

Tested 2026-05-23.

```
terraform → kubectl creds → Secret Manager population → helm install → DNS → wait for cert → smoke
```

Expected total: ~30 min hands-on + ~20 min waiting for Google to issue
the managed cert.

---

## 0. Prerequisites

Local tools:

```bash
brew install terraform kubectl helm
gcloud components install gke-gcloud-auth-plugin   # required by kubectl for GKE
```

GCP-side:

- Project with billing enabled
- APIs enabled (Terraform turns these on, but enable manually first to avoid race conditions on the very first apply):
  - `container.googleapis.com`
  - `sqladmin.googleapis.com`
  - `servicenetworking.googleapis.com`
  - `secretmanager.googleapis.com`
  - `iamcredentials.googleapis.com`
  - `compute.googleapis.com`
- `gcloud auth login` + `gcloud auth application-default login`

GHCR-side: a fine-grained PAT (or classic with `read:packages`) issued by
try-caret for pulling the private container images. Customers receive
this as part of onboarding.

---

## 1. Configure the environment

```bash
cd infra/gcp/customer
cp envs/example.tfvars envs/<environment>.tfvars
```

Edit the copied file. Minimum fields:

```hcl
project_id  = "<gcp-project-id>"
region      = "us-east1"
environment = "<environment>"
name_prefix = "arbium"

# Non-overlapping CIDRs — only matters if multiple envs share a project.
subnet_cidr   = "10.81.0.0/20"
pods_cidr     = "10.84.0.0/14"   # second octet divisible by 4 (/14 boundary)
services_cidr = "10.82.0.0/20"
psa_cidr      = "10.83.0.0/20"

# Tighten in production. Wide-open is for setup convenience only.
master_authorized_networks = [
  { cidr = "0.0.0.0/0", display_name = "all" },
]

# Use e2-standard-2 or larger — CPU embedder needs ~1.5GB headroom for
# ONNX, which doesn't fit alongside kubelet on e2-small (2GB total).
general_node_machine_type = "e2-standard-2"
general_node_min_size     = 1
general_node_max_size     = 3

# GPU node pool for the GPU embedder variant. Set _enabled=false if your
# account has no GPU quota or you'll run the CPU embedder.
gpu_node_enabled           = true
gpu_node_machine_type      = "g2-standard-4"
gpu_node_accelerator_type  = "nvidia-l4"
gpu_node_accelerator_count = 1
gpu_node_min_size          = 0
gpu_node_max_size          = 1

# Cloud SQL. db-custom-1-3840 is enough for ~50 captures/min.
cloudsql_tier                  = "db-custom-1-3840"
cloudsql_availability_type     = "ZONAL"   # REGIONAL for HA in production
cloudsql_deletion_protection   = true
```

**Do not put secret values in tfvars** — Terraform will create empty
secret containers; you populate them in step 4.

---

## 2. Provision infrastructure

```bash
terraform init
terraform plan -var-file=envs/<environment>.tfvars
terraform apply -var-file=envs/<environment>.tfvars
```

Takes 8-15 min. Creates: VPC, GKE cluster, Cloud SQL Postgres 16
instance, Secret Manager containers, GSAs for Workload Identity, static
external IP for the Ingress.

Grab the outputs you'll need next:

```bash
terraform output
```

Key ones:

- `cluster_name` → GKE cluster name
- `cluster_endpoint` → GKE API endpoint
- `cloudsql_connection_name` → `<project>:<region>:<instance>` form
- `cloudsql_proxy_service_account_email` → GSA for the Cloud SQL Auth Proxy KSA
- `eso_service_account_email` → GSA for the External Secrets KSA
- `secrets` → map of `{name → projects/<id>/secrets/<full-name>}`
- `ingress_static_ip_name` → name to set in chart's ingress.global-static-ip-name
- `ingress_static_ip_address` → IPv4 — customer DNS A-record target

---

## 3. Configure kubectl

```bash
gcloud container clusters get-credentials <cluster_name> \
  --region <region> \
  --project <project_id>
kubectl get nodes
```

Expected: 1-3 general nodes + (if GPU pool enabled and scaled) 1 GPU
node with `nvidia.com/gpu` resources.

---

## 4. Populate Secret Manager values

Terraform created empty secret containers. Fill them:

```bash
# DB URL (Cloud SQL Auth Proxy lives in-cluster — chart-managed Deployment)
DB_PW=$(gcloud secrets versions access latest \
  --secret=arbium-<env>-cloudsql-admin --project=<project_id>)
DB_PW_ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1], safe=''))" "$DB_PW")
printf '%s' "postgres://chaindb_admin:${DB_PW_ENC}@arbium-cloud-sql-proxy.arbium.svc.cluster.local:5432/chaindb?sslmode=disable" | \
  gcloud secrets versions add arbium-<env>-db --data-file=- --project=<project_id>

# Random shared secrets
printf '%s' "$(openssl rand -hex 32)" | gcloud secrets versions add arbium-<env>-scheduler  --data-file=- --project=<project_id>
printf '%s' "$(openssl rand -hex 32)" | gcloud secrets versions add arbium-<env>-enrollment --data-file=- --project=<project_id>
printf '%s' "$(openssl rand -hex 32)" | gcloud secrets versions add arbium-<env>-jwt        --data-file=- --project=<project_id>

# Provider keys and license
printf '%s' "<gemini-api-key>" | gcloud secrets versions add arbium-<env>-gemini --data-file=- --project=<project_id>
printf '%s' "<signed-arbium-license-key>" | gcloud secrets versions add arbium-<env>-license --data-file=- --project=<project_id>
```

### Why `sslmode=disable` on the DB URL is the secure default

The connection path is:

```
edge-fns pod  --(plain TCP, pod-to-pod)-->  Cloud SQL Auth Proxy  --(TLS w/ Google CA)-->  Cloud SQL
```

- The **Cloud SQL Auth Proxy** is Google's recommended TLS termination
  point. The proxy-to-Cloud-SQL leg is *always* TLS with Google's
  managed CA chain, authenticated via Workload Identity — no DB password
  on the wire to Cloud SQL.
- The **pod-to-proxy leg** is plain TCP at the application layer, but
  GCP encrypts all intra-DC traffic at the physical network layer
  (Google's standard infrastructure-level encryption). The bytes are
  still encrypted on the wire; the app just doesn't see/control it
  at L7.
- This matches the [Cloud SQL Auth Proxy documented pattern](https://cloud.google.com/sql/docs/postgres/sql-proxy)
  and satisfies SOC2 / HIPAA / PCI's "encryption in transit" controls
  via Google's infrastructure-level encryption attestation.

If you want explicit TLS on the pod-to-proxy leg too (cosmetic — no
real security delta), the proxy can be configured to expose TLS;
override the chart's `cloudSqlProxy` args. Not recommended — adds
complexity for no audit win that Google's infra doesn't already
provide.

---

## 5. Install External Secrets Operator (one-time per cluster)

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --wait
```

The chart's `externalSecrets.enabled=true` (default) pulls values from
Secret Manager via Workload Identity into a Kubernetes Secret. Terraform
already created the GSA + IAM binding; ESO just needs the controller
running.

---

## 6. Create the GHCR pull secret

The Arbium images live in private GHCR. Customers receive a token from
try-caret out of band — typically a fine-grained PAT with `Resource
owner: try-caret + Organization permissions: Packages: Read`.

```bash
kubectl create namespace arbium-precreate-skip 2>/dev/null || true
# DON'T pre-create the arbium namespace — helm install --create-namespace
# adopts it. Pre-creating breaks Helm ownership.

# Create the pull secret in a temp namespace, then copy it into arbium
# after helm install creates that namespace. OR set --set-string
# imagePullSecrets via helm — but the secret has to land in `arbium`
# specifically. Cleanest pattern: create the secret with `--namespace
# arbium --dry-run=client -o yaml` AFTER helm install creates the ns.
```

Better path — do this AFTER step 8 finishes creating the namespace:

```bash
kubectl create secret docker-registry ghcr-pull \
  --namespace arbium \
  --docker-server=ghcr.io \
  --docker-username=<bot-user> \
  --docker-password=<paste-token-here> \
  --docker-email=<your-email>
```

---

## 7. Write customer values

```bash
cat > <environment>.values.local.yaml <<EOF
global:
  namespace: arbium
  environment: <environment>
  region: <region>

# References the pull secret you'll create in step 8.
imagePullSecrets:
  - name: ghcr-pull

# Cloud SQL Auth Proxy: chart-managed Deployment that bridges pod-CIDR
# isolation in PSA peering.
cloudSqlProxy:
  enabled: true
  connectionName: "<cloudsql_connection_name>"

serviceAccount:
  cloudSqlProxy:
    annotations:
      iam.gke.io/gcp-service-account: "<cloudsql_proxy_service_account_email>"

# External Secrets pulls from GCP Secret Manager via Workload Identity.
externalSecrets:
  enabled: true
  provider: gcpsm
  projectID: "<project_id>"
  clusterLocation: "<region>"
  clusterName: "<cluster_name>"
  serviceAccount:
    annotations:
      iam.gke.io/gcp-service-account: "<eso_service_account_email>"
  dataMappings:
    DATABASE_URL:                       arbium-<env>-db
    SUPABASE_DB_URL:                    arbium-<env>-db
    CHAINDB_SCHEDULER_TOKEN:            arbium-<env>-scheduler
    ARBOR_AGENT_ENROLLMENT_SECRET:      arbium-<env>-enrollment
    ROOTS_INTUNE_PILOT_ENROLLMENT_SECRET: arbium-<env>-enrollment
    GEMINI_API_KEY:                     arbium-<env>-gemini
    JWT_SECRET:                         arbium-<env>-jwt
    ARBIUM_LICENSE_KEY:                 arbium-<env>-license

secrets:
  create: false
  existingSecret: chaindb-runtime

license:
  existingSecret: arbium-runtime

# Embedder: GPU recommended in production; chart can also do CPU.
embedder:
  enabled: true
  gpu:
    enabled: true   # uses the embedder-gpu image on the GPU node pool

# Ingress + Google-managed TLS at your real domain.
ingress:
  enabled: true
  className: gce
  host: chaindb.<customer>.com
  annotations:
    kubernetes.io/ingress.class: gce
    kubernetes.io/ingress.global-static-ip-name: <ingress_static_ip_name>
    networking.gke.io/managed-certificates: chaindb-tls
    # Flip to "false" after ManagedCert flips to Active.
    kubernetes.io/ingress.allow-http: "true"

tls:
  managedCertificate:
    enabled: true
    name: chaindb-tls
    domains:
      - chaindb.<customer>.com

config:
  databaseSsl: disable   # Cloud SQL Auth Proxy hop is plain TCP inside cluster
  edgeFnsAnonKey: self-host-local
  verifyJwt: "false"
EOF
```

---

## 8. Install the chart

```bash
helm install arbium oci://ghcr.io/try-caret/charts/chaindb \
  --version <release-version> \
  --namespace arbium \
  --create-namespace \
  --values charts/chaindb/values-gcp.yaml \
  --values <environment>.values.local.yaml \
  --timeout 15m \
  --wait
```

`--create-namespace` is **required** on first install — chart owns the
namespace via labels/annotations. If you pre-created it with `kubectl
create namespace arbium`, install fails with `invalid ownership
metadata`.

`--timeout 15m` accommodates cold node pool spin-up + image pulls.

After helm install completes, immediately create the pull secret
(referenced by `imagePullSecrets` in your values):

```bash
kubectl create secret docker-registry ghcr-pull \
  --namespace arbium \
  --docker-server=ghcr.io \
  --docker-username=<bot-user> \
  --docker-password=<paste-token> \
  --docker-email=<your-email>

# Bounce any pods that started before the secret existed:
kubectl delete pod -n arbium --all
```

---

## 9. Point DNS

Add a single A record at your DNS provider:

| Type | Name | Value |
|---|---|---|
| A | `chaindb.<customer>.com` | `<ingress_static_ip_address>` |

Confirm propagation:

```bash
dig +short chaindb.<customer>.com @8.8.8.8
# should return the static IP
```

---

## 10. Wait for ManagedCertificate

Google won't issue the cert until DNS resolves to the static IP. Then
issuance takes 10-60 min.

```bash
kubectl get managedcertificate -n arbium -w
# wait for STATUS column to flip from Provisioning → Active
```

Once Active, lock down HTTP:

```bash
kubectl annotate ingress arbium -n arbium \
  kubernetes.io/ingress.allow-http=false --overwrite
```

---

## 11. Smoke test

```bash
# Pull the enrollment secret you stored
ENROLL=$(gcloud secrets versions access latest --secret=arbium-<env>-enrollment --project=<project_id>)

# Enroll a smoke user + get a bearer token
EMAIL="smoke+$(date +%s)@<customer>.local"
ENROLL_JSON=$(curl -fsS -X POST "https://chaindb.<customer>.com/functions/v1/agent-enroll" \
  -H "Authorization: Bearer $ENROLL" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"label\":\"smoke\"}")
TOKEN=$(echo "$ENROLL_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['token'])")

# Post a single capture
NOW_MS=$(($(date +%s) * 1000))
curl -fsS -X POST "https://chaindb.<customer>.com/functions/v1/captures-batch-direct" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "[{\"id\":\"$(uuidgen | tr A-Z a-z)\",\"timestamp\":$NOW_MS,\"appName\":\"smoke\",\"windowKey\":\"smoke\",\"windowTitle\":null,\"eventType\":null,\"eventText\":\"hello\",\"diffText\":\"hello\",\"treeText\":null,\"stateSource\":\"diff\"}]"
# Expected: {"inserted":1,"assigned":1,...}
```

If you see `inserted:1`, the full pipeline is up: edge-fns ingest →
embedder → Cloud SQL → episode assignment.

---

## Common failures

### Helm install times out

Don't panic — gather diagnostic before retrying:

```bash
kubectl get pods,events -n arbium --sort-by='.lastTimestamp' | tail -30
kubectl logs -n arbium -l app.kubernetes.io/component=edge-fns --tail=50
```

Common causes:

- Embedder OOM on small nodes → bump general pool to e2-standard-2+
- Image pull 401 → forgot the GHCR pull secret in step 8
- `chaindb-runtime` Secret not synced yet → wait 30-60s for ESO to
  materialize from Secret Manager

### `relation "auth.users" does not exist`

Pre-0.1.2 bug, fixed via initContainer. If you see this on a current
chart, the edge-fns image didn't get the new initContainer — check that
`image.edgeFns.tag` resolves to a version ≥ 0.1.2.

### ManagedCertificate stuck at Provisioning

```bash
kubectl describe managedcertificate -n arbium chaindb-tls
```

If `FailedNotVisible`: DNS hasn't propagated yet, or you set the wrong
record. The static IP from terraform output must match exactly.

### Pull-secret docs

For the per-customer PAT-issuance pattern: try-caret issues fine-grained
PATs scoped to `try-caret` org with `Packages: Read`. If fine-grained
isn't enabled at the org level, classic PAT with `read:packages` works
too.

---

## Upgrading the chart

```bash
helm upgrade arbium oci://ghcr.io/try-caret/charts/chaindb \
  --version <new-release-version> \
  --namespace arbium \
  --values charts/chaindb/values-gcp.yaml \
  --values <environment>.values.local.yaml \
  --wait
```

Migrations run automatically on the next edge-fns pod rollout (via
initContainer). For chart-version changelog see `charts/chaindb/Chart.yaml`.

---

## Destroy disposable environments

```bash
helm uninstall arbium -n arbium
kubectl delete namespace arbium

# Drop the DB before terraform destroy — terraform can't delete the
# chaindb_admin user while objects still depend on it.
gcloud sql databases delete chaindb \
  --instance=<cloudsql_instance_name> \
  --project=<project_id> --quiet

cd infra/gcp/customer
terraform destroy -var-file=envs/<environment>.tfvars
```

---

## Operational gotchas (read once before first install)

These are platform behaviors, not bugs — knowing them avoids head-scratching.

### `helm install --wait` can leave the release stuck on first-install timeout

If `--wait` exceeds `--timeout` because a pod is slow, helm leaves the
release in `pending-install` and `helm upgrade` errors with `another
operation in progress`. Two fixes:

```bash
# Option A — drop --wait from the install command, then wait separately:
helm install arbium oci://ghcr.io/try-caret/charts/chaindb ...
kubectl wait deployment -n arbium --for=condition=available --timeout=15m --all

# Option B — patch the stuck release secret status to "failed":
python3 -c "
import base64, gzip, json, subprocess
data = subprocess.run(['kubectl','--kubeconfig=...','-n','arbium','get','secret',
  'sh.helm.release.v1.arbium.v1','-o','jsonpath={.data.release}'],
  capture_output=True, text=True).stdout
obj = json.loads(gzip.decompress(base64.b64decode(base64.b64decode(data))))
obj['info']['status'] = 'failed'
enc = base64.b64encode(base64.b64encode(gzip.compress(json.dumps(obj).encode())).encode()).decode()
subprocess.run(['kubectl','-n','arbium','patch','secret','sh.helm.release.v1.arbium.v1',
  '--type=json','-p',f'[{{\"op\":\"replace\",\"path\":\"/data/release\",\"value\":\"{enc}\"}}]'])
"
```

### GCE LB returns `Connection reset` for ~5-10 min after Ingress creation

The LB takes minutes to fully warm even after `gcloud compute backend-services
get-health` shows HEALTHY. Just wait. Retry the curl after 5 min.

### ManagedCertificate CRD lags the actual GCP cert by several minutes

`kubectl get managedcertificate -o yaml` may show `Provisioning` even after
HTTPS works. Authoritative source:

```bash
gcloud compute ssl-certificates describe <name> --global \
  --format='value(managed.status,managed.domainStatus)'
```

### Re-pushing the same image tag doesn't restart existing pods

Even with `pullPolicy: Always`, only NEW pods pull fresh. After re-pushing
a same-tag image:

```bash
kubectl rollout restart deployment/chaindb-edge-fns -n arbium
```

Better: bump the image tag (chart 0.1.4 → 0.1.5) so every restart guarantees
fresh content.
