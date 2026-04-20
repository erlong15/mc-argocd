output "cluster_id" {
  description = "Managed Kubernetes cluster ID"
  value       = module.kube.cluster_id
}

output "cluster_name" {
  description = "Managed Kubernetes cluster name"
  value       = var.cluster_name
}

output "kubeconfig_command" {
  description = "Run this to merge cluster credentials into ~/.kube/config"
  value       = "yc managed-kubernetes cluster get-credentials --id ${module.kube.cluster_id} --external --force"
}

output "ingress_ip" {
  description = "Static external IPv4 reserved for the Envoy Gateway NLB. DNS A record for var.domain already points here."
  value       = yandex_vpc_address.ingress.external_ipv4_address[0].address
}

output "argocd_url" {
  description = "ArgoCD UI URL. Available after the `infra` ApplicationSet provisions Envoy Gateway + cert-manager + HTTPRoute."
  value       = "https://${var.domain}"
}

output "argocd_initial_admin_password_command" {
  description = "Run this to print ArgoCD initial admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
}
