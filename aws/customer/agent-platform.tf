# The agent platform's AWS side (the chart's agentPlatform component): the IAM role its pods run as,
# the certificate for its own HTTPS name, and its function sandbox (Nitro sandbox pods in the cluster). Opt-in; turning the
# component on is a separate Helm change that takes the agent_platform output.
variable "enable_agent_platform" {
  type        = bool
  default     = false
  description = "Provision the agent platform's IAM role and certificate."
  validation {
    condition     = !var.enable_agent_platform || (trimspace(var.agent_platform_domain_name) != "" && (var.agent_platform_bedrock_role_arn != null || length(var.agent_platform_bedrock_models) > 0))
    error_message = "The agent platform needs agent_platform_domain_name, and its models: at least one in agent_platform_bedrock_models, or agent_platform_bedrock_role_arn."
  }
}

variable "agent_platform_domain_name" {
  type        = string
  default     = ""
  description = "The platform's HTTPS name (agentPlatform.host), e.g. agents.example.com. Agent Connect's signed events, action links and function callbacks arrive there. Set it to ingress_domain_name to share the install's name, with no certificate of its own."
}

variable "agent_platform_bedrock_models" {
  type        = list(string)
  default     = []
  description = "Bedrock inference profile IDs the platform may call (its agentPlatform.model.routes targets), e.g. us.anthropic.claude-sonnet-5-5."
  validation {
    condition     = alltrue([for id in var.agent_platform_bedrock_models : can(regex("^(us|eu|apac|global)\\.[a-z0-9.-]+$", id))])
    error_message = "Use cross-region inference profile IDs such as us.anthropic.claude-sonnet-5-5."
  }
}

variable "agent_platform_bedrock_role_arn" {
  type        = string
  default     = null
  description = "A role in another AWS account that serves the platform's models (BEDROCK_ROLE_ARN in agentPlatform.env). The platform's role may then only assume it and has no Bedrock access of its own; that role's trust policy must name the platform's role too. Null = the platform calls agent_platform_bedrock_models in this account."
}

variable "agent_platform_sandbox" {
  type        = string
  default     = "none"
  description = "Where agent functions run (agentPlatform.sandbox.provider): aws runs each call in a pod of its own inside a Nitro sandbox (a VM with its own kernel, runtimeClassName isolated-sandbox) on Auto Mode nodes kept for sandboxes, and needs cluster_version 1.36 or later (it turns on EKS Auto Mode with no built-in node pools); none provisions no sandbox, and functions stay off."
  validation {
    condition     = contains(["aws", "none"], var.agent_platform_sandbox)
    error_message = "agent_platform_sandbox must be aws or none."
  }
  validation {
    condition     = var.agent_platform_sandbox != "aws" || tonumber(split(".", var.cluster_version)[1]) >= 36
    error_message = "agent_platform_sandbox = \"aws\" needs cluster_version 1.36 or later, for Nitro sandboxes."
  }
}

locals {
  agent_platform = var.enable_agent_platform ? 1 : 0
  aws_sandbox    = var.enable_agent_platform && var.agent_platform_sandbox == "aws" ? 1 : 0
  # Where function pods run (agentPlatform.sandbox.namespace).
  sandbox_namespace = "agent-functions"
  # A profile routes to its model in several regions: allow the model there, only through the profiles.
  agent_platform_profile_arns = [
    for id in var.agent_platform_bedrock_models :
    "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${id}"
  ]
  agent_platform_model_arns = flatten([
    for id in var.agent_platform_bedrock_models : [
      "arn:aws:bedrock:*::foundation-model/${replace(id, "/^[a-z]+\\./", "")}*",
      "arn:aws:bedrock:::foundation-model/${replace(id, "/^[a-z]+\\./", "")}*",
    ]
  ])
}

resource "aws_acm_certificate" "agent_platform" {
  count             = var.enable_agent_platform && var.agent_platform_domain_name != var.ingress_domain_name ? 1 : 0
  domain_name       = var.agent_platform_domain_name
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
  tags = local.tags
}

