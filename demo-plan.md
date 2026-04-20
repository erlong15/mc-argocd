# План демонстрации ArgoCD

Кластер: Yandex Managed Kubernetes, поднятый через `terraform/`. ArgoCD устанавливается тем же `terraform apply` (Helm chart).

## Цель демо

Показать минимальный GitOps-цикл:
- кластер + ArgoCD из Terraform
- подключение репозитория
- деплой Helm-приложения в dev/prod через ApplicationSet
- manual sync → переключение на automated + self-heal
- drift detection / self-heal / rollback через `git revert`
- pipeline шифрования секретов (SOPS)

**Общее время:** ~45–55 мин (из них 10–15 мин ждём `terraform apply`).

---

## 0. Pre-flight checklist

```bash
terraform -v       # >= 1.5
yc --version
yc config list     # должен быть cloud_id + folder_id + token
kubectl version --client
helm version
argocd version --client
sops --version
age --version
git --version
```

Проверить:
- доступ в интернет до `github.com` и `argoproj.github.io`
- создан пустой Git remote под демо-репо (GitHub/GitLab)
- в `~/.ssh` есть ключ, пробрасываемый на remote (или HTTPS + токен)

Brew-установка недостающего:

```bash
brew install argocd sops age
```

---

## 1. Поднять кластер + ArgoCD (5 мин на ввод, 10–15 мин ждать)

```bash
cd terraform
cat > terraform.tfvars <<EOF
cloud_id  = "<ваш cloud_id>"
folder_id = "<ваш folder_id>"
EOF

terraform init
terraform apply
```

Пока идёт apply — показываем слайды 1–7.

После apply:

```bash
eval "$(terraform output -raw kubeconfig_command)"
kubectl config current-context
kubectl get nodes
kubectl get pods -n argocd
```

**Что должен увидеть зритель:** 2 Ready-ноды, ~7 Running-подов в `argocd`.

---

## 2. Открыть UI и получить пароль (2 мин)

```bash
terraform output argocd_url               # http://<LB_IP>
terraform output argocd_initial_admin_password_command
# выполнить то, что в output:
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Логин в UI (`admin` / выданный пароль) и CLI:

```bash
argocd login "$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" \
  --username admin --password '<PASTE_PASSWORD>' --insecure
argocd account get-user-info
```

⚠️ `--insecure` — потому что чарт поставлен с `server.insecure=true` и self-signed TLS. В проде ставим normal TLS / Ingress с валидным сертификатом.

**Что должен увидеть зритель:** пустой список Applications в UI.

---

## 3. Подготовить Git-репозиторий (3 мин)

Содержимое `repo/` мастеркласса должно жить в **отдельном** Git-репозитории (ArgoCD подключается к нему извне). Копируем наружу, чтобы не конфликтовать с родительским репо:

```bash
cp -r ../repo /tmp/argocd-masterclass-demo
cd /tmp/argocd-masterclass-demo
```

Подменить плейсхолдер на ваш remote URL:

```bash
export REMOTE='git@github.com:<you>/argocd-masterclass-demo.git'
sed -i.bak "s|https://github.com/example/argocd-masterclass-demo.git|${REMOTE}|g" \
  bootstrap/project.yaml apps/appset-nginx.yaml
find . -name '*.bak' -delete
```

Инициализация и push:

```bash
git init && git branch -M main
git add .
git commit -m "initial argocd demo"
git remote add origin "$REMOTE"
git push -u origin main
```

---

## 4. Создать AppProject (1 мин)

```bash
kubectl apply -f bootstrap/project.yaml
kubectl get appprojects -n argocd workshop
```

Пояснить:
- ограничили `sourceRepos` → только наш remote
- ограничили `destinations` → только namespaces `demo-dev`, `demo-prod`
- ограничили kinds в whitelist (безопасная рамка multi-tenancy)

Namespaces `demo-dev` / `demo-prod` уже созданы terraform'ом (см. `terraform/argocd.tf`).

---

## 5. Развернуть ApplicationSet без auto-sync (3 мин)

ApplicationSet в `apps/appset-nginx.yaml` умышленно без `automated` — сначала показываем manual sync.

```bash
kubectl apply -f apps/appset-nginx.yaml
kubectl get applicationset -n argocd
kubectl get applications -n argocd
argocd app list
```

**Что должен увидеть зритель:** появились `nginx-dev` и `nginx-prod` со статусом `OutOfSync` / `Missing`.

---

## 6. Manual sync (2 мин)

```bash
argocd app sync nginx-dev
argocd app sync nginx-prod
argocd app get nginx-dev
kubectl get deploy,svc,cm -n demo-dev
kubectl get deploy,svc,cm -n demo-prod
```

Показать в UI дерево ресурсов (это главный визуальный аргумент ArgoCD).

Пояснить различия prod vs dev:
- разные `replicaCount` (1 vs 2)
- разные resources
- один chart, два env — вся разница в `environments/<env>/config.json`

---

## 7. Включить auto-sync + self-heal (2 мин)

В `apps/appset-nginx.yaml` раскомментировать блок `syncPolicy.automated`:

```bash
sed -i.bak '/# syncPolicy:/,/# *- CreateNamespace=true/ s/^\( *\)# /\1/' \
  apps/appset-nginx.yaml
