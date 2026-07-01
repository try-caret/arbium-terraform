# Arbium Terraform

Public customer-consumable Terraform for Arbium infrastructure.

This repository is a generated mirror from the private Arbium monorepo. Do not
edit it directly; changes are released from the private source repository and
mirrored here with matching release tags.

## Modules

### AWS

```hcl
module "arbium_aws" {
  source = "github.com/try-caret/arbium-terraform//aws/customer?ref=chaindb-v0.3.8"

  # Set required variables here.
}
```

See [aws/customer/README.md](aws/customer/README.md).

### GCP

```hcl
module "arbium_gcp" {
  source = "github.com/try-caret/arbium-terraform//gcp/customer?ref=chaindb-v0.3.8"

  # Set required variables here.
}
```

See [gcp/customer/README.md](gcp/customer/README.md).

## Versioning

Release tags in this repository match Arbium release tags in the private source
repository. Customers should pin `?ref=chaindb-v0.3.8` or another explicit
release tag, not `main`.

## What is included

- `aws/customer`: AWS customer foundation root and local modules.
- `gcp/customer`: GCP customer foundation root.
- `gcp/modules`: shared GCP modules consumed by the customer root.

The public mirror is intentionally minimal: the customer Terraform roots and
shared modules (`*.tf`, `modules/`, `policies/`), `README.md`, `INSTALL.md`,
`PLAN.md`, `envs/example.tfvars`, and `gcp/customer/docs/` customer docs.
Excluded: hosted-cloud Terraform (`infra/gcp/hosted`), all of `aws/customer/docs/`
(internal — accounts/buckets/operator notes), internal test-run notes and dashboards,
local `.tfvars` other than `envs/example.tfvars`, Helm `*.values*.yaml`, the
operator backend wiring (`backend.tf`, `backends/`), Terraform state, generated
local Terraform directories, and helper scripts.
