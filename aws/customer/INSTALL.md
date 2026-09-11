# Arbium AWS install — operator runbook

End-to-end install of Arbium/ChainDB on a fresh AWS account — created network
or customer-owned ("bring-your-own") network.

```
terraform foundation → ACM cert validation (customer DNS + optional TF zone) →
namespace + secrets + in-cluster DB bootstrap → preflight → helm install →
ALB alias → smoke + SCIM provisioning
```

Expected total: ~45 min hands-on + ~10-30 min waiting on Aurora cluster
instance + ACM validation.

## Paths used throughout

Everything is referenced through three variables — set them once per shell and
the commands below work from any directory:

```bash
# 1. Terraform root (this repository's infra/aws/customer directory; the
#    public arbium-terraform mirror has this content under aws/customer).
TFROOT=/path/to/terraform/checkout/infra/aws/customer

# 2. The PINNED published chart, extracted from OCI — do not mix in a local
#    checkout that may not match the release:
umask 077
DEPLOY_DIR=$(mktemp -d)   # keep this path for the duration of the deployment
cd "$DEPLOY_DIR"
helm pull oci://ghcr.io/try-caret/charts/chaindb --version 0.6.8
mkdir -p chart-0.6.8 && tar -xzf chaindb-0.6.8.tgz -C chart-0.6.8
CHART_DIR=$PWD/chart-0.6.8/chaindb

# 3. YOUR runtime values file — a local file, not a file from this repo
#    (fill it from terraform outputs in step 5; never commit it).
VALUES="$PWD/env.values.local.yaml"
```

## Workflow order matters

The DNS workflow is staged on purpose. The application's ALB only exists after
Helm, and the certificate only validates through DNS that is already
authoritative. Do not try to collapse the stages:

1. **Terraform foundation** (network, EKS, Aurora, controllers) and, if
   opted in, the public hosted zone + ACM certificate request.
