terraform {
  required_version = ">= 1.5"
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = ">= 0.120, < 1.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
  }
}

provider "yandex" {
  cloud_id  = var.cloud_id
  zone      = var.zone
  folder_id = var.folder_id
}

data "yandex_client_config" "client" {}

provider "kubernetes" {
  host                   = module.kube.external_v4_endpoint
  cluster_ca_certificate = module.kube.cluster_ca_certificate
  token                  = data.yandex_client_config.client.iam_token
}

provider "helm" {
  kubernetes = {
    host                   = module.kube.external_v4_endpoint
    cluster_ca_certificate = module.kube.cluster_ca_certificate
    token                  = data.yandex_client_config.client.iam_token
  }
}
