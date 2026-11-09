# The agent platform's AWS side (the chart's agentPlatform component): the IAM role its pods run as,
# the certificate for its own HTTPS name, and its function sandbox (OpenSandbox in the cluster, or AWS). Opt-in; turning the
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
  description = "The platform's HTTPS name (agentPlatform.host), e.g. agents.example.com. Agent Connect's signed events, action links and function callbacks arrive there. Set it to ingress_domain_name to share the install's name, with no certificate of its own (not with the opensandbox sandbox, which the chart refuses)."
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
  default     = "opensandbox"
  description = "Where agent functions run, one per deployment (agentPlatform.sandbox.provider): opensandbox installs the OpenSandbox server in the cluster; aws provisions an AgentCore code interpreter in VPC mode with no network egress, run as a role with no permissions (its gate, AWS_SANDBOX_EXPERIMENT, stays the operator's attestation in Helm values)."
  validation {
    condition     = contains(["opensandbox", "aws"], var.agent_platform_sandbox)
    error_message = "agent_platform_sandbox must be opensandbox or aws."
  }
}

locals {
  agent_platform         = var.enable_agent_platform ? 1 : 0
  agent_platform_sandbox = var.enable_agent_platform && var.agent_platform_sandbox == "aws" ? 1 : 0
  opensandbox            = var.enable_agent_platform && var.agent_platform_sandbox == "opensandbox" ? 1 : 0
  # Merged by the server into every sandbox pod. Lists replace rather than merge, and the server
  # sets containers and volumes itself, so only pod-level fields belong here.
  opensandbox_template = {
    spec = {
      replicas = 1
      template = {
        spec = { restartPolicy = "Never", enableServiceLinks = false }
      }
    }
  }
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
      }],
      local.agent_platform_sandbox == 1 ? [{
        Sid    = "FunctionSandbox"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:GetCodeInterpreter",
          "bedrock-agentcore:StartCodeInterpreterSession",
          "bedrock-agentcore:InvokeCodeInterpreter",
          "bedrock-agentcore:StopCodeInterpreterSession",
        ]
        Resource = aws_bedrockagentcore_code_interpreter.agent_sandbox[0].code_interpreter_arn
    }] : [])
  })
}

# The function sandbox runs as this role, which may do nothing.
resource "aws_iam_role" "agent_sandbox" {
  count = local.agent_platform_sandbox
  name  = "${var.name_prefix}-${var.environment}-agent-sandbox"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
  tags = local.tags
}

# The sandbox can read this role's credentials from its metadata service (measured on IDC, 2026-11-09), and DNS
# lookups leave it, so the credentials could too. An explicit deny keeps them worthless anywhere, even against a
# resource policy that lets in any principal of the account. AgentCore still assumes the role (its trust).
resource "aws_iam_role_policy" "agent_sandbox_deny_all" {
  count = local.agent_platform_sandbox
  name  = "deny-all"
  role  = aws_iam_role.agent_sandbox[0].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Sid = "DenyEverything", Effect = "Deny", Action = "*", Resource = "*" }]
  })
}

# No rule at all: nothing in, nothing out. The platform exchanges files and commands with the
# sandbox through AgentCore's API, never over the network.
resource "aws_security_group" "agent_sandbox" {
  count       = local.agent_platform_sandbox
  name_prefix = "${var.name_prefix}-${var.environment}-agent-sandbox-"
  description = "Agent function sandbox: no inbound, no outbound"
  vpc_id      = local.network.vpc_id
  ingress     = []
  egress      = []
  tags        = merge(local.tags, { Name = "${var.name_prefix}-${var.environment}-agent-sandbox" })
  # The interpreter's network interfaces keep a group for a while after it is gone: a replacement is
  # created before the old one is released.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_bedrockagentcore_code_interpreter" "agent_sandbox" {
  count              = local.agent_platform_sandbox
  name               = replace("${var.name_prefix}_${var.environment}_functions", "-", "_")
  description        = "Agent platform function sandbox: VPC mode, no network egress"
  execution_role_arn = aws_iam_role.agent_sandbox[0].arn
  network_configuration {
    network_mode = "VPC"
    vpc_config {
      security_groups = [aws_security_group.agent_sandbox[0].id]
      subnets         = local.network.private_subnet_ids
    }
  }
  tags = local.tags
}

