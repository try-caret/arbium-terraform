# Run with terraform test -filter=tests/agent-platform.tftest.hcl after backend-disabled init.
# All providers are mocked; these targeted plans never read live state or contact AWS/Kubernetes.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_resource "aws_vpc" {
    override_during = plan
    defaults        = { id = "vpc-aaaaaaaa" }
  }
}
mock_provider "tls" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
override_module {
  target = module.eks
  outputs = {
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/TEST"
    oidc_issuer_url   = "https://oidc.eks.us-east-1.amazonaws.com/id/TEST"
    cluster_name      = "test-cluster"
    cluster_endpoint  = "https://example.invalid"
    cluster_ca_data   = "dGVzdA=="
    # For the aws sandbox's NodeClass.
    cluster_security_group_id = "sg-00000001"
    auto_node_role_name       = "test-cluster-eks-auto-nodes"
  }
}
variables {
  environment                   = "test"
  enable_agent_platform         = true
  agent_platform_domain_name    = "agents.example.com"
  agent_platform_bedrock_models = ["us.anthropic.claude-sonnet-5-5"]
  availability_zones            = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

run "role_may_call_only_its_models" {
  command = plan
  plan_options {
    target = [aws_iam_role.agent_platform, aws_iam_role_policy.agent_platform, aws_acm_certificate.agent_platform]
  }
  assert {
    condition     = jsondecode(aws_iam_role.agent_platform[0].assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.us-east-1.amazonaws.com/id/TEST:sub"] == "system:serviceaccount:arbium:agent-platform"
    error_message = "Only the chart's agent-platform service account may take the role."
  }
  assert {
    condition = jsondecode(aws_iam_role_policy.agent_platform[0].policy).Statement[0].Resource == [
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-5-5",
    ]
    error_message = "The role may invoke exactly the listed inference profiles."
  }
  assert {
    condition     = contains(jsondecode(aws_iam_role_policy.agent_platform[0].policy).Statement[1].Resource, "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-5-5*")
    error_message = "The profile's model must be allowed in the regions the profile routes to."
  }
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.agent_platform[0].policy).Statement) == 2
    error_message = "The role may call its models and nothing else."
  }
  assert {
    condition     = aws_acm_certificate.agent_platform[0].domain_name == "agents.example.com"
    error_message = "The certificate covers the platform's own name."
  }
}

run "models_in_another_account_are_only_assumed" {
  command = plan
  variables {
    agent_platform_bedrock_models   = []
    agent_platform_bedrock_role_arn = "arn:aws:iam::210987654321:role/models"
  }
  plan_options {
    target = [aws_iam_role_policy.agent_platform]
  }
  assert {
    condition     = [for s in jsondecode(aws_iam_role_policy.agent_platform[0].policy).Statement : s.Sid] == ["AssumeModelRole"]
    error_message = "The role reaches models only through the other account's role."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.agent_platform[0].policy).Statement[0].Action == "sts:AssumeRole" && jsondecode(aws_iam_role_policy.agent_platform[0].policy).Statement[0].Resource == "arn:aws:iam::210987654321:role/models"
    error_message = "The role may assume exactly the named role."
  }
}

run "on_the_install_name_it_has_no_certificate_of_its_own" {
  command = plan
  variables {
    agent_platform_domain_name = "arbium.example.com"
    ingress_domain_name        = "arbium.example.com"
  }
  plan_options {
    target = [aws_iam_role_policy.agent_platform, aws_acm_certificate.agent_platform]
  }
  assert {
    condition     = length(aws_acm_certificate.agent_platform) == 0
    error_message = "The install's own certificate covers its name: the platform needs none."
  }
  assert {
    condition     = output.agent_platform.certificate_arn == null && length(output.agent_platform.certificate_validation_records) == 0
    error_message = "The Helm handoff has no certificate to add and no record to publish."
  }
}

run "no_sandbox_by_default" {
  command = plan
  plan_options {
    target = [helm_release.sandbox_nodes, kubernetes_namespace_v1.sandboxes, kubernetes_role_v1.sandboxes, aws_iam_role_policy.agent_platform, aws_acm_certificate.agent_platform]
  }
  assert {
    condition     = length(helm_release.sandbox_nodes) == 0 && length(kubernetes_namespace_v1.sandboxes) == 0 && length(kubernetes_role_v1.sandboxes) == 0
    error_message = "Functions off: no sandbox namespace, nodes or rights."
  }
  assert {
    condition     = output.agent_platform.sandbox_namespace == null && length(output.agent_platform.sandbox_env) == 0
    error_message = "The Helm handoff names no sandbox."
  }
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.agent_platform[0].policy).Statement) == 2
    error_message = "The role may call its models and nothing else."
  }
}

