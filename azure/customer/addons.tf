# AKS cluster addons the Arbium chart expects to find pre-installed. This is the
# Azure analogue of the AWS addons.tf (LBC + ESO + Reloader). Because Azure has
# no managed L7 ingress controller or managed cert issuance equivalent to the
# AWS Load Balancer Controller + ACM, we install ingress-nginx (one Standard
# load balancer) and cert-manager here as well.
#
# Controllers only — the custom resources they act on (ClusterSecretStore,
# Ingress, ClusterIssuer) come from the chart / the out-of-band manifests in
# customer/manifests, matching the out-of-band Helm-deploy pattern the AWS/GCP
# roots use.

locals {
  ingress_ip = var.ingress_static_ip_enabled ? azurerm_public_ip.ingress[0].ip_address : ""
  # sslip.io resolves <ip>.sslip.io -> <ip>, giving a real hostname for TLS with
  # no DNS to provision. cert-manager issues against this host via HTTP-01.
  ingress_host = var.ingress_static_ip_enabled ? "${azurerm_public_ip.ingress[0].ip_address}.sslip.io" : ""
}

# ─────────────────────────────────────────────────────────────────────────────
# External Secrets Operator. Runs without cloud perms; the chart's `eso` KSA
# federates to the Terraform-provisioned user-assigned identity (Workload
# Identity) which holds Key Vault Secrets User.
# ─────────────────────────────────────────────────────────────────────────────
resource "helm_release" "eso" {
  count            = var.enable_eso ? 1 : 0
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.eso_chart_version
  namespace        = "external-secrets"
  create_namespace = true

  depends_on = [module.aks]
}

# ─────────────────────────────────────────────────────────────────────────────
# ingress-nginx — a single Standard-SKU Azure load balancer fronting the chart's
# Ingress (className=nginx). Bound to the Terraform-reserved static IP in the
# AKS node resource group so re-installs preserve the address (and the
# <ip>.sslip.io host).
# ─────────────────────────────────────────────────────────────────────────────
resource "helm_release" "ingress_nginx" {
  count            = var.enable_ingress_nginx ? 1 : 0
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.ingress_nginx_chart_version
  namespace        = "ingress-nginx"
  create_namespace = true

  # Conditionals live only at scalar leaves so the two arms of any ternary share
  # a type (Terraform rejects conditional *object* results with differing
  # attribute sets). When ingress_static_ip_enabled is false, local.ingress_ip is
  # "" — which is exactly the ingress-nginx chart's default for
  # controller.service.loadBalancerIP, so the disabled path is a no-op.
  values = [
    yamlencode({
      controller = {
        service = {
          loadBalancerIP = local.ingress_ip
          annotations = {
            "service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path" = "/healthz"
          }
        }
        # Serve the cert-manager-issued cert (secret from manifests/tls-certificate.yaml)
        # as the default TLS cert for every host. The shared chart Ingress does
        # not render spec.tls, so this is how nginx presents a real cert on the
        # sslip.io host without a chart change.
        extraArgs = {
          "default-ssl-certificate" = "${var.arbium_namespace}/chaindb-tls"
        }
      }
    })
  ]

  depends_on = [module.aks, azurerm_public_ip.ingress]
}

# ─────────────────────────────────────────────────────────────────────────────
# cert-manager — issues the TLS cert for the <ip>.sslip.io ingress host via a
# Let's Encrypt ClusterIssuer (HTTP-01 solved through ingress-nginx). The
# ClusterIssuer + Certificate are applied out-of-band from customer/manifests
# (they are custom resources, installed after the CRDs land — same split as the
# AWS/GCP roots leaving the chart's CRs to the deploy step).
# ─────────────────────────────────────────────────────────────────────────────
resource "helm_release" "cert_manager" {
  count            = var.enable_cert_manager ? 1 : 0
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  namespace        = "cert-manager"
  create_namespace = true

  set = [
    {
      name  = "crds.enabled"
      value = "true"
    },
  ]

  depends_on = [module.aks]
}

# ─────────────────────────────────────────────────────────────────────────────
# Stakater Reloader — rolls Deployments the ChainDB chart annotates when the
# chaindb-runtime Secret rotates (ESO re-sync). RBAC-only, identical role to the
# AWS/GCP siblings' reloader.
# ─────────────────────────────────────────────────────────────────────────────
resource "helm_release" "reloader" {
  count            = var.enable_reloader ? 1 : 0
  name             = "reloader"
  repository       = "https://stakater.github.io/stakater-charts"
  chart            = "reloader"
  version          = var.reloader_chart_version
  namespace        = "reloader"
  create_namespace = true

  set = [
    {
      name  = "reloader.watchGlobally"
      value = "true"
    },
    {
      name  = "reloader.reloadOnCreate"
      value = "true"
    },
  ]

  depends_on = [module.aks]
}