2. **Publish the certificate validation CNAME** in the domain's authoritative
   zone (the customer's DNS provider). If Terraform also manages the new
   hosted zone (`create_public_hosted_zone = true`), it creates the same
   validation record in the new zone too — that preserves certificate renewal
   after the parent domain is later delegated to the new zone. Wait for ACM
   `ISSUED`.
3. **Create the namespace, Kubernetes secrets, and Secrets Manager values**,
   then **bootstrap the databases in-cluster** (a laptop cannot reach a
   private Aurora directly).
4. **Preflight the rendered values**, then **install the chart**.
5. **Apply the final ALB alias** via Terraform (`ingress_alb`) once the
   controller reports the ALB hostname. The new zone is still undelegated at
   this point — the alias lands in it before delegation, so the cutover is
   purely a parent-NS change made by the customer. Never change the parent
   delegation or any existing application record yourself.

---

## 0. Prerequisites

Local tools:

```bash
brew install terraform awscli kubectl helm jq
```

AWS-side:

- Reviewed deployment permissions for the selected ownership mode (EKS, EC2,
  Aurora, Secrets Manager, IAM, ELB, ACM, optional Route 53). Customer-owned
  networking does not require VPC/subnet/route/endpoint lifecycle permissions.
- AWS SSO or approved AWS credentials configured for `aws sts get-caller-identity`
- Valid license, approved integration credentials, and any Agent Factory
  read-role grant requirements resolved before starting paid provisioning
- Sufficient service quotas:
  - **vCPU for EC2 On-Demand (general):** enough for `m6i.large` × 2-3
  - **vCPU for EC2 G/VT On-Demand:** enough for `g4dn.xlarge` × 1+ if
    you enable the GPU embedder pool

Region: anywhere with EKS 1.31+ + Aurora Postgres 16 + g4dn or g5 GPU
instances (us-east-1 most common).

**Verify which AWS account/profile you're in before running terraform** —
profile mismatches are easy to make and expensive to undo:

```bash
aws sts get-caller-identity --profile <profile>
# Account, Arn, UserId all visible — confirm this is the right account
```

GHCR-side: a fine-grained PAT (or classic with `read:packages`) issued
by try-caret. Customers receive this during onboarding.

---

## 1. Terraform state and environment

State is in S3, one key per environment. The **public mirror** excludes the
internal `backend.tf` and `backends/` files: create your own backend there,
e.g. below. In the internal checkout, keep the existing backend declaration
and initialize with the matching `-backend-config=backends/<env>.s3.hcl`;
never overwrite it or pair one environment's backend with another's tfvars.

```hcl
# $TFROOT/backend.tf
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
cd "$TFROOT"
terraform init -reconfigure
```

Create a tfvars file (copy `envs/example.tfvars` and edit; keep it outside
git). Two network modes:

**Created network (default).** Minimum fields:

```hcl
aws_region  = "us-east-1"
environment = "<env>"
name_prefix = "arbium"

vpc_cidr             = "10.71.0.0/16"
private_subnet_cidrs = ["10.71.0.0/20", "10.71.16.0/20", "10.71.32.0/20"]
public_subnet_cidrs  = ["10.71.240.0/24", "10.71.241.0/24", "10.71.242.0/24"]

cluster_version = "1.31"

general_node_instance_types = ["m6i.large"]
general_node_min_size       = 2
general_node_desired_size   = 3
general_node_max_size       = 4

# GPU pool for the GPU embedder.
gpu_node_instance_types = ["g4dn.xlarge"]
gpu_node_ami_type       = "AL2023_x86_64_NVIDIA"
gpu_node_min_size       = 1
gpu_node_desired_size   = 1
gpu_node_max_size       = 1

aurora_serverless_min_acu    = 0.5
aurora_serverless_max_acu    = 8
aurora_backup_retention_days = 7
aurora_deletion_protection   = true
aurora_skip_final_snapshot   = false

enable_lb_controller = true   # AWS Load Balancer Controller (ALB for chart Ingress)
enable_eso           = true   # External Secrets Operator + IRSA for the chart's `eso` KSA
```

**Customer-owned network (bring-your-own).** Instead of CIDRs, reference the
customer's VPC — Terraform validates and reads it, it never creates, retags,
or manages its lifecycle:

```hcl
existing_network = {
  vpc_id             = "vpc-…"
  private_subnet_ids = ["subnet-…", "subnet-…"] # matched AZs, ≥2 distinct
  public_subnet_ids  = ["subnet-…", "subnet-…"] # required for internet-facing ingress
}
```

Requirements enforced up front: ≥2 private subnets in distinct AZs inside the
VPC, VPC DNS support/hostnames enabled, and public subnets present when
ingress is internet-facing. `vpc_cidr`/`*_subnet_cidrs`/`create_public_subnets`/
`enable_nat_gateway` are ignored on this path.

**Ingress scheme.** `ingress_scheme` defaults to `internet-facing`. For a
cluster reachable only inside the customer network, set `ingress_scheme =
"internal"` and set chart `ingress.scheme: internal` to match. Terraform does
not install the application chart: its `helm_ingress_values_hint` output includes
the scheme to copy into Helm values. Use the subnet outputs for annotations. Private DNS/access
must be arranged by the customer separately.

**DNS.** Optional opt-in hosted zone management (default off — existing
environments see no DNS additions):

```hcl
create_ingress_certificate = true
ingress_domain_name        = "chaindb.<customer>.com"
create_public_hosted_zone  = true   # requires create_ingress_certificate
```

Terraform then creates the public zone named `ingress_domain_name`, the ACM
validation record in it, and (later, step 8) the ALB alias. **Do not hardcode
nameservers** — always read the `ingress_zone_name_servers` output; AWS
assigns them.

**Do not put secret values in tfvars** — Terraform creates empty
Secrets Manager containers; you populate the ones the chart actually reads in
step 5. List every secret name the values file references in `secret_names`,
so the containers exist even if some stay reserved/empty.

---

## 2. Provision infrastructure

```bash
cd "$TFROOT"
AWS_PROFILE=<profile> terraform plan  -var-file=<env>.tfvars
AWS_PROFILE=<profile> terraform apply -var-file=<env>.tfvars
```

Takes 15-20 min. Most of the wait is Aurora cluster instance creation
(~5-8 min by itself).

> If this environment's state was created under an older module layout (e.g.
> the network module gained `count`), the `moved` blocks migrate the addresses
> automatically. **Read the resulting plan**: it must show moves
> (`will be moved to`), not replacements or deletions of existing resources.
> The moves are designed to be zero-diff for existing environments, but that
> must be confirmed against the real state — never apply a plan that
> replaces or destroys an existing cluster's network or cluster.

Creates (created-network mode):
- VPC across 3 AZs (private + public subnets, NAT, S3 + interface VPC endpoints)
- EKS cluster + general managed node group + (optional) GPU managed node group
- IRSA OIDC provider
- Aurora Postgres 16 Serverless v2 cluster + writer instance + initial database
- Secrets Manager containers (empty)
- AWS Load Balancer Controller, External Secrets Operator, Reloader (via Helm)
- IRSA roles for the chart's `eso`, CaptureLake, admin-ui, factory-runner KSAs

