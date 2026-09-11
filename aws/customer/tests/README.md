# Offline Terraform regression checks

Tested with Terraform 1.15.7. No AWS credentials, live backend, or cluster are
needed. The native suite mocks **every provider**, overrides unrelated modules,
and only plans: it never runs the secret-purge provisioner. These checks do not
replace real, authorized plans against each environment's actual state.

From the Terraform root, use an isolated copy (do not reinitialize a working
production backend just to test):

```bash
TFROOT=$PWD
work=$(mktemp -d)
cp "$TFROOT"/*.tf "$work/"
if [ -f "$TFROOT/.terraform.lock.hcl" ]; then
  cp "$TFROOT/.terraform.lock.hcl" "$work/"
fi
cp -R "$TFROOT/modules" "$TFROOT/policies" "$TFROOT/tests" "$work/"
rm -f "$work/backend.tf"
env -u TF_DATA_DIR terraform -chdir="$work" init -backend=false -input=false
env -u TF_DATA_DIR terraform -chdir="$work" validate
env -u TF_DATA_DIR terraform -chdir="$work" test -filter=tests/network_dns.tftest.hcl
rm -rf "$work"
```

Coverage: default three-AZ created-network/output contracts, whole-module bypass
for supplied networking, invalid subnet shapes/membership/AZs/DNS, private-only
internal ingress, opt-in DNS defaults, undelegated certificate foundation,
canonicalized ACM domain names, and post-Helm ALB alias wiring.

The internal checkout additionally has:

```bash
bash scripts/test-deployment-values.sh
python3 scripts/test-network-migrations.py
```

The migration script generates two historical **address shapes** from the actual
network module (singleton VPC and exploratory counted VPC), saves mock state,
and plans the production moved blocks against both. Every managed network
resource must move with **no create, update, delete, or replacement** action.
It loads no backend, application modules or provisioners, rejects AWS CLI use,
and removes temporary fixtures/state. It is not a snapshot comparison of all
historical configuration or a drift check against the live accounts.

Provider initialization and real OCI chart rendering may download artifacts;
mocked test execution itself makes no AWS/Kubernetes API calls.
