# YC service account для cert-manager-webhook-yandex.
# Сам webhook ставит ArgoCD (repo/infra/cert-manager-webhook-yc — вендорный чарт).
# Terraform отвечает только за credentials DNS-01 challenge: SA, роль, ключ и k8s Secret.
#
# Мы сознательно вендорили чарт без secret.yaml — Secret `cm-sa-creds` в ns infra
# единолично принадлежит terraform (иначе helm перепишет содержимое в {}).

resource "yandex_iam_service_account" "cert_manager" {
  folder_id   = var.folder_id
  name        = "cert-manager-webhook"
  description = "Used by cert-manager-webhook-yandex to solve DNS-01 challenges"
}

resource "yandex_resourcemanager_folder_iam_member" "cert_manager_dns_editor" {
  folder_id = var.folder_id
  role      = "dns.editor"
  member    = "serviceAccount:${yandex_iam_service_account.cert_manager.id}"
}

resource "yandex_iam_service_account_key" "cert_manager" {
  service_account_id = yandex_iam_service_account.cert_manager.id
  description        = "cert-manager-webhook-yandex DNS-01 key"
  key_algorithm      = "RSA_2048"
}

# JSON того же формата, что `yc iam key create --output` — webhook читает его как authorized_key.
locals {
  cert_manager_sa_key_json = jsonencode({
    id                 = yandex_iam_service_account_key.cert_manager.id
    service_account_id = yandex_iam_service_account_key.cert_manager.service_account_id
    created_at         = yandex_iam_service_account_key.cert_manager.created_at
    key_algorithm      = yandex_iam_service_account_key.cert_manager.key_algorithm
    public_key         = yandex_iam_service_account_key.cert_manager.public_key
    private_key        = yandex_iam_service_account_key.cert_manager.private_key
  })
}

# ns infra создаёт terraform, а не CreateNamespace=true из ApplicationSet —
# иначе Secret некуда класть на момент первого apply.
resource "kubernetes_namespace" "infra" {
  metadata {
    name = "infra"
  }
  depends_on = [module.kube]
}

resource "kubernetes_secret" "cm_sa_creds" {
  metadata {
    name      = "cm-sa-creds"
    namespace = kubernetes_namespace.infra.metadata[0].name
  }
  type = "Opaque"
  data = {
    "key.json" = local.cert_manager_sa_key_json
  }

  depends_on = [yandex_resourcemanager_folder_iam_member.cert_manager_dns_editor]
}