Bring-your-own mode creates everything after the network and reads the
customer VPC/subnets instead of creating them.

Grab the outputs:

```bash
AWS_PROFILE=<profile> terraform output
```

Key ones:

- `cluster_name`, `cluster_endpoint`
- `aurora_cluster_endpoint` → DATABASE_URL host
- `aurora_master_user_secret_arn` → RDS-managed `{username, password}` JSON
- `secrets` → map of `{name → arn:aws:secretsmanager:.../<prefix>/<env>/<name>-XXXXX}`
- `arbium_eso_role_arn`, `capturelake_role_arn`, `capturelake_bucket`,
  `admin_ui_role_arn`, `factory_runner_role_arn` → values-file IRSA annotations
- `ingress_certificate_arn`, `ingress_certificate_validation_records`
- `ingress_zone_id`, `ingress_zone_name_servers` (a **list** — when the hosted
  zone is Terraform-managed, these are the NS records to hand the customer for
  delegation)

---

## 3. Configure kubectl

```bash
aws eks update-kubeconfig \
  --profile <profile> \
  --region <aws_region> \
  --name <cluster_name>
kubectl get nodes
```

Expected: general nodes + (if GPU desired ≥ 1) a GPU node with the
`nvidia.com/gpu` resource and `workload=embedder:NoSchedule` taint.

Confirm controllers:

```bash
kubectl get pods -n kube-system | grep aws-load-balancer
kubectl get pods -n external-secrets
# both should be Running
```

---

## 4. Validate the certificate

Publish the ACM validation CNAME at the domain's **authoritative DNS** from:

```bash
AWS_PROFILE=<profile> terraform output ingress_certificate_validation_records
AWS_PROFILE=<profile> terraform output -raw ingress_certificate_status_check_command
```

The validation output has this shape:

```text
<domain> = {
  name  = "_<token>.<ingress-domain>"
  type  = "CNAME"
  value = "_<token>.acm-validations.aws."
}
```

| Field | Value |
|---|---|
| Type | `CNAME` |
| Name/Host | `name` from Terraform output |
| Target/Value | `value` from Terraform output |

Two-zone case (Terraform manages the new zone): create the CNAME **in both**
the authoritative (existing) zone and the new Terraform-managed zone. The
authoritative copy is what validates the certificate today; the copy in the
Terraform-managed zone keeps renewal working once the parent delegates to it.
If the authoritative zone is managed in a different AWS account/provider,
select that account explicitly when creating it — and add **only** the
validation CNAME there. Never touch existing application records or the
parent delegation.

If the DNS provider offers proxying/CDN mode, keep this ACM validation record
DNS-only. ACM must be able to resolve the AWS validation target directly.

Run the status command until it returns `ISSUED`. Keep the ARN from:

```bash
AWS_PROFILE=<profile> terraform output -raw ingress_certificate_arn
```

You'll pass this ARN into chart values in step 5. Validating the certificate
does **not** move live traffic. Creating the alias in a new, undelegated zone
also does not move traffic; the customer-controlled delegation does.

---

## 5. Namespace, secrets, and runtime values

### 5a. Namespace with Helm ownership

The chart renders the Namespace itself, so Helm must recognize a pre-created
one as its own or `helm install` fails on the already-existing resource.
Create it **with** Helm's ownership metadata — and never overwrite the
ownership of a namespace you did not create:

```bash
kubectl create namespace arbium
kubectl annotate ns arbium \
  meta.helm.sh/release-name=arbium \
  meta.helm.sh/release-namespace=arbium --overwrite
kubectl label ns arbium app.kubernetes.io/managed-by=Helm --overwrite
```

> If `arbium` already exists in this cluster, STOP: find out what owns it
> first. Adding the annotations above to someone else's namespace tells Helm
> it may prune it.

### 5b. Out-of-band Kubernetes secrets (before any `--wait`)

```bash
# GHCR image-pull credentials (registry Secret)
kubectl -n arbium create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=<ghcr-user> \
  --docker-password=<read:packages PAT> \
  --docker-email=<email>

# Admin UI OIDC client (Entra app client id + secret).
# SESSION_SECRET is NOT needed here — ESO generates and persists it into
# admin-ui-session automatically on first sync.
kubectl -n arbium create secret generic admin-ui-oidc \
  --from-literal=OIDC_CLIENT_ID=<entra-admin-app-client-id> \
  --from-literal=OIDC_CLIENT_SECRET=<entra-admin-app-client-secret>
```

Add the redirect URI `https://<ingress.host>/admin/api/auth/callback` to the
Entra admin app.

