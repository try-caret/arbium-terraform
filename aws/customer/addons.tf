# EKS cluster addons that the Arbium chart expects to find pre-installed:
#
#   - AWS Load Balancer Controller (LBC): turns the chart's Ingress
#     (className=alb) into a real ALB. Without it, ingress.enabled=true is a
#     no-op and the cluster has no way to expose itself.
#
#   - External Secrets Operator (ESO): the chart's externalSecrets template
#     (when enabled with provider=aws) renders ExternalSecret + ClusterSecret-
#     Store resources that ESO reconciles into Kubernetes Secrets pulled from
#     AWS Secrets Manager.
#
# Both are toggleable. Customers running their own ingress (NLB direct, ALB
# managed outside terraform, etc.) can disable LBC; customers managing their
# own secret stuffing can disable ESO.

locals {
  oidc_issuer_host = replace(module.eks.oidc_issuer_url, "https://", "")
}

# ─────────────────────────────────────────────────────────────────────────────
# AWS Load Balancer Controller
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "lbc_assume" {
  count = var.enable_lb_controller ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lbc" {
  count              = var.enable_lb_controller ? 1 : 0
  name               = "${var.name_prefix}-${var.environment}-lbc"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume[0].json
}

resource "aws_iam_policy" "lbc" {
  count       = var.enable_lb_controller ? 1 : 0
  name        = "${var.name_prefix}-${var.environment}-lbc"
  description = "AWS Load Balancer Controller permissions (kubernetes-sigs/aws-load-balancer-controller v2.8.2)"
  policy      = file("${path.module}/policies/aws-lb-controller-iam.json")
}

resource "aws_iam_role_policy_attachment" "lbc" {
  count      = var.enable_lb_controller ? 1 : 0
  role       = aws_iam_role.lbc[0].name
  policy_arn = aws_iam_policy.lbc[0].arn
}

resource "helm_release" "lb_controller" {
  count            = var.enable_lb_controller ? 1 : 0
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = var.lb_controller_chart_version
  namespace        = "kube-system"
  create_namespace = false

  set = [
    {
      name  = "clusterName"
      value = module.eks.cluster_name
    },
    {
      name  = "region"
      value = var.aws_region
    },
    {
      name  = "vpcId"
      value = module.network.vpc_id
    },
    {
      name  = "serviceAccount.create"
      value = "true"
    },
    {
      name  = "serviceAccount.name"
      value = "aws-load-balancer-controller"
    },
    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.lbc[0].arn
    },
  ]

  depends_on = [
    aws_iam_role_policy_attachment.lbc,
    module.eks,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# External Secrets Operator (controller) + IRSA role for the `eso` KSA
# ─────────────────────────────────────────────────────────────────────────────
#
# The operator itself runs without AWS perms; the IRSA role is on the SA the
# ChainDB chart creates (`eso` in the `arbium` namespace), which ESO
# impersonates when calling Secrets Manager via the chart's ClusterSecretStore.

resource "helm_release" "eso" {
  count            = var.enable_eso ? 1 : 0
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.eso_chart_version
  namespace        = "external-secrets"
  create_namespace = true

  # LBC must be Ready before ESO installs — LBC's MutatingWebhookConfiguration
  # intercepts every Service create cluster-wide. If LBC's webhook backend
  # pod isn't yet up when ESO tries to create its Services, we hit
  # `no endpoints available for service "aws-load-balancer-webhook-service"`.
  depends_on = [
    module.eks,
    helm_release.lb_controller,
  ]
}

data "aws_iam_policy_document" "arbium_eso_assume" {
  count = var.enable_eso ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      # KSA: `eso` in the namespace where the chart is installed
      # (defaults to "arbium"; override via var.arbium_namespace).
      values = ["system:serviceaccount:${var.arbium_namespace}:eso"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "arbium_eso_secrets" {
  count = var.enable_eso ? 1 : 0

  statement {
    sid    = "ReadArbiumSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.name_prefix}/${var.environment}/*",
    ]
  }
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "arbium_eso" {
  count              = var.enable_eso ? 1 : 0
  name               = "${var.name_prefix}-${var.environment}-arbium-eso"
  assume_role_policy = data.aws_iam_policy_document.arbium_eso_assume[0].json
}

resource "aws_iam_policy" "arbium_eso" {
  count       = var.enable_eso ? 1 : 0
  name        = "${var.name_prefix}-${var.environment}-arbium-eso"
  description = "Read-only on arbium/<env>/* Secrets Manager containers, assumed by the arbium-eso KSA via IRSA"
  policy      = data.aws_iam_policy_document.arbium_eso_secrets[0].json
}

resource "aws_iam_role_policy_attachment" "arbium_eso" {
  count      = var.enable_eso ? 1 : 0
  role       = aws_iam_role.arbium_eso[0].name
  policy_arn = aws_iam_policy.arbium_eso[0].arn
}

# ─────────────────────────────────────────────────────────────────────────────
# NVIDIA Device Plugin
# Required so embedder pods on g5/g6 nodes can request nvidia.com/gpu.
# ─────────────────────────────────────────────────────────────────────────────

resource "helm_release" "nvidia_device_plugin" {
  count = var.enable_nvidia_device_plugin ? 1 : 0

  name       = "nvidia-device-plugin"
  namespace  = "kube-system"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  version    = var.nvidia_device_plugin_chart_version

  values = [
    yamlencode({
      nodeSelector = {
        workload = "embedder"
      }
      tolerations = [
        {
          key      = "workload"
          operator = "Equal"
          value    = "embedder"
          effect   = "NoSchedule"
        }
      ]
    })
  ]

  depends_on = [module.eks]
}
