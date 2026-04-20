resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }

  depends_on = [module.kube]
}

# age приватный ключ для helm-secrets в argocd-repo-server.
# Создаётся только если указана var.age_key_file. Иначе Secret можно создать руками:
#   kubectl -n argocd create secret generic helm-secrets-private-keys \
#     --from-file=key.txt=$HOME/.config/sops/age/keys.txt
resource "kubernetes_secret" "helm_secrets_private_keys" {
  count = var.age_key_file == "" ? 0 : 1

  metadata {
    name      = "helm-secrets-private-keys"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }

  data = {
    "key.txt" = file(var.age_key_file)
  }

  type = "Opaque"
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  timeout          = 600
  atomic           = true
  create_namespace = false

  values = concat(
    [file("${path.module}/argocd-values.yaml")],
    var.argocd_admin_password_bcrypt == "" ? [] : [
      yamlencode({
        configs = {
          secret = {
            argocdServerAdminPassword = var.argocd_admin_password_bcrypt
          }
        }
      })
    ]
  )
}

# Бутстрап-чарт создаёт AppProject "infra" и один ApplicationSet, который на основе
# директорий repo/infra/* генерирует Applications. lbIp прокидывается из
# yandex_vpc_address в helm values ApplicationSet (условно — только для envoy-gateway).
resource "helm_release" "argocd_bootstrap" {
  name      = "argocd-bootstrap"
  namespace = kubernetes_namespace.argocd.metadata[0].name
  chart     = "${path.module}/charts/argocd-bootstrap"

  atomic           = true
  create_namespace = false

  values = [
    yamlencode({
      repoUrl        = var.gitops_repo_url
      targetRevision = "main"
      infraPath      = "repo/infra"
      lbIp           = yandex_vpc_address.ingress.external_ipv4_address[0].address
    })
  ]

  depends_on = [helm_release.argocd]
}

resource "kubernetes_namespace" "demo_dev" {
  metadata {
    name = "demo-dev"
  }
  depends_on = [module.kube]
}

resource "kubernetes_namespace" "demo_prod" {
  metadata {
    name = "demo-prod"
  }
  depends_on = [module.kube]
}