Optional (marketplace/skill publishing only): register the marketplace GitHub
App by hand — its private key is downloadable exactly once, so load it
straight into the cluster rather than round-tripping through any store:

```bash
kubectl -n arbium create secret generic arbium-github-app \
  --from-file=GITHUB_APP_PRIVATE_KEY=./app.private-key.pem \
  --from-literal=GITHUB_WEBHOOK_SECRET=<webhook-secret>
```

### 5c. Populate Secrets Manager — only what ESO actually reads

Terraform created empty containers named `<prefix>/<environment>/<name>`.
**Populate only the ones your values file's ExternalSecrets reference** —
extra reserved containers can stay empty. With `externalSecrets.db.fromManagedSecret`
set, the chart builds `DATABASE_URL`, `SUPABASE_DB_URL`, and the CaptureLake
catalog/derived DSNs itself from the RDS-managed secret, so **never** push
static DSNs for those (they would silently break on the weekly rotation).

Read the master credentials (you can do this from the laptop — it's a
Secrets Manager read, not a database connection):

```bash
DB_SECRET_ARN=$(AWS_PROFILE=<profile> terraform output -raw aurora_master_user_secret_arn)
AURORA_HOST=$(AWS_PROFILE=<profile> terraform output -raw aurora_cluster_endpoint)
DB_JSON=$(AWS_PROFILE=<profile> aws secretsmanager get-secret-value \
  --secret-id "$DB_SECRET_ARN" --region <aws_region> --query SecretString --output text)
DB_USER=$(echo "$DB_JSON" | jq -r .username)   # default: chaindb_admin
DB_PW=$(echo "$DB_JSON"   | jq -r .password)
DB_PW_ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1], safe=''))" "$DB_PW")

push() {
  AWS_PROFILE=<profile> aws secretsmanager put-secret-value \
    --secret-id "<prefix>/<env>/$1" --secret-string "$2" --region <aws_region> >/dev/null
}

# Rendered ESO remoteRefs for a standard AWS install:
push enrollment "$(openssl rand -hex 32)"
push jwt        "$(openssl rand -hex 32)"
push license    "<signed-arbium-license-key>"   # check --max-users seat coverage
push gemini     "<gemini-api-key>"              # or the configured LLM credential
push scim       "<existing-provisioning-app-token>"   # see step 9 — do NOT mint a new one
push sentry-relay "<sentry-dsn>"                # optional; blank/absent disables telemetry
push google-private-key "<llm-provider-service-account-key>"  # SECRET — SA private key
```

Per-feature additions, per your values file:

- **Agent Factory** (`factory.secret.dataMappings`): `factory-db-rw` plus the
  two read DSNs — all three are **dedicated DB roles with fixed passwords**;
  they do not track the master rotation. See step 6 for role creation and the
  grant prerequisite.
- The SCIM token is the **existing** Entra provisioning app's token, reused
  unchanged. Rotation, if ever needed, must be coordinated at cutover so the
  live integration never breaks.

> **Aurora username is `chaindb_admin`, not `postgres`.** The terraform
> module sets it explicitly. Fetching from the RDS-managed secret (as above)
> avoids hardcoding — and note the RDS-managed password **rotates weekly**;
> every DSN that must track it goes through `fromManagedSecret`, never a
> copy-pasted static value.

### 5d. Write the runtime values file

Fill `"$VALUES"` (your local file) from the outputs. Start from the AWS
preset's structure and set at minimum: `global`, `imagePullSecrets`
(`ghcr-pull`), `externalSecrets` (IRSA role ARN, `fromManagedSecret` ARN,
Aurora host, `dataMappings` matching 5c), `secrets.existingSecret`,
`license.existingSecret`, `embedder`, `capturelake` (+ S3 bucket/IRSA),
`scim` (group GUIDs), `admin` (+ `admin-ui-oidc`), `ingress`
(host, `certificateArn`, explicit `alb.ingress.kubernetes.io/subnets` when
the network is customer-owned — subnet tags you don't own cannot be relied
on), `metricsServer.enabled: true` (chart-managed; the HPA needs it), and
`factory` if used.

---

## 6. Bootstrap databases in-cluster

The Aurora security group only accepts connections from the EKS nodes, so a
laptop `psql` cannot reach it. Run everything through short-lived pods —
credentials travel via a Kubernetes Secret, never as manifest literals:

```bash
# One bootstrap secret holding the master DSN (delete it when done):
kubectl -n arbium create secret generic bootstrap-db \
  --from-literal=DATABASE_URL="postgres://${DB_USER}:${DB_PW_ENC}@${AURORA_HOST}:5432/chaindb?sslmode=require"
```

