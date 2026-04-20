variable "cloud_id" {
  type        = string
  description = "Yandex Cloud cloud_id"
}

variable "folder_id" {
  type        = string
  description = "Yandex Cloud folder_id"
}

variable "zone" {
  type        = string
  description = "Availability zone"
  default     = "ru-central1-a"
}

variable "cluster_name" {
  type        = string
  description = "Managed Kubernetes cluster name"
  default     = "argocd-masterclass"
}

variable "network_cidr" {
  type        = string
  description = "CIDR for the VPC subnet"
  default     = "10.10.0.0/16"
}

variable "node_cores" {
  type        = number
  description = "vCPU per node in the demo node group"
  default     = 4
}

variable "node_memory_gb" {
  type        = number
  description = "RAM (GB) per node in the demo node group"
  default     = 8
}

variable "node_autoscale_min" {
  type        = number
  description = "Min nodes in autoscaling group"
  default     = 1
}

variable "node_autoscale_max" {
  type        = number
  description = "Max nodes in autoscaling group"
  default     = 3
}

variable "node_autoscale_initial" {
  type        = number
  description = "Initial nodes in autoscaling group"
  default     = 1
}

variable "argocd_chart_version" {
  type        = string
  description = "Version of argo-cd Helm chart"
  default     = "9.5.2"
}

variable "argocd_admin_password_bcrypt" {
  type        = string
  description = "Optional bcrypt hash for ArgoCD admin password. If empty, stock initial-admin-secret is used."
  default     = ""
  sensitive   = true
}

variable "dns_zone_name" {
  type        = string
  description = "Name of the Yandex Cloud DNS zone that serves the parent domain (e.g. `erlong-ru` for `erlong.ru.`). Used to create the A record for argocd."
  default     = "erlong-ru"
}

variable "domain" {
  type        = string
  description = "FQDN at which ArgoCD UI is served. Must be inside the zone referenced by var.dns_zone_name."
  default     = "argocd.erlong.ru"
}

variable "gitops_repo_url" {
  type        = string
  description = "Git repository URL that ArgoCD pulls from. Defaults to this masterclass repo; override to point at your own fork."
  default     = "https://github.com/erlong15/mc-argocd.git"
}

variable "age_key_file" {
  type        = string
  description = "Absolute path to local age private key file. Generate it first via `age-keygen -o ~/.config/sops/age/keys.txt`. If set, it is loaded into Secret `helm-secrets-private-keys` (namespace argocd) so argocd-repo-server can decrypt via helm-secrets. Leave empty to skip (then create the Secret manually after apply). NOTE: tilde `~` is not expanded in HCL — pass an absolute path."
  default     = ""

  validation {
    condition     = var.age_key_file == "" || fileexists(var.age_key_file)
    error_message = "age_key_file points to a file that does not exist. Generate it first: `age-keygen -o ~/.config/sops/age/keys.txt`, then pass the absolute path."
  }
}

