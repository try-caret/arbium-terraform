# GCP production readiness checklist

This document tracks everything still needed to move the GCP deployment from
"works in a test env" to "ready for a real customer."

State as of `feat/add-gcp-deployment` head. Tick off as work lands.

## Tier 1 — must-fix before any external user

### Networking + DNS + TLS
- [x] Static external IP reserved (`arbium-<env>-ingress`); GCE Ingress
      bound via `kubernetes.io/ingress.global-static-ip-name` annotation
      from chart values. Verified on arbium-tftest: chaindb.arbium.ai
      -> 8.232.121.50.
- [x] (was) Reserve a static external IP and attach to the GCE Ingress via
      `kubernetes.io/ingress.global-static-ip-name`. Without this, the LB IP
      changes on every chart re-install.
- [x] DNS A record for chaindb.arbium.ai pointing at 8.232.121.50 (live).
- [x] Google-managed certificate (`arbium-tls`) requested via the chart's
      ManagedCertificate template; Google currently Provisioning.
- [ ] (waiting) Google-managed certificate
      so the ALB/GCE LB terminates TLS. Today the URL is HTTP-only.
- [ ] Set `kubernetes.io/ingress.allow-http: "false"` once HTTPS is healthy.

### Auth + enrollment
- [x] Opaque token auth path works.
- [x] `agent-enroll` edge function ships in the chart (see commit history).
- [x] Entra OIDC config seeded into public.chaindb_config
      (tenant 8f1a1811-..., client 86d4437e-...). /auth-config now returns
      OIDC method with the Microsoft sign-in URL. Mac agent side still
      needs to launch the actual MS sign-in flow.
- [ ] Document the device-enrollment flow for IT (curl example, Intune
      command line).
- [ ] Decide on JWT_SECRET rotation policy. Currently a single secret in
      the runtime Secret; in HS256 mode rotating means re-issuing all
      device tokens.

### Embedder
- [x] CPU embedder image built + pushed (`arbium-embedder-cpu:dev`, 590 MB).
- [x] GPU embedder image built + pushed (`arbium-embedder-gpu:dev`, 2.7 GB,
      CUDA 12.5 + cuDNN runtime).
- [x] GPU embedder validated on L4: ONNX model loads on
      CUDAExecutionProvider in 2.3s, edge-fns hits POST /invocations,
      captures get assigned to episodes via centroid similarity.
- [x] Fine-tuned model deployed: pulled v4fp16-2048 from
      s3://caret-prod-sagemaker-models-us-east-1/caret-embedder/v4fp16-2048/
      and baked into arbium-embedder-gpu:finetuned-v4fp16. Running on L4
      with CUDAExecutionProvider in arbium-tftest. Ingest with real
      embeddings: 8 captures embedded + assigned in 267 ms.
- [ ] Production decision: keep pulling from S3 at build time, or move
      the model artifact to GCS so the customer GCP install doesn't have
      an AWS dependency for builds.
- [ ] `/search` returns hits only after `drain-batch` summarizes episodes
      into facts. Requires a working Gemini API key (today: arbium-tftest
      drain-batch is in CrashLoopBackOff because the gemini Secret Manager
      value is empty).

### Migration runner idempotency
- [x] Switched to Flyway-based `ChainDB/tools/chaindb-migrate`. Flyway tracks
      applied versions in `chaindb_migrations.flyway_schema_history` and skips
      already-applied files. Re-running the Helm hook / initContainer on a
      populated DB is a no-op.

### Database + state
- [ ] Set `cloudsql_deletion_protection = true` in production tfvars.
- [ ] Bump `cloudsql_backup_retention_days` from 1 (test default) to 7+
      and set `transaction_log_retention_days` correspondingly.
- [ ] Switch `cloudsql_availability_type` from `ZONAL` to `REGIONAL` for
      HA writer + sync standby.
- [ ] Run `CREATE EXTENSION vector;` once against the `chaindb` database
      (today the bootstrap SQL handles it via `create extension if not
      exists`, so this should already be done — confirm in any new env).
