output "cluster_id" {
  value = azurerm_kubernetes_cluster.this.id
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "node_resource_group" {
  description = "AKS-managed resource group (MC_*). The ingress static IP is created here so the cluster's load balancer can attach it without extra RBAC."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL for Workload Identity federated credentials."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "host" {
  description = "AKS API server endpoint."
  value       = azurerm_kubernetes_cluster.this.kube_config[0].host
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Cluster CA certificate (base64) for the helm/kubernetes providers."
  value       = azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate
  sensitive   = true
}

output "kubelet_identity_object_id" {
  description = "Object ID of the kubelet (node) managed identity."
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

output "cluster_identity_principal_id" {
  description = "Principal ID of the cluster's system-assigned identity."
  value       = azurerm_kubernetes_cluster.this.identity[0].principal_id
}
