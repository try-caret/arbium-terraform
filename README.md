# Arbium Terraform

Public customer-consumable Terraform for Arbium infrastructure.

This repository is a generated mirror from the private Arbium monorepo. Do not
edit it directly; changes are released from the private source repository and
mirrored here with matching release tags.

## Modules

### AWS

```hcl
module "arbium_aws" {
  source = "github.com/try-caret/arbium-terraform//aws/customer?ref=chaindb-v0.2.6"

  # Set required variables here.
}
```

See [aws/customer/README.md](aws/customer/README.md).

### GCP

```hcl
module "arbium_gcp" {
  source = "github.com/try-caret/arbium-terraform//gcp/customer?ref=chaindb-v0.2.6"

  # Set required variables here.
}
```

See [gcp/customer/README.md](gcp/customer/README.md).

## Versioning

Release tags in this repository match Arbium release tags in the private source
repository. Customers should pin `?ref=chaindb-v0.2.6` or another explicit
release tag, not `main`.

## What is included

- `aws/customer`: AWS customer foundation root and local modules.
- `gcp/customer`: GCP customer foundation root and local modules.

Secret-bearing files, local `.tfvars` other than checked-in
`envs/example.tfvars` examples, Terraform state, generated local Terraform
directories, internal test-run notes, and helper scripts are excluded from this
public mirror.