- [ ] Decide whether to add a read-replica node for `/search` traffic.

### Secrets handling
- [x] Chart ships `externalSecrets.enabled` flag with a ClusterSecretStore
      + ExternalSecret that pull from GCP Secret Manager via Workload
      Identity. Validated on arbium-tftest: ESO syncs the K8s Secret
      and edge-fns env shows DATABASE_URL/JWT/etc. resolved from Secret
      Manager. Customer flips `secrets.create=false` +
      `secrets.existingSecret=<release>-runtime`.
- [x] Terraform creates a dedicated GSA (arbium-<env>-eso) with
      `roles/secretmanager.secretAccessor` + workloadIdentityUser binding
      for the chart's `arbium-eso` KSA.
- [x] Default `secret_names` now includes `enrollment` + `jwt` so all
      keys the chart needs come from Terraform-managed containers.
- [ ] Install External Secrets Operator helm chart in the cluster as
      part of the customer install runbook (one-off, separate from the
      Arbium chart).
- [ ] Set up secret rotation cadence for: scheduler token, enrollment
      secret, JWT secret, Cloud SQL admin password.

### Image hygiene
- [ ] Pin all image references to digest (`@sha256:...`) instead of `:dev`
      tag. Update both `values-aws.yaml` and `values-gcp.yaml` defaults.
- [ ] Decide on an image versioning scheme (semantic tags `v1.x.y` for
      releases, `dev-<sha>` for previews).
- [ ] Add a Cloud Build / GitHub Action that builds, pushes, and tags on
      every merge to main.
- [ ] Add image vulnerability scanning (Artifact Registry has this built-in
      on push — enable + monitor).

## Tier 2 — strongly recommended before scaling

### Cluster hardening
- [ ] Tighten `master_authorized_networks` from the current `0.0.0.0/0`
      test default down to operator office IPs + CI runner CIDRs.
- [ ] Flip `cluster_endpoint_public_access = false` after operators have
      VPN/IAP access lined up.
- [x] Chart ships five purpose-built NetworkPolicies behind
      `networkPolicy.enabled` (default-deny + intra-ns + DNS + edge-fns
      ingress + egress-https).
- [ ] Enable `networkPolicy.enabled=true` in customer values after
      verifying the cluster CIDR doesn't conflict with the egress-https
      `except` block (`10/8`, `172.16/12`, `192.168/16`).
- [ ] Enable Pod Security Standards / OPA Gatekeeper for namespace-level
      restrictions.
- [ ] Consider GKE Dataplane V2 (Cilium-based) for better network policy
      observability.

### Autoscaling + reliability
- [x] HPA enabled by default in `values-gcp.yaml` and `values-aws.yaml`:
      min=2, max=10, target CPU 70%.
- [x] PDB enabled by default for edge-fns (`minAvailable=1`) — protects
      against simultaneous drain during node upgrades.
- [x] `edgeFns.replicaCount=2` baseline in both cloud presets so rolling
      upgrades have a healthy replica throughout.
- [ ] Increase general node pool autoscale range (currently 1..3) to handle
      bursts. Production default closer to `general_node_max_size = 10`.
- [ ] Set `gpu_node_min_size: 1` for production so the embedder isn't
      cold-starting (or use Cloud Run for the embedder once packaging is
      done).
- [ ] PDB for embedder (`pdb.embedder.enabled=true`) once the embedder
      runs multi-replica.

### Observability
- [ ] Populate the `arbium-<env>-sentry` Secret Manager value with a real
      Sentry DSN and set `telemetry.sentry.enabled=true`.
- [ ] Decide on optional Sentry Relay deployment (on-prem ingest) or
      keep direct-to-Sentry.
- [ ] Provision a Cloud Monitoring workspace + dashboards for:
      edge-fns p95 latency, Cloud SQL connections, GKE node CPU/mem,
      Ingress backend health.
