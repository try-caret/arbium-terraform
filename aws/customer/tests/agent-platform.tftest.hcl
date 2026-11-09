# Run with terraform test -filter=tests/agent-platform.tftest.hcl after backend-disabled init.
# All providers are mocked; these targeted plans never read live state or contact AWS/Kubernetes.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_vpc" {
    override_during = plan
    defaults        = { cidr_block_associations = [{ association_id = "a", cidr_block = "198.18.0.0/24", state = "associated" }] }
  }
  mock_resource "aws_vpc" {
    override_during = plan
    defaults        = { id = "vpc-aaaaaaaa" }
  }
  mock_resource "aws_bedrockagentcore_code_interpreter" {
    override_during = plan
    defaults        = { code_interpreter_arn = "arn:aws:bedrock-agentcore:us-east-1:123456789012:code-interpreter-custom/arbium_test_functions-abcdefghij" }
  }
}
mock_provider "tls" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
override_data {
  target          = data.aws_vpc.network[0]
  override_during = plan
  values          = { cidr_block_associations = [{ association_id = "a", cidr_block = "198.18.0.0/24", state = "associated" }] }
}
override_module {
  target = module.eks
  outputs = {
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/TEST"
    oidc_issuer_url   = "https://oidc.eks.us-east-1.amazonaws.com/id/TEST"
    cluster_name      = "test-cluster"
    cluster_endpoint  = "https://example.invalid"
    cluster_ca_data   = "dGVzdA=="
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
    error_message = "Without the sandbox, the role has no AgentCore access."
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
    agent_platform_sandbox          = "aws"
  }
  plan_options {
    target = [aws_iam_role_policy.agent_platform, aws_bedrockagentcore_code_interpreter.agent_sandbox]
  }
  assert {
    condition     = [for s in jsondecode(aws_iam_role_policy.agent_platform[0].policy).Statement : s.Sid] == ["AssumeModelRole", "FunctionSandbox"]
    error_message = "The role reaches models only through the other account's role, and keeps its own AgentCore access."
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
    agent_platform_sandbox     = "aws"
  }
  plan_options {
    target = [aws_iam_role_policy.agent_platform, aws_acm_certificate.agent_platform, aws_bedrockagentcore_code_interpreter.agent_sandbox, aws_iam_role.agent_sandbox, aws_security_group.agent_sandbox, helm_release.opensandbox]
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

run "sandbox_has_no_network_and_no_permissions" {
  command = plan
  variables { agent_platform_sandbox = "aws" }
  plan_options {
    target = [helm_release.opensandbox, aws_security_group.agent_sandbox, aws_iam_role.agent_sandbox, aws_iam_role_policy.agent_sandbox_deny_all, aws_bedrockagentcore_code_interpreter.agent_sandbox, aws_iam_role_policy.agent_platform]
  }
  assert {
    condition = alltrue([for s in jsondecode(aws_iam_role_policy.agent_sandbox_deny_all[0].policy).Statement :
    s.Effect == "Deny" && s.Action == "*" && s.Resource == "*"]) && length(jsondecode(aws_iam_role_policy.agent_sandbox_deny_all[0].policy).Statement) == 1
    error_message = "The sandbox's role denies everything: its credentials are readable inside the sandbox."
  }
  assert {
    condition     = length(aws_security_group.agent_sandbox[0].ingress) == 0 && length(aws_security_group.agent_sandbox[0].egress) == 0
    error_message = "The sandbox's security group must have no rules."
  }
  assert {
    condition     = aws_bedrockagentcore_code_interpreter.agent_sandbox[0].network_configuration[0].network_mode == "VPC"
    error_message = "The interpreter must run in VPC mode (SANDBOX and PUBLIC modes reach the internet or S3)."
  }
  assert {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,47}$", aws_bedrockagentcore_code_interpreter.agent_sandbox[0].name))
    error_message = "The interpreter name must fit what the platform's AWS sandbox accepts."
  }
  assert {
    condition     = length(helm_release.opensandbox) == 0
    error_message = "One sandbox per deployment: the AWS sandbox installs no OpenSandbox."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.agent_platform[0].policy).Statement[2].Resource == "arn:aws:bedrock-agentcore:us-east-1:123456789012:code-interpreter-custom/arbium_test_functions-abcdefghij"
    error_message = "The platform reaches only its own interpreter."
  }
}

run "refuses_without_a_name_or_models" {
  command = plan
  variables { agent_platform_bedrock_models = [] }
  plan_options { target = [aws_iam_role.agent_platform] }
  expect_failures = [var.enable_agent_platform]
}