# OpenSandbox (github.com/opensandbox-group/OpenSandbox): its controller and API server, from the
# release chart vendored in charts/opensandbox (1.2.0, Apache-2.0), images pinned by digest. Only
# its CRDs, controller and server are vendored (not upstream's fast-sandbox runtime, ingress gateway
# or node agent): the platform is the only client and calls the server in-cluster. Each function call or build is a pod in the opensandbox namespace, with an
# egress sidecar that denies everything the call is not allowed to reach.
#
# The server's API key is the Secrets Manager entry opensandbox-api-key (add it to secret_names and
# set its value outside Terraform). The ChainDB chart syncs it into the platform's Secret and into
# this namespace (agentPlatform.sandbox.opensandboxNamespace), so the server starts once the chart
# is installed: Terraform does not wait for it.
resource "kubernetes_namespace_v1" "opensandbox_sandboxes" {
  count = local.opensandbox
  metadata {
    name = "opensandbox"
  }
}

# A second layer under the egress sidecar's per-sandbox domain allowlist (dns+nft), enforced by the
# VPC CNI on the node, outside the pod. Nothing may connect in except the OpenSandbox server, which
# relays every platform call to execd (44772) and the egress sidecar's API (18080) on the pod IP.
# Out: cluster DNS, and public addresses only, so no private range (the VPC, the service network,
# instance metadata, other clusters) is reachable whatever a sandbox's allowlist says. The pod's own
# node is the CNI's one exception (kubelet probes), which the sidecar still blocks.
data "aws_vpc" "network" {
  count = local.opensandbox
  id    = local.network.vpc_id
}

resource "kubernetes_network_policy_v1" "opensandbox_sandboxes" {
  count = local.opensandbox
  metadata {
    name      = "sandboxes"
    namespace = kubernetes_namespace_v1.opensandbox_sandboxes[0].metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = helm_release.opensandbox[0].namespace }
        }
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "opensandbox-server" }
        }
      }
    }

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
        pod_selector {
          match_labels = { "k8s-app" = "kube-dns" }
        }
      }
      ports {
        protocol = "UDP"
        port     = "53"
      }
      ports {
        protocol = "TCP"
        port     = "53"
      }
    }

    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
          except = distinct(concat(
            ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16"],
            [for a in data.aws_vpc.network[0].cidr_block_associations : a.cidr_block],
          ))
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.ingress_scheme != "internal"
      error_message = "OpenSandbox sandboxes reach only public addresses, so their function callbacks cannot reach an internal load balancer: OpenSandbox needs ingress_scheme = \"internet-facing\"."
    }
  }
}

# Every sandbox container gets requests and limits (the egress sidecar and execd installer set none
# of their own), so the quota can count them and no sandbox runs unbounded.
resource "kubernetes_limit_range_v1" "opensandbox_sandboxes" {
  count = local.opensandbox
  metadata {
    name      = "sandboxes"
    namespace = kubernetes_namespace_v1.opensandbox_sandboxes[0].metadata[0].name
  }
  spec {
    # max must cover the sandbox container's 1 CPU / 2Gi (the OpenSandbox SDK's default, which the
    # platform keeps), or every sandbox is refused.
    limit {
      type            = "Container"
      default_request = { cpu = "100m", memory = "128Mi" }
      default         = { cpu = "500m", memory = "512Mi" }
      max             = { cpu = "2", memory = "4Gi" }
    }
  }
}

