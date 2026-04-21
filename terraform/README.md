# Terraform: YC Managed Kubernetes + ArgoCD

Поднимает кластер Yandex Managed Kubernetes и ставит в него ArgoCD (Helm chart) + namespaces `demo-dev`, `demo-prod`.

## Требования

- `terraform >= 1.5`
- `yc` CLI с авторизацией (`yc init`)
- `kubectl`, `helm` (для работы с кластером после apply)

## Запуск

```bash
cd terraform
cat > terraform.tfvars <<EOF
cloud_id  = "<ваш cloud_id>"
folder_id = "<ваш folder_id>"
EOF

terraform init
terraform apply
```

Apply идёт ~10–15 мин (кластер YC ~7–10 мин, ArgoCD ~2 мин, LB для argocd-server ~1 мин).

## После apply

```bash
# kubeconfig
eval "$(terraform output -raw kubeconfig_command)"
kubectl get nodes

# URL ArgoCD UI
terraform output argocd_url

# initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

## Уничтожение

⚠️ LoadBalancer `argocd-server` создаёт NetworkLoadBalancer в YC — его нужно удалить ДО `terraform destroy`, иначе destroy зависнет на удалении VPC.

```bash
kubectl -n argocd patch svc argocd-server -p '{"spec":{"type":"ClusterIP"}}'
kubectl -n argocd delete svc argocd-server   # если не помогло
terraform destroy
```

## Что внутри

- `provider.tf` — yandex + helm + kubernetes, auth через `yandex_client_config.iam_token`
- `main.tf` — VPC, subnet, egress gateway, route table, managed k8s через модуль `terraform-yc-modules/terraform-yc-kubernetes@1.1.2`
- `argocd.tf` — namespace `argocd` + `helm_release "argocd"` + namespaces `demo-dev`/`demo-prod` + опциональный Secret с age-ключом для helm-secrets
- `argocd-values.yaml` — values для argo-cd chart, включая init-container, который ставит `sops` / `age` / `helm-secrets` в `argocd-repo-server`
- `variables.tf` — `cloud_id`/`folder_id` без дефолтов (обязательные), остальное с разумными значениями
- `outputs.tf` — cluster_id, kubeconfig команда, argocd_url, команда для пароля

## helm-secrets / SOPS

`argocd-repo-server` запускается с init-container'ом, который кладёт бинари `sops`, `age` и плагин `helm-secrets` в `/custom-tools/` и прокидывает это в `PATH` + `HELM_PLUGINS`. Приватный age-ключ читается из Secret `helm-secrets-private-keys` (key `key.txt`) в namespace `argocd`, путь подставляется через `SOPS_AGE_KEY_FILE`.

### Предварительно: сгенерировать age-ключ

Файл `~/.config/sops/age/keys.txt` не создаётся terraform'ом — это ваш приватный ключ, он должен существовать до apply (если используете вариант (a) ниже) либо до `kubectl create secret` (вариант (b)):

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
grep '# public key:' ~/.config/sops/age/keys.txt   # этот recipient передаётся как `sops --age "$PUBKEY"`
```

### Два способа завести ключ в кластер

```bash
# (a) через terraform: путь в tfvars (terraform прочитает файл через file() и создаст Secret)
# ВАЖНО: tilde ~ в HCL не раскрывается, указывайте абсолютный путь.
echo "age_key_file = \"$HOME/.config/sops/age/keys.txt\"" >> terraform.tfvars
terraform apply

# (b) вручную после apply (если age_key_file пустой)
kubectl -n argocd create secret generic helm-secrets-private-keys \
  --from-file=key.txt=$HOME/.config/sops/age/keys.txt
kubectl -n argocd rollout restart deployment argocd-repo-server
```

Если указали `age_key_file` на несуществующий файл — `terraform plan` упадёт с ошибкой `file not found`. Это ожидаемо: сгенерируйте ключ командой выше и повторите.

Использование в Application/ApplicationSet — ссылаться на values через `secrets://` префикс (helm-secrets v4+) или держать `secrets.yaml` в чарте и указывать `helm.valueFiles: [secrets://secrets.yaml]`.

## Стоимость (ориентировочно)

По умолчанию — **минимальный ценник**: 1 preemptible-нода 4vCPU/8GB + autoscale до 3 при нагрузке.

- master: non-HA zonal
- node group: `preemptible = true`, autoscale 1..3, initial=1
- LoadBalancer для argocd-server

⚠️ Preemptible-ноды YC могут быть вытеснены в любой момент в течение 24ч. Для живого демо это риск «кластер моргнул посреди объяснения». Если это критично — поднять `node_autoscale_initial`/`min` до 2 или переключить на non-preemptible в `main.tf`.
