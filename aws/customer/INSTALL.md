# Arbium AWS install — operator runbook

End-to-end install of Arbium/ChainDB on a fresh AWS account. Targets
chart **0.1.4+**.

Tested 2026-05-23.

```
terraform → kubectl creds → ACM cert + DNS validation → Secret Manager population → helm install → smoke
```

Expected total: ~30 min hands-on + ~10-30 min waiting on Aurora cluster
instance + ACM cert.

---

## 0. Prerequisites

Local tools:

```bash
brew install terraform awscli kubectl helm
```

AWS-side:

- Account with admin or equivalent permissions (VPC, EKS, EC2, Aurora,
  Secrets Manager, IAM, ELB, ACM, Route 53 if you'll manage DNS in AWS)
- SSO or PAT configured for `aws sts get-caller-identity`
- Sufficient service quotas:
  - **vCPU for EC2 On-Demand (general):** enough for `m6i.large` × 2-3
  - **vCPU for EC2 G/VT On-Demand:** enough for `g4dn.xlarge` × 1+ if
    you enable the GPU embedder pool

Region: anywhere with EKS 1.31 + Aurora Postgres 16 + g4dn or g5 GPU
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

## 1. Configure the environment

```bash
cd infra/aws/customer
cp envs/example.tfvars envs/<environment>.tfvars
```

Edit the copied file. Minimum fields:

```hcl
aws_region  = "us-east-1"
environment = "<environment>"
name_prefix = "arbium"

vpc_cidr             = "10.71.0.0/16"
private_subnet_cidrs = ["10.71.0.0/20", "10.71.16.0/20", "10.71.32.0/20"]
public_subnet_cidrs  = ["10.71.240.0/24", "10.71.241.0/24", "10.71.242.0/24"]

cluster_version = "1.31"

# m6i.large minimum — anything smaller risks OOM on CPU embedder.
general_node_instance_types = ["m6i.large"]
general_node_min_size       = 1
general_node_desired_size   = 2
general_node_max_size       = 3

# GPU pool for the GPU embedder. Set _desired=0 if no quota; chart can
# fall back to the CPU embedder image (and bigger general nodes).
gpu_node_instance_types = ["g4dn.xlarge"]
gpu_node_ami_type       = "AL2_x86_64_GPU"
gpu_node_min_size       = 0
gpu_node_desired_size   = 1
gpu_node_max_size       = 1

# Aurora Serverless v2 — set min ACU above 0 to avoid auto-pause cold
# starts during smoke + low-traffic windows.
aurora_serverless_min_acu    = 0.5
aurora_serverless_max_acu    = 4
aurora_backup_retention_days = 7
aurora_deletion_protection   = true
aurora_skip_final_snapshot   = false

# Cluster addons — chart expects both to be installed.
enable_lb_controller = true   # AWS Load Balancer Controller (ALB for chart Ingress)
enable_eso           = true   # External Secrets Operator + IRSA for the chart's `eso` KSA
```

**Do not put secret values in tfvars** — Terraform creates empty
Secrets Manager containers; you populate them in step 4.

---

## 2. Provision infrastructure

```bash
terraform init
AWS_PROFILE=<profile> terraform plan -var-file=envs/<environment>.tfvars
AWS_PROFILE=<profile> terraform apply -var-file=envs/<environment>.tfvars
```

Takes 15-20 min. Most of the wait is Aurora cluster instance creation
(~5-8 min by itself).

Creates:
- VPC across 3 AZs (private + public subnets, NAT, S3 + interface VPC endpoints)
- EKS cluster + general managed node group + (optional) GPU managed node group
- IRSA OIDC provider
- Aurora Postgres 16 Serverless v2 cluster + writer instance
- Secrets Manager containers (empty)
- AWS Load Balancer Controller (installed into kube-system via Helm)
- External Secrets Operator (installed into external-secrets ns via Helm)
- IRSA role for the `eso` KSA the chart will create

Grab the outputs:

```bash
AWS_PROFILE=<profile> terraform output
```

Key ones:

- `cluster_name`, `cluster_endpoint`
- `aurora_cluster_endpoint` → DATABASE_URL host
- `aurora_master_user_secret_arn` → RDS-managed `{username, password}` JSON
- `secrets` → map of `{name → arn:aws:secretsmanager:.../arbium/<env>/<name>-XXXXX}`
- `arbium_eso_role_arn` → IRSA role for the chart's `eso` KSA

---

## 3. Configure kubectl

```bash
aws eks update-kubeconfig \
  --profile <profile> \
  --region <aws_region> \
  --name <cluster_name>
kubectl get nodes
```

Expected: 1-3 general nodes + (if GPU desired ≥ 1) 1 GPU node with the
`nvidia.com/gpu` resource and `workload=embedder:NoSchedule` taint.

Confirm cluster addons:

```bash
kubectl get pods -n kube-system | grep aws-load-balancer
kubectl get pods -n external-secrets
# both should be Running
```

---

## 4. Request the HTTPS certificate

Terraform can request the ALB ACM certificate and output the DNS validation
records to create in the customer's DNS provider.

In `envs/<environment>.tfvars` set:

```hcl
create_ingress_certificate = true
ingress_domain_name        = "chaindb.<customer>.com"
```

Apply the change:

```bash
AWS_PROFILE=<profile> terraform apply -var-file=envs/<environment>.tfvars
```

Create the ACM validation CNAME at the domain's DNS provider from:

```bash
terraform output ingress_certificate_validation_records
terraform output -raw ingress_certificate_status_check_command
```

The validation output has this shape:

```text
<domain> = {
  name  = "_<token>.<ingress-domain>"
  type  = "CNAME"
  value = "_<token>.acm-validations.aws."
}
```

Create that DNS record exactly as shown by Terraform:

| Field | Value |
|---|---|
| Type | `CNAME` |
| Name/Host | `name` from Terraform output |
| Target/Value | `value` from Terraform output |

If the DNS provider offers proxying/CDN mode, keep this ACM validation record
DNS-only. ACM must be able to resolve the AWS validation target directly.

Run the status command until it returns `ISSUED`. Keep the ARN from:

```bash
terraform output -raw ingress_certificate_arn
```

You'll pass this ARN into chart values in step 7.

---

## 5. Populate Secrets Manager values

Terraform created empty secret containers. Fill them:

```bash
# Fetch the Aurora-managed master credentials
DB_SECRET_ARN=$(AWS_PROFILE=<profile> terraform output -raw aurora_master_user_secret_arn)
DB_JSON=$(AWS_PROFILE=<profile> aws secretsmanager get-secret-value \
  --secret-id "$DB_SECRET_ARN" --region <aws_region> --query SecretString --output text)
DB_USER=$(echo "$DB_JSON" | jq -r .username)   # default: chaindb_admin
DB_PW=$(echo "$DB_JSON"   | jq -r .password)
DB_PW_ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1], safe=''))" "$DB_PW")
AURORA_HOST=$(AWS_PROFILE=<profile> terraform output -raw aurora_cluster_endpoint)

push() {
  AWS_PROFILE=<profile> aws secretsmanager put-secret-value \
    --secret-id "arbium/<env>/$1" --secret-string "$2" --region <aws_region> >/dev/null
}

# Chart 0.1.4 bundles AWS RDS Global CA + uses strict TLS automatically
# for *.amazonaws.com hosts. sslmode=require is correct + secure.
push db         "postgres://${DB_USER}:${DB_PW_ENC}@${AURORA_HOST}:5432/chaindb?sslmode=require"
push scheduler  "$(openssl rand -hex 32)"
push enrollment "$(openssl rand -hex 32)"
push jwt        "$(openssl rand -hex 32)"
push gemini     "<gemini-api-key>"
push license    "<signed-arbium-license-key>"
```

> **Aurora username is `chaindb_admin`, not `postgres`.** The terraform
> module sets it explicitly to match the GCP module. Fetching from the
> RDS-managed secret (as above) avoids hardcoding.

---

## 6. Create the GHCR pull secret

> **Don't pre-create the arbium namespace** — `helm install --create-namespace`
> claims ownership. Pre-creating breaks Helm. Create the pull secret
> AFTER step 8.

---

## 7. Write customer values

```bash
cat > <environment>.values.local.yaml <<EOF
global:
  namespace: arbium
  environment: <environment>
  region: <aws_region>

imagePullSecrets:
  - name: ghcr-pull

# External Secrets pulls from AWS Secrets Manager via IRSA.
externalSecrets:
  enabled: true
  provider: aws
  region: <aws_region>
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "<arbium_eso_role_arn>"
  dataMappings:
    DATABASE_URL:                       arbium/<env>/db
    SUPABASE_DB_URL:                    arbium/<env>/db
    CHAINDB_SCHEDULER_TOKEN:            arbium/<env>/scheduler
    ARBOR_AGENT_ENROLLMENT_SECRET:      arbium/<env>/enrollment
    ROOTS_INTUNE_PILOT_ENROLLMENT_SECRET: arbium/<env>/enrollment
    GEMINI_API_KEY:                     arbium/<env>/gemini
    JWT_SECRET:                         arbium/<env>/jwt
    ARBIUM_LICENSE_KEY:                 arbium/<env>/license

secrets:
  create: false
  existingSecret: chaindb-runtime

license:
  existingSecret: arbium-runtime

# Aurora directly — no proxy needed.
cloudSqlProxy:
  enabled: false

embedder:
  enabled: true
  gpu:
    enabled: true   # uses the embedder-gpu image on the GPU node pool

ingress:
  enabled: true
  className: alb
  host: chaindb.<customer>.com
  scheme: internet-facing
  certificateArn: "<terraform output -raw ingress_certificate_arn>"
  # Optional: wafAclArn: <wafv2-arn>
  annotations:
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"

# The chart's edge-fns image bundles the AWS RDS Global CA and auto-detects *.rds.amazonaws.com
# hosts → strict TLS with the bundled bundle. Leave at "require" (default).
config:
  databaseSsl: require
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
  --values charts/chaindb/values-aws.yaml \
  --values <environment>.values.local.yaml \
  --timeout 15m \
  --wait
```

Immediately after, create the GHCR pull secret in the now-created
namespace:

```bash
kubectl create secret docker-registry ghcr-pull \
  --namespace arbium \
  --docker-server=ghcr.io \
  --docker-username=<bot-user> \
  --docker-password=<paste-token> \
  --docker-email=<your-email>

# Bounce pods that started before the secret existed:
kubectl delete pod -n arbium --all
```

---

## 9. Point DNS at the ALB

After helm install completes, get the ALB hostname:

```bash
kubectl get ingress -n arbium arbium \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# returns: <alb-name>.us-east-1.elb.amazonaws.com
```

Add the final app DNS record. This is separate from the ACM validation CNAME
created in step 4.

| DNS provider | Type | Name | Value |
|---|---|---|---|
| Route 53 | `A`/`AAAA` ALIAS | `chaindb.<customer>.com` | `<alb-hostname>.elb.amazonaws.com` |
| Other DNS providers | `CNAME` | `chaindb.<customer>.com` | `<alb-hostname>.elb.amazonaws.com` |

If the DNS provider offers proxying/CDN mode, start with DNS-only for the final
app record too. Enable proxying only after HTTPS and application behavior are
verified.

Confirm:

```bash
dig +short chaindb.<customer>.com @8.8.8.8
```

---

## 10. Smoke test

```bash
ENROLL=$(AWS_PROFILE=<profile> aws secretsmanager get-secret-value \
  --secret-id arbium/<env>/enrollment --region <aws_region> \
  --query SecretString --output text)

EMAIL="smoke+$(date +%s)@<customer>.local"
ENROLL_JSON=$(curl -fsS -X POST "https://chaindb.<customer>.com/functions/v1/agent-enroll" \
  -H "Authorization: Bearer $ENROLL" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"label\":\"smoke\"}")
TOKEN=$(echo "$ENROLL_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['token'])")

NOW_MS=$(($(date +%s) * 1000))
curl -fsS -X POST "https://chaindb.<customer>.com/functions/v1/captures-batch-direct" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "[{\"id\":\"$(uuidgen | tr A-Z a-z)\",\"timestamp\":$NOW_MS,\"appName\":\"smoke\",\"windowKey\":\"smoke\",\"windowTitle\":null,\"eventType\":null,\"eventText\":\"hello\",\"diffText\":\"hello\",\"treeText\":null,\"stateSource\":\"diff\"}]"
# Expected: {"inserted":1,"assigned":1,...}
```

---

## Common failures

### Helm install times out

```bash
kubectl get pods,events -n arbium --sort-by='.lastTimestamp' | tail -30
kubectl logs -n arbium -l app.kubernetes.io/component=edge-fns --tail=50
```

Likely causes:
- Pull secret missing → 401 on image pull
- Embedder OOM → bump general pool from m6i.large to m6i.xlarge (or
  schedule on GPU pool by enabling `embedder.gpu.enabled=true`)
- ESO secret not synced → wait 30-60s, then `kubectl get externalsecret -n arbium`

### `FATAL: password authentication failed for user "postgres"`

You hardcoded the username. Aurora's master is `chaindb_admin` — fetch
it from the RDS-managed secret as shown in step 5.

### `connection closed before message completed`

Pre-0.1.4 bug — postgres.js client rejected the Aurora cert. Fixed in
0.1.4 by bundling the AWS RDS Global CA. If you see this on 0.1.4+,
confirm `image.edgeFns.tag` resolves to 0.1.4 or later.

### LB Controller pods CrashLoopBackOff

Almost always an IRSA issue:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
```

If you see `AccessDenied` or `unable to retrieve credentials`, the SA
annotation didn't bind. Confirm:

```bash
kubectl get sa -n kube-system aws-load-balancer-controller -o yaml | grep role-arn
# should match terraform output lb_controller_role_arn
```

### Ingress has no ADDRESS

ALB takes 60-180s to provision after the Ingress resource appears. If
it's still empty after 3 min:

```bash
kubectl describe ingress -n arbium arbium
# look for events from the load-balancer-controller
```

Common causes: missing tags on subnets (terraform handles this for
both private + public subnets), or the ACM cert isn't `ISSUED` yet.

---

## Upgrading the chart

```bash
helm upgrade arbium oci://ghcr.io/try-caret/charts/chaindb \
  --version <new-release-version> \
  --namespace arbium \
  --values charts/chaindb/values-aws.yaml \
  --values <environment>.values.local.yaml \
  --wait
```

Migrations run automatically on the next edge-fns pod rollout (via
initContainer). See `charts/chaindb/Chart.yaml` for the chart changelog.

---

## Destroy disposable environments

```bash
helm uninstall arbium -n arbium
kubectl delete namespace arbium

cd infra/aws/customer
AWS_PROFILE=<profile> terraform destroy -var-file=envs/<environment>.tfvars
```

Aurora deletion can fail if the chaindb DB owns objects under
chaindb_admin — drop the DB first via `aws rds delete-db-instance` or
the AWS console if terraform fails on the user delete step.

---

## Operational gotchas (read once before first install)

### `terraform destroy` + re-apply within 7 days

AWS Secrets Manager keeps deleted secrets recoverable for 7-30 days. Chart
0.1.4 terraform now auto-force-deletes any pending arbium-prefixed secrets
before re-creating them (via `null_resource.purge_pending_secrets`). If you
ever need to do it manually:

```bash
for name in db scheduler scim sentry registry gemini enrollment jwt; do
  aws secretsmanager delete-secret --secret-id "arbium/<env>/$name" \
    --force-delete-without-recovery --region <region>
done
```

### `helm install --wait` stuck in `pending-install`

Same as GCP — see GCP INSTALL.md's "Operational gotchas" for the recovery
recipe (kubectl patch on the helm release secret).

### Re-pushing the same image tag doesn't restart existing pods

```bash
kubectl rollout restart deployment/chaindb-edge-fns -n arbium
```

Better: bump the chart's `image.edgeFns.tag` to a new immutable tag.

### ESO Helm chart version matters

ESO < 2.0 only serves `external-secrets.io/v1beta1`. Chart 0.1.4 uses
`external-secrets.io/v1`. Terraform defaults `eso_chart_version=2.5.0` —
don't downgrade without also reverting the chart's API version.