run "opensandbox_is_the_default_and_pinned" {
  command = plan
  plan_options {
    target = [helm_release.opensandbox, aws_bedrockagentcore_code_interpreter.agent_sandbox, aws_iam_role_policy.agent_platform]
  }
  assert {
    condition     = length(aws_bedrockagentcore_code_interpreter.agent_sandbox) == 0 && length(jsondecode(aws_iam_role_policy.agent_platform[0].policy).Statement) == 2
    error_message = "One sandbox per deployment: OpenSandbox makes no AgentCore interpreter and grants no AgentCore access."
  }
  assert {
    condition     = length(regexall("@sha256:[a-f0-9]{64}", helm_release.opensandbox[0].values[0])) == 4
    error_message = "Every OpenSandbox image (controller, server, execd, egress) is pinned by digest."
  }
  assert {
    condition     = strcontains(yamldecode(helm_release.opensandbox[0].values[0])["opensandbox-server"].configToml, "mode = \"dns+nft\"")
    error_message = "Sandboxes keep the egress sidecar's DNS and nftables enforcement."
  }
}

run "refuses_an_unknown_sandbox" {
  command = plan
  variables { agent_platform_sandbox = "gcp" }
  plan_options { target = [helm_release.opensandbox] }
  expect_failures = [var.agent_platform_sandbox]
}

run "disabled_by_default" {
  command = plan
  variables { enable_agent_platform = false }
  plan_options {
    target = [aws_iam_role.agent_platform, aws_acm_certificate.agent_platform, aws_bedrockagentcore_code_interpreter.agent_sandbox, helm_release.opensandbox]
  }
  assert {
    condition     = length(aws_iam_role.agent_platform) == 0 && length(aws_acm_certificate.agent_platform) == 0 && length(aws_bedrockagentcore_code_interpreter.agent_sandbox) == 0 && length(helm_release.opensandbox) == 0
    error_message = "Disabled provisioning must create nothing."
  }
}

run "sandboxes_reach_only_public_addresses_and_only_the_server_reaches_them" {
  command = plan
  plan_options {
    target = [kubernetes_network_policy_v1.opensandbox_sandboxes]
  }
  assert {
    condition = toset(kubernetes_network_policy_v1.opensandbox_sandboxes[0].spec[0].egress[1].to[0].ip_block[0].except) == toset([
      "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "198.18.0.0/24",
    ])
    error_message = "Public egress must exclude every private range, link-local metadata and the VPC's own CIDRs."
  }
  assert {
    condition     = length(kubernetes_network_policy_v1.opensandbox_sandboxes[0].spec[0].egress) == 2
    error_message = "Sandboxes get DNS and public egress only."
  }
  assert {
    condition     = kubernetes_network_policy_v1.opensandbox_sandboxes[0].spec[0].ingress[0].from[0].pod_selector[0].match_labels["app.kubernetes.io/name"] == "opensandbox-server" && length(kubernetes_network_policy_v1.opensandbox_sandboxes[0].spec[0].ingress) == 1
    error_message = "Only the OpenSandbox server may connect to a sandbox."
  }
  assert {
    condition     = toset(kubernetes_network_policy_v1.opensandbox_sandboxes[0].spec[0].policy_types) == toset(["Ingress", "Egress"])
    error_message = "The policy must isolate both directions."
  }
}

run "refuses_internal_ingress" {
  command = plan
  variables { ingress_scheme = "internal" }
  plan_options { target = [kubernetes_network_policy_v1.opensandbox_sandboxes] }
  expect_failures = [kubernetes_network_policy_v1.opensandbox_sandboxes]
}

run "sandboxes_are_bounded" {
  command = plan
  plan_options {
    target = [kubernetes_resource_quota_v1.opensandbox_sandboxes, kubernetes_limit_range_v1.opensandbox_sandboxes]
  }
  assert {
    condition     = kubernetes_resource_quota_v1.opensandbox_sandboxes[0].spec[0].hard["pods"] == "30"
    error_message = "The namespace caps concurrent sandboxes."
  }
  assert {
    condition     = kubernetes_limit_range_v1.opensandbox_sandboxes[0].spec[0].limit[0].max["cpu"] == "2" && kubernetes_limit_range_v1.opensandbox_sandboxes[0].spec[0].limit[0].max["memory"] == "4Gi"
    error_message = "The per-container ceiling must still admit the SDK's 1 CPU / 2Gi sandbox container."
  }
}

run "template_tolerates_nothing" {
  command = plan
  plan_options { target = [helm_release.opensandbox] }
  assert {
    condition     = !strcontains(helm_release.opensandbox[0].values[0], "tolerations") && strcontains(helm_release.opensandbox[0].values[0], "/etc/opensandbox/arbium/template.yaml")
    error_message = "The server uses Arbium's template, which drops the example's blanket toleration."
  }
}
