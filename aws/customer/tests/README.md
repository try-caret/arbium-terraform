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

`tests/gpu-time-slicing.tftest.hcl` (same isolated-copy recipe, `-filter=tests/gpu-time-slicing.tftest.hcl`)
covers the opt-in GPU sharing: off by default with the device plugin's values unchanged, the time-slicing
config for 2 replicas, and rejection of 0, more than 16, or sharing without the device plugin.

`tests/aurora-performance-insights.tftest.hcl` (same isolated-copy recipe, `-filter=tests/aurora-performance-insights.tftest.hcl`)
covers the Aurora module's Performance Insights: on with 7 days by default, no retention sent when off, a longer retention
passed through, and rejection of retention values AWS does not accept (accepts 7, 731 and multiples of 31 up to 713).
`tests/aurora-performance-insights-root.tftest.hcl` (`-filter=tests/aurora-performance-insights-root.tftest.hcl`) plans
the root and checks the two `aurora_performance_insights_*` variables reach the module.

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
