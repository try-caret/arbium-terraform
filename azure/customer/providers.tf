# resource_provider_registrations = "none": the azurerm v4 provider otherwise
# tries to auto-register EVERY RP it supports at plan time and blocks on slow
# ones (e.g. Microsoft.Kusto), which is both unnecessary and a hang risk. The
# RPs this stack actually uses (Microsoft.Network, Microsoft.ContainerService,
# Microsoft.DBforPostgreSQL, Microsoft.KeyVault, Microsoft.ManagedIdentity,
# Microsoft.Compute — plus always-on Microsoft.Resources/Authorization) are
# registered out-of-band on the subscription (see INSTALL.md). This mirrors the
# AWS/GCP siblings, which enable only the specific service APIs they need.
provider "azurerm" {
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
  features {}
}

provider "azuread" {
  tenant_id = var.tenant_id
}

# helm + kubernetes reach the AKS API via kubelogin (azurecli login mode) so the
# providers authenticate with the same Azure AD identity running terraform — no
# static kubeconfig on disk. Mirrors the AWS `aws eks get-token` exec pattern.
# server-id 6dae42f8-4368-4678-94ff-3960e28e3630 is the constant AKS AAD server
# application ID.
provider "helm" {
  kubernetes = {
    host                   = module.aks.host
    cluster_ca_certificate = base64decode(module.aks.cluster_ca_certificate)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "kubelogin"
      args = [
        "get-token",
        "--login", "azurecli",
        "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630",
      ]
    }
  }
}

provider "kubernetes" {
  host                   = module.aks.host
  cluster_ca_certificate = base64decode(module.aks.cluster_ca_certificate)
  exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    args = [
      "get-token",
      "--login", "azurecli",
      "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630",
    ]
  }
}