resource "aws_iam_role" "agent_platform" {
  count = local.agent_platform
  name  = "${var.name_prefix}-${var.environment}-agent-platform"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = module.eks.oidc_provider_arn }
      Condition = { StringEquals = {
        "${local.oidc_issuer_host}:sub" = "system:serviceaccount:${var.arbium_namespace}:agent-platform"
        "${local.oidc_issuer_host}:aud" = "sts.amazonaws.com"
      } }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "agent_platform" {
  count = local.agent_platform
  name  = "agent-platform"
  role  = aws_iam_role.agent_platform[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      var.agent_platform_bedrock_role_arn == null ? [] : [{
        Sid      = "AssumeModelRole"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = var.agent_platform_bedrock_role_arn
      }],
      var.agent_platform_bedrock_role_arn != null ? [] : [{
        Sid      = "Profiles"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = local.agent_platform_profile_arns
      }],
      var.agent_platform_bedrock_role_arn != null ? [] : [{
        Sid       = "ModelsThroughProfiles"
        Effect    = "Allow"
        Action    = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource  = local.agent_platform_model_arns
        Condition = { StringLike = { "bedrock:InferenceProfileArn" = local.agent_platform_profile_arns } }
      }]
    )
  })
}

# The function sandbox: each call is one pod in this namespace, which the platform creates and
# deletes itself (ChainDB/agent-platform/sandbox/aws.ts), in a Nitro sandbox of its own. Nothing
# else runs here and no Secret lives here. Pod Security `restricted` and the admission policy in
# helm_release.sandbox_nodes bound what the platform's Role can make here, even if the platform is
# compromised: no privileged or host pods, and every pod in a Nitro VM with no network or token.
resource "kubernetes_namespace_v1" "sandboxes" {
  count = local.aws_sandbox
  metadata {
    name   = local.sandbox_namespace
    labels = { "pod-security.kubernetes.io/enforce" = "restricted" }
  }
}