resource "kubernetes_resource_quota_v1" "opensandbox_sandboxes" {
  count = local.opensandbox
  metadata {
    name      = "sandboxes"
    namespace = kubernetes_namespace_v1.opensandbox_sandboxes[0].metadata[0].name
  }
  # How many sandboxes may run at once and their total CPU and memory. A sandbox over the quota fails
  # to start (the call fails) rather than waiting for room.
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

resource "helm_release" "opensandbox" {
  count            = local.opensandbox
  name             = "opensandbox"
  chart            = "${path.module}/charts/opensandbox"
  namespace        = "opensandbox-system"
  create_namespace = true
  wait             = false
  values = [yamlencode({
    opensandbox-controller = {
      controller = {
        image = {
          repository = "docker.io/opensandbox/controller"
          tag        = "release-1.2.0@sha256:7701db7eacda4c3533a961e0451f6ce067535d8ce46f15765a04dcf0ffa6e2c6"
        }
      }
    }
    opensandbox-server = {
      server = {
        image = {
          repository = "docker.io/opensandbox/server"
          tag        = "release-1.2.0@sha256:25bebdcf1cf7724eb923faecbdbbf82d4038c6ab35c736151574726d14006f30"
        }
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "1", memory = "1Gi" }
        }
        env = [{
          name      = "OPENSANDBOX_SERVER_API_KEY"
          valueFrom = { secretKeyRef = { name = "opensandbox-api-key", key = "api-key" } }
        }]
        # The server reads the template once at start: a change to it rolls the pod.
        podAnnotations = { "checksum/batchsandbox-template" = sha256(yamlencode(local.opensandbox_template)) }
        volumes        = [{ name = "batchsandbox-template", configMap = { name = "opensandbox-batchsandbox-template" } }]
        volumeMounts = [{
          name      = "batchsandbox-template"
          mountPath = "/etc/opensandbox/arbium"
          readOnly  = true
        }]
      }
      configToml = <<-EOT
        [server]
        host = "0.0.0.0"
        port = 80
        [log]
        level = "INFO"
        [runtime]
        type = "kubernetes"
        execd_image = "docker.io/opensandbox/execd:release-1.2.0@sha256:c75836c46ef4302afccec182d5d7339eb2f905f51e3d73b7aa17bb76c832526c"
        [kubernetes]
        namespace = "${kubernetes_namespace_v1.opensandbox_sandboxes[0].metadata[0].name}"
        workload_provider = "batchsandbox"
        batchsandbox_template_file = "/etc/opensandbox/arbium/template.yaml"
        [egress]
        image = "docker.io/opensandbox/egress:release-1.2.0@sha256:a3d30246e557525f3fa44d16226258268cea175532e652822bd1eb4e83e0f54d"
        mode = "dns+nft"
      EOT
    }
    batchsandboxTemplate = local.opensandbox_template
  })]
  # No depends_on: the helm provider already waits for the cluster, and a dependency on module.eks
  # would put every node group in a targeted plan of this release. On a first install in the same
  # apply as the load balancer controller, its webhook may not answer yet: apply again.
}

output "agent_platform" {
  description = "Helm handoff for agentPlatform: the service account role, the certificate (publish its validation record, then add its ARN to ingress.certificateArn), agentPlatform.sandbox.env and, for OpenSandbox, agentPlatform.sandbox.opensandboxNamespace."
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
    sandbox_env = local.agent_platform_sandbox == 1 ? {
      AWS_SANDBOX_INTERPRETER_ARN           = aws_bedrockagentcore_code_interpreter.agent_sandbox[0].code_interpreter_arn
      AWS_SANDBOX_VALIDATED_ROLE            = aws_iam_role.agent_sandbox[0].arn
      AWS_SANDBOX_VALIDATED_SUBNETS         = join(",", local.network.private_subnet_ids)
      AWS_SANDBOX_VALIDATED_SECURITY_GROUPS = aws_security_group.agent_sandbox[0].id
      } : {
      OPENSANDBOX_URL                = "http://opensandbox-server.${helm_release.opensandbox[0].namespace}.svc.cluster.local"
      OPENSANDBOX_ALLOW_PRIVATE_HTTP = "true"
    }
    opensandbox_namespace = local.opensandbox == 1 ? helm_release.opensandbox[0].namespace : null
  } : null
}