### 6a. Apply the canonical migrations (existing supported path)

Run the published migrations image once, standalone — the same image and
entrypoint the chart uses as an initContainer. This creates the schema AND
the migration-declared `factory_rw` role **before** Helm waits on anything:

```bash
kubectl -n arbium apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: db-bootstrap-migrate
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      imagePullSecrets:
        - name: ghcr-pull
      containers:
        - name: migrate
          image: ghcr.io/try-caret/chaindb-migrations:0.6.8   # tag = chart appVersion
          args: ["migrate"]
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef: { name: bootstrap-db, key: DATABASE_URL }
EOF
kubectl -n arbium wait --for=condition=complete --timeout=15m job/db-bootstrap-migrate
kubectl -n arbium logs job/db-bootstrap-migrate | tail -20
```

No duplicate bootstrap code: this is `ChainDB/tools/chaindb-migrate` (Flyway)
running the canonical `ChainDB/supabase/migrations` stream — the same path
the chart's initContainer uses on every rollout.

### 6b. Create the CaptureLake databases

```bash
kubectl -n arbium apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: psql-bootstrap
spec:
  restartPolicy: Never
  containers:
    - name: psql
      image: public.ecr.aws/docker/library/postgres:16-alpine
      env:
        - name: DATABASE_URL
          valueFrom: { secretKeyRef: { name: bootstrap-db, key: DATABASE_URL } }
      command: ["sleep", "600"]
EOF
kubectl -n arbium wait --for=condition=Ready pod/psql-bootstrap --timeout=120s

kubectl -n arbium exec -i psql-bootstrap -- sh -c 'psql -X -v ON_ERROR_STOP=1 "$DATABASE_URL"' <<'SQL'
CREATE DATABASE capturelake;
CREATE DATABASE derived;
SQL
# Reconnect to `derived`, preserving the query params (e.g. sslmode) from the DSN:
kubectl -n arbium exec -i psql-bootstrap -- sh -c '
  base="${DATABASE_URL%%\?*}"; q="${DATABASE_URL#*\?}"; [ "$q" = "$DATABASE_URL" ] && q=""
  psql -X -v ON_ERROR_STOP=1 "${base%/chaindb}/derived${q:+?$q}"' <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
SQL
```

Database creation is a **one-time fresh-install** step, not idempotent: on
failure inspect the databases before retrying; do not drop/recreate them.
The extension statements are idempotent. The chart's `capturelake` Deployment runs the
DuckLake catalog migrations on start, and `capturelake.schemaInit` owns the
derived Postgres schema (it also runs the same `CREATE EXTENSION IF NOT
EXISTS`, so the explicit step above is a belt-and-braces no-op afterwards).

### 6c. Agent Factory roles

- **`factory_rw` (writer)** was declared by the migrations in 6a
  (`20260815090000_factory_writer_role.sql`: `GRANT SELECT,INSERT,UPDATE` on
  `factory_sops`/`factory_recs` only). It exists with no password — set one
  from the generated secret now:

  ```bash
  FACTORY_RW_PW=$(openssl rand -hex 24)
  printf "ALTER ROLE factory_rw WITH PASSWORD '%s';\n" "$FACTORY_RW_PW" \
    | kubectl -n arbium exec -i psql-bootstrap -- sh -c 'psql -X -v ON_ERROR_STOP=1 "$DATABASE_URL"'
  AWS_PROFILE=<profile> aws secretsmanager put-secret-value \
    --secret-id "<prefix>/<env>/factory-db-rw" \
    --secret-string "postgres://factory_rw:${FACTORY_RW_PW}@${AURORA_HOST}:5432/chaindb?sslmode=require" \
    --region <aws_region> >/dev/null
  ```

- **Read role(s).** There is **no committed grant list** in this repository
  for the factory read role. Obtain a reviewed least-privilege definition
  from the Agent Factory maintainers/data-access documentation. Do **not** substitute
  a broad `GRANT SELECT ON ALL TABLES` (that would expose credential and
  token tables). This is a **pre-Helm blocking prerequisite**:

  1. Obtain the explicit grant list from the factory's data-access docs.
  2. Create ONE login role (`CREATE ROLE … LOGIN NOSUPERUSER NOCREATEDB
     NOCREATEROLE NOINHERIT`, password from a generated secret, explicit
     grants only), or grant membership in an existing approved read-only role
     if the docs designate one.
  3. Both read DSNs use the **same role and password**, differing only in the
     default database:

     ```bash
     READ_PW=<generated>
     push factory-db-ro         "postgres://<read-role>:${READ_PW}@${AURORA_HOST}:5432/derived?sslmode=require"
     push factory-db-chaindb-ro "postgres://<read-role>:${READ_PW}@${AURORA_HOST}:5432/chaindb?sslmode=require"
     ```

  If the grants cannot be confirmed before the install, stop — do not roll
  Helm with empty or dummy factory DSNs: the chart's factory pods mount them
  and `--wait` would stall or start against broken credentials.