run "refuses_without_a_name_or_models" {
  command = plan
  variables { agent_platform_bedrock_models = [] }
  plan_options { target = [aws_iam_role.agent_platform] }
  expect_failures = [var.enable_agent_platform]
}

run "refuses_an_unknown_sandbox" {
  command = plan
  # OpenSandbox is gone.
  variables { agent_platform_sandbox = "opensandbox" }
  plan_options { target = [helm_release.sandbox_nodes] }
  expect_failures = [var.agent_platform_sandbox]
}

run "disabled_by_default" {
  command = plan
  variables { enable_agent_platform = false }
  plan_options {
    target = [aws_iam_role.agent_platform, aws_acm_certificate.agent_platform, helm_release.sandbox_nodes]
  }
  assert {
    condition     = length(aws_iam_role.agent_platform) == 0 && length(aws_acm_certificate.agent_platform) == 0 && length(helm_release.sandbox_nodes) == 0
    error_message = "Disabled provisioning must create nothing."
  }
}

run "nothing_reaches_a_function_pod_or_leaves_it" {
  command = plan
  variables {
    agent_platform_sandbox = "aws"
    cluster_version        = "1.36"
  }
  plan_options {
    target = [kubernetes_network_policy_v1.sandboxes]
  }
  assert {
    condition     = toset(kubernetes_network_policy_v1.sandboxes[0].spec[0].policy_types) == toset(["Ingress", "Egress"]) && length(kubernetes_network_policy_v1.sandboxes[0].spec[0].egress) == 0
    error_message = "The policy isolates both directions and allows nothing out, not even DNS."
  }
  assert {
    condition     = length(kubernetes_network_policy_v1.sandboxes[0].spec[0].ingress) == 0 && length(coalesce(kubernetes_network_policy_v1.sandboxes[0].spec[0].pod_selector[0].match_labels, {})) == 0
    error_message = "Nothing may connect to any pod in the namespace: the platform talks to them through the Kubernetes API."
  }
}

run "the_platform_may_only_make_read_delete_and_exec_pods_there" {
  command = plan
  variables {
    agent_platform_sandbox = "aws"
    cluster_version        = "1.36"
  }
  plan_options {
    target = [kubernetes_role_v1.sandboxes, kubernetes_role_binding_v1.sandboxes, kubernetes_resource_quota_v1.sandboxes, aws_iam_role_policy.agent_platform]
  }
  assert {
    condition     = length(kubernetes_role_v1.sandboxes[0].rule) == 2 && kubernetes_role_v1.sandboxes[0].rule[0].resources == toset(["pods"]) && kubernetes_role_v1.sandboxes[0].rule[0].verbs == toset(["create", "get", "delete"]) && kubernetes_role_v1.sandboxes[0].rule[1].resources == toset(["pods/exec"]) && kubernetes_role_v1.sandboxes[0].rule[1].verbs == toset(["create", "get"])
    error_message = "The platform's rights in the cluster are pods in the sandbox namespace (create, get, delete) and their exec stream (create, get)."
  }
  assert {
    condition     = kubernetes_role_binding_v1.sandboxes[0].subject[0].name == "agent-platform" && kubernetes_role_binding_v1.sandboxes[0].subject[0].namespace == "arbium"
    error_message = "Only the chart's agent-platform service account gets them."
  }
  assert {
    condition     = kubernetes_resource_quota_v1.sandboxes[0].spec[0].hard["pods"] == "30"
    error_message = "The namespace caps concurrent function pods."
  }
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.agent_platform[0].policy).Statement) == 2
    error_message = "The sandbox gives the platform's AWS role nothing beyond its models."
  }
}