# Nothing in or out. A function pod has no network interface at all (the platform asks for a VM
# without one and talks to it through the Kubernetes API, and the admission policy below refuses a
# pod without that). This policy states the same; it is enforced only where the cluster's VPC CNI
# enforces network policies, which the aws sandbox does not turn on.
resource "kubernetes_network_policy_v1" "sandboxes" {
  count = local.aws_sandbox
  metadata {
    name      = "sandboxes"
    namespace = kubernetes_namespace_v1.sandboxes[0].metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

# How many function pods may run at once and their total CPU and memory. A pod over the quota is
# refused (the call fails) rather than waiting for room.
resource "kubernetes_resource_quota_v1" "sandboxes" {
  count = local.aws_sandbox
  metadata {
    name      = "sandboxes"
    namespace = kubernetes_namespace_v1.sandboxes[0].metadata[0].name
  }
  spec {
    hard = {
      pods              = "30"
      "requests.cpu"    = "16"
      "requests.memory" = "40Gi"
      "limits.cpu"      = "32"
      "limits.memory"   = "64Gi"
    }
  }
}

# All the platform may do in the cluster: make, read and delete pods here, and open the exec stream
# that carries a call into its pod.
resource "kubernetes_role_v1" "sandboxes" {
  count = local.aws_sandbox
  metadata {
    name      = "agent-platform"
    namespace = kubernetes_namespace_v1.sandboxes[0].metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["create", "get", "delete"]
  }
  # The exec stream is a WebSocket upgrade, which EKS 1.36 authorizes as `get`; Kubernetes is moving
  # it to `create` (AuthorizePodWebsocketUpgradeCreatePermission), so both.
  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create", "get"]
  }
}

resource "kubernetes_role_binding_v1" "sandboxes" {
  count = local.aws_sandbox
  metadata {
    name      = "agent-platform"
    namespace = kubernetes_namespace_v1.sandboxes[0].metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.sandboxes[0].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "agent-platform"
    namespace = var.arbium_namespace
  }
}

# The Auto Mode nodes function pods run on, tainted for them only (the platform's pods tolerate it).
# A static pool: one node is always up, so a call never waits for a node to boot.
# ponytail: one node holds about ten function pods at once (the 16 GiB floor); add a second, scaling
# NodePool for bursts when calls start waiting. Their kinds exist only once Auto Mode is on, which
# is why they go through a chart and not kubernetes_manifest: if this release applies first, apply again.
resource "helm_release" "sandbox_nodes" {
  count     = local.aws_sandbox
  name      = "sandbox-nodes"
  chart     = "${path.module}/charts/sandbox-nodes"
  namespace = kubernetes_namespace_v1.sandboxes[0].metadata[0].name
  wait      = false
  values = [yamlencode({
    objects = [
      {
        apiVersion = "eks.amazonaws.com/v1"
        kind       = "NodeClass"
        metadata   = { name = "sandboxes" }
        spec = {
          role                       = module.eks.auto_node_role_name
          subnetSelectorTerms        = [for id in local.network.private_subnet_ids : { id = id }]
          securityGroupSelectorTerms = [{ id = module.eks.cluster_security_group_id }]
          tags                       = local.tags
        }
      },
      {
        apiVersion = "karpenter.sh/v1"
        kind       = "NodePool"
        metadata   = { name = "sandboxes" }
        spec = {
          replicas = 1
          limits   = { nodes = 2 } # room to replace the node on an AMI update
          template = {
            metadata = { labels = { workload = "sandbox" } }
            spec = {
              nodeClassRef = { group = "eks.amazonaws.com", kind = "NodeClass", name = "sandboxes" }
              taints       = [{ key = "workload", value = "sandbox", effect = "NoSchedule" }]
              requirements = [
                { key = "eks.amazonaws.com/nitro-sandbox", operator = "In", values = ["true"] },
                { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
                { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
                { key = "eks.amazonaws.com/instance-category", operator = "In", values = ["m", "c", "r"] },
                { key = "eks.amazonaws.com/instance-memory", operator = "Gt", values = ["15000"] },
              ]
            }
          }
        }
      },
      # Every pod made in the namespace is a function pod: in a Nitro VM, without a network interface,
      # without a service account token. Pod fields are fixed at creation, so creation is checked.
      {
        apiVersion = "admissionregistration.k8s.io/v1"
        kind       = "ValidatingAdmissionPolicy"
        metadata   = { name = "agent-function-pods" }
        spec = {
          failurePolicy = "Fail"
          matchConstraints = {
            resourceRules = [{ apiGroups = [""], apiVersions = ["v1"], operations = ["CREATE"], resources = ["pods"] }]
          }
          validations = [
            {
              expression = "has(object.spec.runtimeClassName) && object.spec.runtimeClassName == 'isolated-sandbox'"
              message    = "A function pod runs in a Nitro sandbox (runtimeClassName isolated-sandbox)."
            },
            {
              expression = "has(object.metadata.annotations) && 'sandbox.amazonaws.com/network-isolated' in object.metadata.annotations && object.metadata.annotations['sandbox.amazonaws.com/network-isolated'] == 'true'"
              message    = "A function pod has no network interface (sandbox.amazonaws.com/network-isolated: \"true\")."
            },
            {
              expression = "has(object.spec.automountServiceAccountToken) && object.spec.automountServiceAccountToken == false"
              message    = "A function pod has no service account token."
            },
          ]
        }
      },
      {
        apiVersion = "admissionregistration.k8s.io/v1"
        kind       = "ValidatingAdmissionPolicyBinding"
        metadata   = { name = "agent-function-pods" }
        spec = {
          policyName        = "agent-function-pods"
          validationActions = ["Deny"]
          matchResources = {
            namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = local.sandbox_namespace } }
          }
        }
      },
    ]
  })]
  # No depends_on: the helm provider already waits for the cluster, and a dependency on module.eks
  # would put every node group in a targeted plan of this release.
}

output "agent_platform" {
  description = "Helm handoff for agentPlatform: the service account role, the certificate (publish its validation record, then add its ARN to ingress.certificateArn) and, for the aws sandbox, agentPlatform.sandbox.namespace and agentPlatform.sandbox.env (add the image and, after the isolation checks, the gate)."
  value = var.enable_agent_platform ? {
    role_arn        = aws_iam_role.agent_platform[0].arn
    certificate_arn = one(aws_acm_certificate.agent_platform[*].arn)
    certificate_validation_records = [
      for option in flatten(aws_acm_certificate.agent_platform[*].domain_validation_options) : {
        name  = option.resource_record_name
        type  = option.resource_record_type
        value = option.resource_record_value
      }
    ]
    sandbox_namespace = local.aws_sandbox == 1 ? local.sandbox_namespace : null
    # The runtime class EKS Auto Mode makes for Nitro sandboxes.
    sandbox_env = local.aws_sandbox == 1 ? tomap({ AWS_SANDBOX_RUNTIME_CLASS = "isolated-sandbox" }) : tomap({})
  } : null
}