Then populate the values file's IRSA annotations and clean up:

```bash
kubectl -n arbium delete pod psql-bootstrap
kubectl -n arbium delete job db-bootstrap-migrate
kubectl -n arbium delete secret bootstrap-db
unset DB_JSON DB_USER DB_PW DB_PW_ENC FACTORY_RW_PW READ_PW
```

---

## 7. Preflight the rendered values

Unresolved `REPLACE_AFTER_APPLY` placeholders still render successfully — they silently
point the deployment at nothing. Render the exact published chart with ALL
value layers and fail on placeholders **before** installing anything:

```bash
# Subshell: fail on render errors, keep manifests private, always clean up.
(
  set -euo pipefail
  umask 077
  rendered=$(mktemp)
  trap 'rm -f "$rendered"' EXIT
  helm template arbium "$CHART_DIR" --namespace arbium \
    -f "$CHART_DIR/values-aws.yaml" -f "$VALUES" > "$rendered"
  if grep -q 'REPLACE_AFTER_APPLY' "$rendered"; then
    echo "FAIL: unresolved placeholders — fill Terraform outputs first" >&2
    exit 1
  fi
)
# STOP if the subshell fails. Do not print or keep rendered Secrets.
```

Feed every layer you will install with (AWS preset + your runtime values, in
the same order as the install) so the render is the install.

---

## 8. Install the chart

**Always with the full committed values, never `--reuse-values` /
`--reset-then-reuse-values`** (reused values silently drop new keys like
`reloader.enabled` or `config.auth.provisioningMode`):

```bash
helm upgrade --install arbium oci://ghcr.io/try-caret/charts/chaindb \
  --version 0.6.8 \
  --namespace arbium \
  --values "$CHART_DIR/values-aws.yaml" \
  --values "$VALUES" \
  --timeout 20m \
  --wait
```

Verify after the wait:

```bash
kubectl get pods -n arbium
kubectl get externalsecret -n arbium          # chaindb-runtime should be Synced/SecretSynced
kubectl get deploy -n reloader                # Reloader running (rotation self-heal)
kubectl get deploy -n arbium chaindb-edge-fns # metrics-server + HPA need it Ready
```

---

## 9. Point DNS at the ALB

After the install completes, get the actual ALB hostname and canonical
hosted-zone ID (the Ingress is named `chaindb`, not the release name):

```bash
kubectl get ingress -n arbium chaindb \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Never assume the ELB's zone id — take it from the describe output:

```bash
aws elbv2 describe-load-balancers --region <aws_region> --query \
  "LoadBalancers[?DNSName=='<alb-hostname>'].CanonicalHostedZoneId" --output text
```

If Terraform manages the hosted zone, put the alias into it via
`ingress_alb` in tfvars and apply — the zone is still **undelegated** at this
point, so this changes no live traffic:

```hcl
ingress_alb = {
  dns_name = "<alb-hostname>"
  zone_id  = "<canonical-hosted-zone-id>"
}
```

Without Terraform-managed DNS, add the record at the domain's DNS provider:

| DNS provider | Type | Name | Value |
|---|---|---|---|
| Route 53 | `A`/`AAAA` ALIAS | `<ingress-domain>` | ALB DNS name + canonical zone id |
| Other DNS providers | `CNAME` | `<ingress-domain>` | `<alb-hostname>` |

If the DNS provider offers proxying/CDN mode, start with DNS-only for the final
app record too. Enable proxying only after HTTPS and application behavior are
verified.

Parent-domain delegation to a Terraform-managed zone is a **customer action**,
taken separately. Hand over the AWS-assigned nameservers exactly as output —
`ingress_zone_name_servers` is a **list**:

```bash
cd "$TFROOT"
AWS_PROFILE=<profile> terraform output -json ingress_zone_name_servers | jq -r '.[]'
```

Never `terraform output -raw` a list, and never substitute example nameservers.

---

## 10. Smoke test + SCIM provisioning

Until the parent domain resolves to the new ALB, use a host-preserving
override so the TLS SNI, certificate, and callback URLs all match production:

```bash
ALB_IP=$(dig +short <alb-hostname> | head -1)
curl --resolve <ingress-domain>:443:$ALB_IP https://<ingress-domain>/functions/v1/agent-enroll \
  -H "Authorization: Bearer $ENROLL" ...