- [ ] Alerting policies via `gcp-mcp__create_alert_policy` or Terraform:
      pod restart loops, Cloud SQL CPU > 80%, edge-fns 5xx rate.

### Security layer
- [x] Cloud Armor security policy available behind
      `ingress_cloud_armor_enabled` in Terraform. Includes per-IP rate
      limiting (`cloud_armor_rate_limit_rpm`, default 600), preconfigured
      SQLi/XSS/RCE rules (OWASP CRS v33), and Layer 7 DDoS adaptive
      protection. Customer attaches via the chart's `backendConfig.*`
      values which render a BackendConfig CRD + Service annotation.
- [ ] Apply Cloud Armor in production tfvars (`ingress_cloud_armor_enabled
      = true`) and customer values (`backendConfig.enabled=true`,
      `backendConfig.securityPolicy = <terraform output>`).
- [ ] Enable Binary Authorization for the cluster (signed images only).
- [ ] Audit IAM bindings — node SA currently has only the necessary
      roles, but verify after any additions.
- [ ] Customer data handling: confirm no PII gets into logs (Cloud Logging
      is retained; sanitize edge-fns log lines).

### Scheduler + drain-batch
- [ ] Populate `arbium-<env>-gemini` Secret Manager value with the
      Gemini API key so `drain-batch` can summarize episodes.
- [ ] Enable scheduler (`scheduler.enabled=true`) — CronJobs already in
      chart; just needs the key + the right token plumbing.
- [ ] Monitor `drain-batch` CronJob success rate; alert on consecutive
      failures.
- [ ] Decide on Bedrock vs Gemini for summarization; once Anthropic Bedrock
      quotas are granted on AWS side, can flip via `EMBEDDER_PROVIDER` /
      drain-batch config.

## Tier 3 — nice-to-have

- [ ] Switch chart distribution from local-path to OCI registry
      (`ghcr.io/try-caret/charts/arbium` per the conversation earlier).
- [ ] Bump `Chart.yaml:version` to `1.0.0`, add CHANGELOG, set up CI
      publish on chart change.
- [ ] Migrate Terraform state from local to GCS backend
      (versioned bucket, state locking).
- [ ] AlloyDB swap path (one-knob change) documented for customers whose
      load justifies it.
- [ ] Add `gsd:audit-milestone` or similar internal audit pass before
      handing the install to a customer.
- [ ] Customer-facing OPERATIONS runbook: how to upgrade, how to rotate
      secrets, how to recover from a Cloud SQL backup, how to scale.

## Cost guardrails (already in place — re-confirm before launch)

- Cloud NAT: $0.045/hr (~$33/mo) — necessary, accept.
- GKE control plane: $0.10/hr (~$73/mo) per cluster.
- Cloud SQL `db-custom-2-7680`: ~$70/mo + disk.
- L4 GPU node `g2-standard-4`: ~$510/mo if min=1. Consider min=0 with
  HPA for cost.

Production with all of the above ON, no GPU: ~$200–250/mo per customer.
With a single L4 GPU node always-on for the embedder: ~$700/mo.

## Done items (carried over so we don't accidentally regress)

- [x] Terraform foundation creates VPC, GKE Standard, Cloud SQL Postgres 16
      with private IP via PSA, Secret Manager containers, dedicated GKE
      node service account, Cloud SQL Auth Proxy GSA + Workload Identity
      bindings.
- [x] Helm chart is cloud-agnostic; `values-aws.yaml` + `values-gcp.yaml`
      are the only cloud-specific surfaces.
- [x] Chart-managed Cloud SQL Auth Proxy via `cloudSqlProxy.enabled`.
- [x] Migrations run as a Helm hook on every install/upgrade; idempotent.
- [x] Authentication via opaque tokens proven end-to-end.
- [x] Synthetic ingest → episode → stats round-trip verified by
      `scripts/smoke-test.py`.
- [x] `agent-enroll` edge function ships in the chart (issues opaque
      tokens after validating the shared enrollment secret).