run "functions_run_on_tainted_nitro_nodes_of_their_own" {
  command = plan
  variables {
    agent_platform_sandbox = "aws"
    cluster_version        = "1.36"
  }
  # Known subnets, so the rendered values are known at plan.
  override_module {
    target  = module.network
    outputs = { vpc_id = "vpc-aaaaaaaa", private_subnet_ids = ["subnet-00000001", "subnet-00000002"], public_subnet_ids = [] }
  }
  plan_options { target = [helm_release.sandbox_nodes, aws_iam_role_policy.agent_platform, aws_acm_certificate.agent_platform] }
  assert {
    condition     = [for o in yamldecode(helm_release.sandbox_nodes[0].values[0]).objects : o.kind] == ["NodeClass", "NodePool", "ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding"]
    error_message = "Functions get Auto Mode nodes of their own, and an admission policy for their pods."
  }
  assert {
    condition     = contains(yamldecode(helm_release.sandbox_nodes[0].values[0]).objects[1].spec.template.spec.requirements, { key = "eks.amazonaws.com/nitro-sandbox", operator = "In", values = ["true"] })
    error_message = "Those nodes run Nitro sandboxes."
  }
  assert {
    condition     = yamldecode(helm_release.sandbox_nodes[0].values[0]).objects[1].spec.template.spec.taints == [{ key = "workload", value = "sandbox", effect = "NoSchedule" }]
    error_message = "The nodes are tainted so only function pods, which tolerate it, land there."
  }
  assert {
    condition     = yamldecode(helm_release.sandbox_nodes[0].values[0]).objects[1].spec.replicas == 1
    error_message = "One sandbox node is always up: a call can't wait for a node to boot."
  }
  assert {
    condition     = output.agent_platform.sandbox_env["AWS_SANDBOX_RUNTIME_CLASS"] == "isolated-sandbox"
    error_message = "The Helm handoff names the Nitro runtime class."
  }
}

run "the_namespace_admits_only_function_pods" {
  command = plan
  variables {
    agent_platform_sandbox = "aws"
    cluster_version        = "1.36"
  }
  override_module {
    target  = module.network
    outputs = { vpc_id = "vpc-aaaaaaaa", private_subnet_ids = ["subnet-00000001", "subnet-00000002"], public_subnet_ids = [] }
  }
  plan_options { target = [kubernetes_namespace_v1.sandboxes, helm_release.sandbox_nodes] }
  assert {
    condition     = kubernetes_namespace_v1.sandboxes[0].metadata[0].labels["pod-security.kubernetes.io/enforce"] == "restricted"
    error_message = "Pod Security restricted: the platform's Role can't make a privileged or host pod there."
  }
  assert {
    condition     = yamldecode(helm_release.sandbox_nodes[0].values[0]).objects[2].spec.failurePolicy == "Fail" && yamldecode(helm_release.sandbox_nodes[0].values[0]).objects[2].spec.matchConstraints.resourceRules == [{ apiGroups = [""], apiVersions = ["v1"], operations = ["CREATE"], resources = ["pods"] }]
    error_message = "Every pod created is checked, and the check failing refuses the pod."
  }
  assert {
    condition     = [for v in yamldecode(helm_release.sandbox_nodes[0].values[0]).objects[2].spec.validations : v.expression] == ["has(object.spec.runtimeClassName) && object.spec.runtimeClassName == 'isolated-sandbox'", "has(object.metadata.annotations) && 'sandbox.amazonaws.com/network-isolated' in object.metadata.annotations && object.metadata.annotations['sandbox.amazonaws.com/network-isolated'] == 'true'", "has(object.spec.automountServiceAccountToken) && object.spec.automountServiceAccountToken == false"]
    error_message = "A pod there must be in a Nitro VM, without a network interface and without a token."
  }
  assert {
    condition     = yamldecode(helm_release.sandbox_nodes[0].values[0]).objects[3].spec.policyName == "agent-function-pods" && yamldecode(helm_release.sandbox_nodes[0].values[0]).objects[3].spec.validationActions == ["Deny"] && yamldecode(helm_release.sandbox_nodes[0].values[0]).objects[3].spec.matchResources.namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "agent-functions"
    error_message = "The policy denies, and binds to the sandbox namespace."
  }
}

run "the_aws_sandbox_needs_1_36" {
  command = plan
  variables {
    agent_platform_sandbox = "aws"
    cluster_version        = "1.35"
  }
  plan_options { target = [helm_release.sandbox_nodes] }
  expect_failures = [var.agent_platform_sandbox]
}