```

Full ingest smoke (after the host resolves, or with `--resolve`):

```bash
ENROLL=$(AWS_PROFILE=<profile> aws secretsmanager get-secret-value \
  --secret-id <prefix>/<env>/enrollment --region <aws_region> \
  --query SecretString --output text)

EMAIL="smoke+$(date +%s)@example.com"
ENROLL_JSON=$(curl -fsS --resolve <ingress-domain>:443:$ALB_IP \
  -X POST "https://<ingress-domain>/functions/v1/agent-enroll" \
  -H "Authorization: Bearer $ENROLL" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"label\":\"smoke\"}")
TOKEN=$(echo "$ENROLL_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['token'])")

NOW_MS=$(($(date +%s) * 1000))
curl -fsS --resolve <ingress-domain>:443:$ALB_IP \
  -X POST "https://<ingress-domain>/functions/v1/captures-batch-direct" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "[{\"id\":\"$(uuidgen | tr A-Z a-z)\",\"timestamp\":$NOW_MS,\"appName\":\"smoke\",\"windowKey\":\"smoke\",\"windowTitle\":null,\"eventType\":null,\"eventText\":\"hello\",\"diffText\":\"hello\",\"treeText\":null,\"stateSource\":\"diff\"}]"
# Expected: {"inserted":1,"assigned":1,...}
```

Confirm the capture reached the **new** database (fresh install → every row
is yours), and check CaptureLake:

```bash
kubectl -n arbium logs deploy/chaindb-capturelake --tail=20
kubectl -n arbium get jobs | grep capturelake   # audit rotation by job exit code, not pod Ready
```

### Provision identities via the SCIM API (no Entra changes)

Identities arrive via the SCIM service (`/scim/v2` on the ingress host). Use
the **existing** Entra provisioning app's bearer token unchanged — the token
in Secrets Manager (step 5c) is that same value. No new provisioning app, no
Entra changes, no database patches. Pre-delegation the hostname still
resolves to the old deployment's ALB, so every test call needs a
host-preserving override:

```bash
SCIM_TOKEN=$(AWS_PROFILE=<profile> aws secretsmanager get-secret-value \
  --secret-id <prefix>/<env>/scim --region <aws_region> \
  --query SecretString --output text)

# 1. User — externalId MUST be the Entra user's objectId (object GUID):
curl -fsS --resolve <ingress-domain>:443:$ALB_IP \
  -X POST "https://<ingress-domain>/scim/v2/Users" \
  -H "Authorization: Bearer $SCIM_TOKEN" \
  -H "Content-Type: application/scim+json" \
  -d '{"userName":"<email>","externalId":"<entra-user-object-guid>","name":{"givenName":"Test","familyName":"User"},"emails":[{"value":"<email>","primary":true}]}'
# → note the "id" in the response

# 2. Group — externalId is the approved Entra group GUID; members.value are
#    the SCIM user ids from step 1 (copied GUIDs alone create nothing):
curl -fsS --resolve <ingress-domain>:443:$ALB_IP \
  -X POST "https://<ingress-domain>/scim/v2/Groups" \
  -H "Authorization: Bearer $SCIM_TOKEN" \
  -H "Content-Type: application/scim+json" \
  -d '{"displayName":"<group-name>","externalId":"<approved-group-guid>","members":[{"value":"<scim-user-id-from-step-1>"}]}'