rm apps/appset-nginx.yaml.bak
git add apps/appset-nginx.yaml
git commit -m "enable auto-sync + self-heal"
git push
kubectl apply -f apps/appset-nginx.yaml
```

Проговорить риски:
- `prune: true` удаляет ресурсы, пропавшие из Git
- `selfHeal: true` затирает ручные изменения
- в проде прикрывается sync windows + `ignoreDifferences`

---

## 8. Изменение через Git (3 мин)

Поменять в `environments/dev/config.json` `replicaCount` с 1 на 2 — откройте в редакторе или:

```bash
jq '.replicaCount = 2' environments/dev/config.json > .tmp && mv .tmp environments/dev/config.json
git add environments/dev/config.json
git commit -m "scale dev to 2 replicas"
git push
```

Проверка:

```bash
argocd app get nginx-dev
kubectl get deploy -n demo-dev
```

**Что должен увидеть зритель:** через ~30 сек (refresh interval) `nginx-dev` показал 2 реплики без ручного apply.

---

## 9. Drift detection + self-heal (2 мин)

Ручное вмешательство в кластер:

```bash
kubectl scale deployment/nginx-dev -n demo-dev --replicas=5
kubectl get deploy nginx-dev -n demo-dev -w
```

**Что должен увидеть зритель:** ArgoCD возвращает `replicas=2` в течение 30–60 сек. В UI — краткая вспышка `OutOfSync` → `Synced`.

Мораль: ручное изменение вне Git = отклонение, которое система автоматически откатывает.

---

## 10. Rollback через git revert (2 мин)

```bash
git log --oneline -n 5
git revert --no-edit HEAD~2   # коммит «scale dev to 2 replicas»
git push
argocd app get nginx-dev
kubectl get deploy nginx-dev -n demo-dev -o jsonpath='{.spec.replicas}' && echo
```

**Что должен увидеть зритель:** 1 реплика. История rollback'а — в `git log`, не в голове инженера.

---

## 11. AppProject как граница безопасности (2 мин)

Попробуем задеплоить ресурс за пределы разрешённых namespace'ов:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: break-project
  namespace: argocd
spec:
  project: workshop
  source:
    repoURL: ${REMOTE}
    path: charts/nginx-demo
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
EOF
argocd app get break-project
```

**Что должен увидеть зритель:** статус с `ComparisonError`/`Project ... destination is not permitted` — проект блокирует деплой в чужой namespace.

Убрать:
```bash
kubectl delete application break-project -n argocd
```

---

## 12. SOPS pipeline (5 мин)

Сгенерировать age-ключ:

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
PUBKEY=$(grep '# public key:' ~/.config/sops/age/keys.txt | awk '{print $4}')
echo "public: $PUBKEY"
```

Вставить `$PUBKEY` в `secrets/.sops.yaml` (поле `age`).

Создать plaintext Secret из шаблона и зашифровать:

```bash
cd secrets
cp dev-secret.example.yaml dev-secret.yaml
# отредактировать значения в dev-secret.yaml
sops -e dev-secret.yaml > dev-secret.enc.yaml
rm dev-secret.yaml   # обязательно: plaintext не коммитим
cat dev-secret.enc.yaml
sops -d dev-secret.enc.yaml   # проверка расшифровки
git add .sops.yaml dev-secret.enc.yaml
git commit -m "add encrypted dev secret"
git push
cd ..
```

`repo/.gitignore` блокирует коммит любых `secrets/*.yaml`, кроме `*.enc.yaml` и `.sops.yaml`.

Проговорить:
- в Git хранится только ciphertext
- приватный ключ живёт в `~/.config/sops/age/keys.txt` и **не уходит** в Git
- чтобы ArgoCD сам расшифровывал — нужен plugin (CMP / helm-secrets / KSOPS) или ESO / Vault. В этом демо такой plugin не настроен.

---

## 13. Что проговорить отдельно

- зачем AppProject в multi-tenant
- зачем ApplicationSet вместо десятков Application
- auto-sync удобен, но требует дисциплины (sync windows, ignoreDifferences)
- SOPS ≠ готовое решение для секретов в проде

---

## 14. Troubleshooting (если что-то сломалось)

| Симптом | Причина | Что делать |
|---|---|---|
| `argocd-initial-admin-secret not found` | password-secret удаляется после первой смены пароля | `argocd account update-password`; если потерян — `kubectl -n argocd delete pod -l app.kubernetes.io/name=argocd-server` и заново из initial-admin-secret (только если он ещё не удалён) |
| ApplicationSet не генерирует apps | неверный `files:` path или HTTPS auth | `kubectl describe applicationset nginx-appset -n argocd` |
| Application `ComparisonError` | AppProject блокирует kind/namespace | `kubectl get appproject workshop -n argocd -o yaml`, сверить whitelist |
| `sops` не видит `.sops.yaml` | правила ищутся вверх по дереву | запускать `sops` из `secrets/` или поднять `.sops.yaml` в корень `repo/` |
| kubeconfig смотрит не туда | после нескольких apply | `kubectl config get-contexts`, переключиться на YC-контекст |

---

## 15. Очистка стенда

```bash
# 1) снять LoadBalancer, чтобы не подвис terraform destroy
kubectl -n argocd patch svc argocd-server -p '{"spec":{"type":"ClusterIP"}}'

# 2) удалить Applications и ApplicationSet (иначе finalizer'ы могут мешать)
kubectl delete applicationset nginx-appset -n argocd --ignore-not-found
kubectl delete application --all -n argocd --ignore-not-found

# 3) снести кластер
cd terraform
terraform destroy
```
