locals {
  name = "${var.name_prefix}-${var.environment}"
}

data "azurerm_client_config" "current" {}

# AKS cluster with OIDC issuer + Workload Identity — the Azure analogue of GKE
# Workload Identity and EKS IRSA. ESO (and any other in-cluster workload)
# federates a Kubernetes ServiceAccount to a user-assigned managed identity via
# the OIDC issuer, so no long-lived cloud credentials live in the cluster.
#
# ONE general node pool only (cost-minimal). No GPU pool — the embedder runs on
# CPU (embedder-cpu image) on this same pool, unlike the AWS/GCP siblings which
# provision an optional GPU pool.
resource "azurerm_kubernetes_cluster" "this" {
  name                = local.name
  resource_group_name = var.resource_group_name
  location            = var.location
  dns_prefix          = local.name

  # SKU Free is the cheapest control-plane tier (no uptime SLA) — appropriate
  # for a single dev cluster. Bump to Standard for production HA.
  sku_tier = var.sku_tier

  kubernetes_version = var.kubernetes_version

  # Workload Identity federation surface.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Keep the local admin kubeconfig available as an operator fallback; AAD +
  # Azure RBAC is the primary auth path (see providers.tf kubelogin exec).
  local_account_disabled = false

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = var.tenant_id
  }

  identity {
    type = "SystemAssigned"
  }

  default_node_pool {
    name                 = "general"
    vm_size              = var.general_node_vm_size
    vnet_subnet_id       = var.aks_subnet_id
    auto_scaling_enabled = true
    min_count            = var.general_node_min_count
    max_count            = var.general_node_max_count
    node_count           = var.general_node_min_count
    os_sku               = "Ubuntu"
    os_disk_size_gb      = var.general_node_disk_size_gb
    max_pods             = 60

    # Required when mutating an immutable default-node-pool field so AKS can
    # cycle in a temporary pool instead of failing the update.
    temporary_name_for_rotation = "generaltmp"

    upgrade_settings {
      max_surge = "10%"
    }
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    load_balancer_sku = "standard"
    # All node egress routes through the network module's NAT gateway; the
    # cluster's single Standard load balancer is used for inbound ingress only.
    outbound_type = var.enable_nat_gateway_egress ? "userAssignedNATGateway" : "loadBalancer"
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count, # cluster-autoscaler owns this at runtime
    ]
  }
}

# BYO-VNet: the node subnet lives in the Arbium resource group, not the AKS
# managed (MC_*) group, so AKS's control-plane identity is not automatically
# granted rights on it. The cloud-provider needs Microsoft.Network/.../subnets/
# join/action to wire the Standard load balancer for a LoadBalancer Service
# (ingress-nginx) — without it the LB sync fails LinkedAuthorizationFailed and
# the Service IP never binds. Network Contributor on the subnet grants exactly
# that. Azure analogue of the AWS/GCP siblings granting the cluster's node
# networking permissions on the shared VPC/subnet.
resource "azurerm_role_assignment" "cluster_subnet_network_contributor" {
  scope                = var.aks_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.identity[0].principal_id
}

# Grant the deploying principal cluster-admin over Kubernetes RBAC so the helm /
# kubernetes providers (kubelogin azurecli exec) can install the addons in the
# same apply. Analogous to the AWS/GCP operator already holding cluster access.
resource "azurerm_role_assignment" "deployer_cluster_admin" {
  count = var.grant_deployer_cluster_admin ? 1 : 0

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}