```

Group GUIDs must match the values file's `scim.scimUserGroupIds` /
`scimAdminGroupIds`. Any credential rotation is coordinated at cutover so the
live integration never breaks; nothing in Entra changes before handoff.

**Browser/OIDC testing before delegation.** For admin/SCIM login flows that
need a real browser, add a temporary hosts-file override on the test laptop
mapping `<ingress-domain>` to the ALB IP, so the hostname, certificate, and
OIDC callback URL stay production-correct. Remove the override after testing,
and confirm the test request/capture in the **new cluster's** logs or database.
Use ALB access logs as further evidence when enabled (IDC's values enable
logging to the Terraform-created ALB log bucket). Generic installs must opt in.

---

## Secret rotation

AWS rotates the Aurora master password weekly into the RDS-managed secret;
ESO syncs it into `chaindb-runtime` and Reloader rolls the annotated
Deployments. This self-heals only while all of these stay true:

1. Reloader installed by Terraform (`helm_release.reloader`), running in `reloader`.
2. `reloader.enabled: true` in the values file (admin-ui/llm-proxy opt into
   extra Secrets via `admin.envFromSecrets` etc.).
3. `externalSecrets.db.fromManagedSecret` set (else DATABASE_URL tracks a
   static password that never rotates).
4. Every DSN that must track the rotation goes through `fromManagedSecret` —
   the chart templates the CaptureLake catalog/derived DSNs from the rotating
   managed secret. **Agent Factory DSNs are dedicated roles with fixed
   passwords and do NOT track the master rotation** (that's the point of
   them); rotate those out-of-band if ever needed.

**Audit a rotation by CronJob/job exit code, not pod readiness** — the
CaptureLake writer's `/healthz` never touches the catalog, so a stale-DSN pod
stays Ready while silently dropping writes:

```bash
kubectl -n arbium get jobs | grep capturelake
```

Post-roll assertion:

```bash
kubectl -n arbium get deploy admin-ui chaindb-edge-fns scim \
  -o 'jsonpath={range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.secret\.reloader\.stakater\.com/reload}{"\n"}{end}'
kubectl -n arbium get configmap chaindb-config -o jsonpath='{.data.AUTH_PROVISIONING_MODE}'   # scim on SCIM-gated clusters
```

`chaindb-config` is not Reloader-watched — config-only changes still need a
`kubectl rollout restart deploy/chaindb-edge-fns deploy/scim` (a version-bump
helm roll covers it).

## Upgrading the chart

Same as install — preflight first, full values, pinned version:

```bash
# First pull/extract the NEW pinned version and update CHART_DIR.
# Run step 7's fail-closed preflight with that chart and every values layer;
# stop on failure. Do not preflight an old chart and install a different one.
helm upgrade arbium oci://ghcr.io/try-caret/charts/chaindb \
  --version <new-release-version> \
  --namespace arbium \
  --values "$CHART_DIR/values-aws.yaml" \
  --values "$VALUES" \
  --wait
```

Before upgrading across several minor versions, diff
`helm get values arbium -n arbium -o yaml` against your committed values to
confirm there are no live-only keys.

## Destroy disposable environments

```bash
helm uninstall arbium -n arbium
kubectl delete namespace arbium

cd "$TFROOT"
AWS_PROFILE=<profile> terraform destroy -var-file=<env>.tfvars
```

Wait for the LBC to remove the application ALB/target groups/security groups
before destroying the controllers. Aurora deletion protection and final-snapshot
settings require a separately reviewed teardown decision. Secrets Manager uses
a recovery window; do not force-delete secrets or customer-owned resources as
a workaround. This section does not authorize production decommissioning.

Do **not** destroy a deployment that shares DNS with a live production
record — remove the alias first so nothing points at resources mid-teardown.

## Common failures

### Helm install times out

```bash
kubectl get pods,events -n arbium --sort-by='.lastTimestamp' | tail -30
kubectl logs -n arbium -l app.kubernetes.io/component=edge-fns --tail=50
kubectl logs -n arbium <pod> -c migrations   # migration initContainer gates every listed workload
```

Likely causes: pull secret missing (step 5b), ESO not synced (step 5c —
check the exact remoteRef names your values reference), or migrations stuck.

### `FATAL: password authentication failed for user "postgres"`

You hardcoded the username. Aurora's master is `chaindb_admin` — fetch
it from the RDS-managed secret as shown in step 5c.

### LB Controller pods CrashLoopBackOff

Almost always an IRSA issue:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
kubectl get sa -n kube-system aws-load-balancer-controller -o yaml | grep role-arn
# should match terraform output lb_controller_role_arn
```

### Ingress has no ADDRESS

ALB takes 60-180s to provision after the Ingress resource appears. If
it's still empty after 3 min:

```bash
kubectl describe ingress -n arbium chaindb
# look for events from the load-balancer-controller
```

Common causes: no usable public subnets in ≥2 AZs (with bring-your-own
network, the values file's explicit `alb.ingress.kubernetes.io/subnets`
annotation is authoritative — never rely on subnet tags you don't own), or
the ACM cert isn't `ISSUED` yet.

### Admin login fails with `scim_identity_not_found`

The SCIM `externalId` is not the user's Entra objectId. Reprovision via the
SCIM API with the correct `externalId`; never patch the database (a sync
overwrites it).

### `helm install` rejects the namespace

The namespace existed without Helm ownership metadata — see step 5a. If you
did not create that namespace, stop and find its owner instead of annotating.