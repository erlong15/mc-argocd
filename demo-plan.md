# План демонстрации ArgoCD

Кластер: Yandex Managed Kubernetes, поднятый через `terraform/`. Тем же `terraform apply` в кластер заезжает ArgoCD + bootstrap-чарт, который создаёт AppProject `infra` и ApplicationSet'ом раскатывает инфраструктуру (Envoy Gateway + cert-manager-webhook-yandex). ArgoCD выставлен наружу через HTTPRoute + Let's Encrypt staging (DNS-01 через Yandex Cloud DNS), UI доступен по `https://argocd.erlong.ru` (или тому, что указано в `var.domain`). Сертификат **staging** — браузер его не доверяет, это намеренно: у демо нет бюджета на прод-лимиты LE.

## Цель демо

Показать минимальный GitOps-цикл:
- кластер + ArgoCD + весь GitOps-слой одним `terraform apply`
- трёхуровневый self-bootstrap: terraform → bootstrap-чарт → infra-projects → per-env ApplicationSet → прикладной Application
- деплой Helm-приложения в dev/prod через ApplicationSet per env
- manual sync → переключение на automated + self-heal коммитом в гит
- drift detection / self-heal / rollback через `git revert`
- AppProject как граница безопасности (infra, demo-dev, demo-prod)
- pipeline шифрования секретов (SOPS)

**Общее время:** ~50–60 мин (из них 15–20 мин ждём `terraform apply` + первый sync инфраструктуры + выпуск LE-сертификата).

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
- доступ в интернет до `github.com`, `argoproj.github.io`, `docker.io/envoyproxy`, `acme-staging-v02.api.letsencrypt.org`, `cr.yandex` (OCI-чарт webhook'а)
- есть форк `https://github.com/erlong15/mc-argocd` на ваш аккаунт — именно его ArgoCD будет пуллить через `gitops_repo_url`
- домен `var.domain` (дефолт `argocd.erlong.ru`) находится в Cloud DNS зоне `var.dns_zone_name` (дефолт `erlong-ru`). Terraform создаст A-запись сам, но зона должна существовать и обслуживаться в YC DNS (туда же пишется DNS-01 challenge-запись от cert-manager-webhook-yandex)
- (опционально для секции 11 «SOPS») сгенерирован age-ключ: `age-keygen -o ~/.config/sops/age/keys.txt`; путь можно прокинуть в `var.age_key_file` заранее

Brew-установка недостающего:

```bash
brew install argocd sops age
```

---

## 1. Поднять кластер + ArgoCD + инфраструктуру (5 мин на ввод, 10–15 мин ждать)

```bash
cd terraform
cat > terraform.tfvars <<EOF
cloud_id        = "<ваш cloud_id>"
folder_id       = "<ваш folder_id>"
gitops_repo_url = "https://github.com/<you>/mc-argocd.git"
# опционально — если хотите, чтобы ArgoCD сразу умел расшифровывать SOPS (см. секцию 11):
# age_key_file  = "/Users/<you>/.config/sops/age/keys.txt"
EOF

terraform init
terraform apply
```

Пока идёт apply — показываем слайды 1–7.

Что делает этот `apply`:
- VPC / subnet / managed K8s кластер + node group
- резервирует статический IP для входящего трафика
- создаёт A-запись `${var.domain}` → этот IP
- ставит ArgoCD (чарт `argo-cd` 9.5.2, `server.service.type: ClusterIP`, `server.httproute.enabled: false` — HTTPRoute приезжает из гита вместе с Gateway API CRDs, см. ниже)
- создаёт YC service-account `cert-manager-webhook` с ролью `dns.editor`, выпускает RSA-ключ и кладёт его в ns `infra` как Secret `cm-sa-creds` (terraform владеет Secret'ом единолично — мы отдельно вендорили вебхук-чарт без `secret.yaml`, чтобы helm его не перезаписывал)
- ставит bootstrap-чарт (`terraform/charts/argocd-bootstrap`): AppProject `infra` + ApplicationSet, генерирующий по одному Application на каждую поддиректорию `repo/infra/*`; `folder_id` прокидывается в `valuesObject` ApplicationSet'а → попадает в ClusterIssuer `yc-clusterissuer`
- ApplicationSet поднимает Envoy Gateway (pinned к зарезервированному IP через `EnvoyProxy.spec.provider.kubernetes.envoyService.loadBalancerIP`), HTTPRoute `argocd-server` (в ns `argocd`, рядом с бэкендом — cross-ns без ReferenceGrant), базовый cert-manager (jetstack) и отдельно вендорный webhook-yc (DNS-01 через YC DNS, ClusterIssuer `yc-clusterissuer` на LE staging)

Почему HTTPRoute живёт в `repo/infra/envoy-gateway/`, а не в чарте argo-cd: на старте Gateway API CRDs ещё не установлены, и `helm_release.argocd` падал бы с `no matches for kind "HTTPRoute"`. Теперь Gateway API CRDs и HTTPRoute едут в одном Argo-синке `envoy-gateway` → Argo сам упорядочит CRD-then-CR. Плата за это — в AppProject `infra` в `destinations` разрешён и ns `argocd` (HTTPRoute) помимо `infra`.

После apply:

```bash
eval "$(terraform output -raw kubeconfig_command)"
kubectl config current-context
kubectl get nodes
kubectl get pods -n argocd
kubectl get pods -n infra
kubectl -n argocd get applicationset,app
```

**Что должен увидеть зритель:** 1–2 Ready-ноды, ArgoCD-поды Running, в ns `infra` поднимаются envoy-gateway + cert-manager + webhook-yc, в ArgoCD три Application'а `envoy-gateway`, `cert-manager` и `cert-manager-webhook-yc` движутся в `Synced/Healthy`. Webhook может пару раз сфейлиться с «no matches for kind Certificate/Issuer», пока jetstack не поставит CRDs — Argo retry'нет сам.

---

## 2. Открыть UI и получить пароль (2 мин)

```bash
terraform output argocd_url        # https://argocd.erlong.ru
terraform output ingress_ip        # зарезервированный IP, на него смотрит DNS A
terraform output argocd_initial_admin_password_command
# выполнить то, что в output:
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Сценарий A — инфраструктура уже поднялась, сертификат выписан:

```bash
# проверка, что LE staging-cert уже есть и Gateway зелёный:
kubectl -n infra get certificate argocd -o jsonpath='{.status.conditions[-1]}{"\n"}'
kubectl -n infra get gateway public -o jsonpath='{.status.listeners[*].name}{"\n"}'
curl -skI https://argocd.erlong.ru/ | head -1   # -k: staging-CA браузер не доверяет
```

Открыть `https://argocd.erlong.ru` в браузере → «Not secure» (staging CA) → продолжить → логин `admin` / выданный пароль.

```bash
argocd login argocd.erlong.ru --username admin --password '<PASTE_PASSWORD>' --grpc-web --insecure
argocd account get-user-info
```

Сценарий B — HTTPS ещё не готов (идёт DNS-01 challenge):

```bash
# пока нет TLS — достучаться до argocd-server через port-forward
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
open http://localhost:8080
argocd login localhost:8080 --username admin --password '<PASTE_PASSWORD>' --plaintext
```

Статус выдачи сертификата:

```bash
kubectl -n infra get certificate,certificaterequest,order,challenge
kubectl -n infra describe challenge | tail -30
# параллельно проверить, что вебхук создал TXT-запись в YC DNS:
yc dns zone list-record-sets --name "$DNS_ZONE" | grep -E 'TXT.*_acme-challenge'
```

**Что должен увидеть зритель:** пустой список Applications (кроме `envoy-gateway`, `cert-manager`, `cert-manager-webhook-yc`) в UI. Здесь уместно проговорить, что инфраструктурный слой ArgoCD уже управляет сам собой — далее добавляем прикладной слой.

---

## 3. Разобрать дерево GitOps-слоёв (2 мин)

После terraform apply ArgoCD уже управляет собой целиком. Показать иерархию:

```bash
kubectl -n argocd get appprojects
# infra, demo-dev, demo-prod
kubectl -n argocd get applicationsets
# infra, infra-projects, apps-dev, apps-prod
kubectl -n argocd get applications
# envoy-gateway, cert-manager, cert-manager-webhook-yc, projects-dev, projects-prod, nginx-dev, nginx-prod, podinfo-prod
```

Нарисовать на доске три уровня:

1. **Terraform** — ставит ArgoCD + bootstrap-чарт (`argocd-bootstrap`).
2. **bootstrap-чарт** — создаёт AppProject `infra` + два ApplicationSet:
   - `infra` → `repo/infra/*` (envoy-gateway, cert-manager, cert-manager-webhook-yc) как Helm-чарты.
   - `infra-projects` → `repo/infra/projects/*` как raw-YAML; каждый Application `projects-{env}` укладывает внутрь ns `argocd` ещё один AppProject (`demo-dev`/`demo-prod`) и ещё один ApplicationSet (`apps-dev`/`apps-prod`).
3. **apps-dev / apps-prod** — dev и prod ведут себя по-разному намеренно (показываем два паттерна):
   - `apps-dev` — git **files**-generator, читает `repo/apps/dev/*/config.json`, поля (`replicaCount`, `cpuRequest`, …) подставляются в helm values шаблона ApplicationSet'а. Все dev-приложения рендерятся из общего `repo/charts/nginx-demo`.
   - `apps-prod` — git **directories**-generator: `repo/apps/prod/<name>/` = самодостаточный umbrella-чарт (`Chart.yaml` с upstream dependency, `values.yaml`, `templates/httproute.yaml`). Добавить новый prod-сервис — скопировать директорию, поменять зависимость в `Chart.yaml`. Тот же паттерн, что `repo/infra/envoy-gateway/`.

Ключевые границы:
- `sourceRepos` у всех project'ов ограничен нашим форком.
- `destinations` у `demo-dev` — только ns `demo-dev`; у `demo-prod` — только `demo-prod`.
- `destinations` у `infra` — `infra` + `argocd` (HTTPRoute для argocd-server лежит в ns argocd рядом с бэкендом).

Namespaces `demo-dev`/`demo-prod` уже созданы terraform'ом.

---

## 4. Осмотреть состояние приложений (2 мин)

```bash
argocd app list
argocd app get nginx-dev
argocd app get nginx-prod
argocd app get podinfo-prod
```

**Что должен увидеть зритель:** `nginx-dev`, `nginx-prod`, `podinfo-prod` в статусе `OutOfSync` / `Missing` — ApplicationSet'ы `apps-{dev,prod}` умышленно без `automated` (закомментирован блок в `repo/infra/projects/{env}/appset.yaml`). В UI — дерево из трёх уровней project → appset → app.

---

## 5. Manual sync (2 мин)

```bash
argocd app sync nginx-dev
argocd app sync nginx-prod
argocd app sync podinfo-prod
argocd app get nginx-dev
kubectl get deploy,svc -n demo-dev
kubectl get deploy,svc,httproute -n demo-prod
```

Показать в UI дерево ресурсов (главный визуальный аргумент ArgoCD).

Пояснить два разных паттерна values в одном репо:
- **dev** — общий чарт `repo/charts/nginx-demo` + per-app `config.json` (files-generator прокидывает поля в helm values шаблона ApplicationSet'а). Подход компактный, когда все приложения одного типа.
- **prod** — umbrella-чарт в каждой директории `repo/apps/prod/<app>/`: `Chart.yaml` тянет upstream-чарт как dependency (bitnami/nginx, podinfo), `values.yaml` переопределяет под себя, собственный `templates/httproute.yaml` даёт публикацию через Envoy Gateway. Подход гибкий, когда приложения разные.

Проверка, что HTTPRoute реально зашёл:
```bash
curl -s -H 'Host: nginx-prod.erlong.ru'   http://$(terraform -chdir=../terraform output -raw ingress_ip)/ | head -5
curl -s -H 'Host: podinfo-prod.erlong.ru' http://$(terraform -chdir=../terraform output -raw ingress_ip)/ | head -5
```

---

## 6. Включить auto-sync + self-heal (2 мин)

Раскомментировать блок `syncPolicy.automated` в обоих `repo/infra/projects/{dev,prod}/appset.yaml` и запушить:

```bash
cd ../repo
sed -i.bak '/# syncPolicy:/,/# *- CreateNamespace=true/ s/^\( *\)# /\1/' \
  infra/projects/dev/appset.yaml infra/projects/prod/appset.yaml
find infra/projects -name '*.bak' -delete
git add infra/projects/dev/appset.yaml infra/projects/prod/appset.yaml
git commit -m "enable auto-sync + self-heal for nginx"
git push
```

Проверка: `apps-dev`/`apps-prod` ApplicationSet'ы пересоздадут дочерние Application'ы уже с автосинком. Через ~30 сек `nginx-dev`/`nginx-prod` → `Synced/Healthy` без ручного `argocd app sync`.

Проговорить риски:
- `prune: true` удаляет ресурсы, пропавшие из Git
- `selfHeal: true` затирает ручные изменения
- в проде прикрывается sync windows + `ignoreDifferences`

Это ещё один показ *всех* слоёв GitOps: мы правим манифест ApplicationSet'а внутри `infra/projects/`, `infra-projects`-Application подхватывает его, пересоздаёт подчинённый ApplicationSet, тот — пересоздаёт Application'ы.

---

## 7. Изменение через Git (3 мин)

Поменять `replicaCount` в `repo/apps/dev/nginx/config.json` с 1 на 2:

```bash
jq '.replicaCount = 2' apps/dev/nginx/config.json > .tmp && mv .tmp apps/dev/nginx/config.json
git add apps/dev/nginx/config.json
git commit -m "scale nginx-dev to 2 replicas"
git push
```

Проверка:

```bash
argocd app get nginx-dev
kubectl get deploy -n demo-dev
```

**Что должен увидеть зритель:** через ~30 сек (refresh interval) `nginx-dev` показал 2 реплики без ручного apply.

---

## 8. Drift detection + self-heal (2 мин)

Ручное вмешательство в кластер:

```bash
kubectl scale deployment/nginx-dev -n demo-dev --replicas=5
kubectl get deploy nginx-dev -n demo-dev -w
```

**Что должен увидеть зритель:** ArgoCD возвращает `replicas=2` в течение 30–60 сек. В UI — краткая вспышка `OutOfSync` → `Synced`.

Мораль: ручное изменение вне Git = отклонение, которое система автоматически откатывает.

---

## 9. Rollback через git revert (2 мин)

```bash
git log --oneline -n 5
git revert --no-edit HEAD~2   # коммит «scale dev to 2 replicas»
git push
argocd app get nginx-dev
kubectl get deploy nginx-dev -n demo-dev -o jsonpath='{.spec.replicas}' && echo
```

**Что должен увидеть зритель:** 1 реплика. История rollback'а — в `git log`, не в голове инженера.

---

## 10. AppProject как граница безопасности (2 мин)

Попробуем задеплоить ресурс за пределы разрешённых namespace'ов:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: break-project
  namespace: argocd
spec:
  project: demo-dev
  source:
    repoURL: https://github.com/<you>/mc-argocd.git
    path: repo/charts/nginx-demo
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: demo-prod
EOF
argocd app get break-project
```

**Что должен увидеть зритель:** статус с `ComparisonError`/`Project demo-dev destination demo-prod is not permitted` — project `demo-dev` разрешает только свой namespace. Это и есть граница multi-tenancy: даже если злоумышленник изменит yaml — Argo не применит.

Убрать:
```bash
kubectl delete application break-project -n argocd
```

Аналогично защищён `infra`-project: попытка Application с `project: infra` в `kube-system` отбивается. cert-manager в прошлом релизе сам нарывался на эту границу, когда пытался складывать leader-election RBAC в `kube-system`; поэтому в `repo/infra/cert-manager/values.yaml` явно выставлено `cert-manager.global.leaderElection.namespace: infra`.

---

## 11. SOPS pipeline (5 мин)

DNS-01-ключ YC у нас НЕ через SOPS: terraform и так владеет SA, проще положить JSON сразу в `kubernetes_secret cm-sa-creds`, чем гонять plaintext через руки. SOPS показываем на прикладном секрете через чарт `repo/secrets/`.

Что уже есть в репе:
- `repo/secrets/` — helm chart, рендерит Secret'ы по списку в values
- `repo/infra/projects/secretapp/application.yaml` — Application `secrets`, указывает `helm.valueFiles: [values.yaml, secrets://values-secret.enc.yaml]`
- AppProject `infra.destinations` включает ns `secrets`
- argocd-repo-server умеет helm-secrets (init-контейнер ставит sops + age + plugin; приватный ключ монтируется из Secret'а `helm-secrets-private-keys`)

Сгенерировать age-ключ (если ещё не делали перед `terraform apply`):

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
PUBKEY=$(grep '# public key:' ~/.config/sops/age/keys.txt | awk '{print $4}')
echo "public: $PUBKEY"
```

Если в `terraform.tfvars` был задан `age_key_file` — приватный ключ уже положен в Secret `helm-secrets-private-keys` в ns argocd. Если нет — создать вручную и перезапустить repo-server:

```bash
kubectl -n argocd create secret generic helm-secrets-private-keys \
  --from-file=key.txt=$HOME/.config/sops/age/keys.txt
kubectl -n argocd rollout restart deploy argocd-repo-server
```

Заполнить секреты и зашифровать:

```bash
cd repo/secrets
cp values-secret.example.yaml values-secret.yaml
# отредактировать values-secret.yaml — заменить DB_PASSWORD, token и т.д.

sops --encrypt \
     --age "$PUBKEY" \
     --encrypted-regex '^(secrets|data)$' \
     values-secret.yaml > values-secret.enc.yaml
rm values-secret.yaml            # plaintext не коммитим
sops --decrypt values-secret.enc.yaml | head   # проверка

git add values-secret.enc.yaml
git commit -m "add encrypted secrets"
git push
cd ../..
```

Дальше ArgoCD подхватывает сам (auto-sync на Application `secrets`):

```bash
argocd app get secrets
# sync succeeded, Healthy
kubectl -n demo-dev get secret demo-db -o yaml
kubectl -n secrets get secret api-token -o jsonpath='{.data.token}' | base64 -d && echo
```

Проговорить:
- в Git хранится только ciphertext (`--encrypted-regex` шифрует только `secrets:` и `data:`, метаданные — открытым текстом, чтобы diff был читаемым)
- приватный ключ живёт в `~/.config/sops/age/keys.txt` и **не уходит** в Git
- `argocd-repo-server` расшифровывает через helm-secrets на момент Helm-рендера (`secrets://values-secret.enc.yaml`)
- SOPS оправдан там, где секрет **рождается у человека** (DB-пароль, токен); когда секрет рождается у terraform — честнее k8s Secret напрямую
- альтернативы: External Secrets Operator, Vault, KSOPS

---

## 12. Что проговорить отдельно

- зачем AppProject в multi-tenant (граница, а не просто метка)
- зачем ApplicationSet вместо десятков Application
- self-bootstrap паттерн: ArgoCD ставит сам себе Gateway + cert-manager
- почему `lbIp` пробрасывается из terraform через `valuesObject` ApplicationSet'а, а не через git (IP живёт в yandex_vpc_address и не в GitOps-контуре)
- auto-sync удобен, но требует дисциплины (sync windows, ignoreDifferences)
- SOPS ≠ готовое решение для секретов в проде

---

## 13. Troubleshooting (если что-то сломалось)

| Симптом | Причина | Что делать |
|---|---|---|
| `argocd-initial-admin-secret not found` | password-secret удаляется после первой смены пароля | `argocd account update-password`; если потерян — `kubectl -n argocd delete pod -l app.kubernetes.io/name=argocd-server` и заново из initial-admin-secret (только если он ещё не удалён) |
| HTTPS открывается, но браузер «Not secure» | LE staging CA браузером не доверяется (так задумано) | это ок; для curl использовать `-k`, для argocd — `--insecure` |
| HTTPS не открывается / `ERR_CERT_AUTHORITY_INVALID` (staging CA) vs сертификат вообще не выпустился | разные сценарии | `kubectl -n infra get certificate,order,challenge`; если challenge `invalid` с `Presenting`/`no such host` — проверить логи вебхука: `kubectl -n infra logs deploy/cert-manager-webhook-yc`. Если `403`/`401` — ключ YC SA невалидный (см. ниже) |
| webhook-yc в логах `PermissionDenied` / `401` при вызове YC DNS API | роль `dns.editor` не назначена или ключ протух | `yc iam service-account list`, `yc resource-manager folder list-access-bindings <folder_id>` — должен быть `roles/dns.editor` на SA `cert-manager-webhook`. Если нет — `terraform apply` (ресурс `yandex_resourcemanager_folder_iam_member.cert_manager_dns_editor`) |
| Secret `cm-sa-creds` пустой / вебхук логирует `401 Unauthorized` | кто-то поправил чарт и вернул Secret-шаблон | проверить `repo/infra/cert-manager-webhook-yc/templates/` — никакого `secret.yaml` там быть не должно; `kubectl -n infra get secret cm-sa-creds -o jsonpath='{.data.key\.json}' \| base64 -d \| head` |
| ClusterIssuer `yc-clusterissuer` в `Not Ready`, `folder_id` пустой | terraform не докинул `folderId` в bootstrap-values → ClusterIssuer отрендерился с пустым полем | `helm template terraform/charts/argocd-bootstrap ...` локально; убедиться, что `appset-infra.yaml` содержит `clusterIssuer.folder_id: "{{ .Values.folderId }}"` |
| `terraform apply` падает: `namespaces "infra" already exists` | ns создали при прошлом apply, terraform-state потеряли | `terraform import kubernetes_namespace.infra infra` |
| DNS-01 challenge висит в `pending` > 5 мин | TXT-запись не прилетела в YC DNS | `yc dns zone list-record-sets --name <zone>` — там должна быть `_acme-challenge.argocd` TXT; если нет — логи вебхука; если есть, но LE не видит — проверить NS-делегирование зоны |
| LB получил не зарезервированный IP | YC CCM читает `spec.loadBalancerIP`, а не YC-аннотацию | проверить `kubectl -n infra get svc -l gateway.envoyproxy.io/owning-gateway-name=public -o yaml`, там должно быть `spec.loadBalancerIP`; если нет — обновить `repo/infra/envoy-gateway/templates/envoyproxy.yaml` и засинкать |
| envoy-gateway app падает с `Certificate CRD not found` | ApplicationSet'ы ставятся параллельно, envoy-gateway sync'ится раньше, чем cert-manager поставил CRD | ArgoCD retry'нет. Если залипло — засинкать cert-manager вручную (`argocd app sync cert-manager`) и подождать; Certificate для argocd.erlong.ru живёт в `repo/infra/envoy-gateway/templates/argocd-certificate.yaml` |
| `cert-manager-webhook-yc` висит в `Error` с `no matches for kind Issuer/Certificate` | webhook-yc засинкался раньше, чем jetstack cert-manager поставил CRDs | Argo retry'нет сам; если застряло — `argocd app sync cert-manager-webhook-yc` после того, как `cert-manager` в `Healthy` |
| `helm_release.argocd` падает на `no matches for kind "HTTPRoute"` | bootstrap: Gateway API CRDs ещё не установлены | в `terraform/argocd-values.yaml` `server.httproute.enabled: false`; HTTPRoute живёт в `repo/infra/envoy-gateway/templates/argocd-httproute.yaml` и приезжает в одном Argo-синке с CRDs |
| `envoy-gateway` app висит `OutOfSync` на HTTPRoute | server-side apply проставляет `backendRefs[].weight: 1` по умолчанию, в манифесте не было | `weight: 1` уже задан явно; если видишь diff — проверить, что в `argocd-httproute.yaml` он есть |
| `apps-dev/apps-prod` ApplicationSet: `error getting project demo-dev: AppProject ... not found` | race: ApplicationSet controller стартовал реконцайл раньше, чем AppProject попал в его кэш | в `project.yaml` выставлен `argocd.argoproj.io/sync-wave: "-1"` — AppProject применится раньше ApplicationSet'а; если ошибка залипла от старого состояния: `kubectl -n argocd rollout restart deploy argocd-applicationset-controller` |
| `nginx-prod` sync: `ERROR: Original containers have been substituted for unrecognized ones` | bitnami-чарт блокирует не-bitnami образ в NOTES.txt | в `repo/apps/prod/nginx/values.yaml` выставлен `nginx.global.security.allowInsecureImages: true` (мы осознанно ставим официальный `nginx:alpine` поверх чарта); если ошибка — проверить, что флаг не выпал из values |
| `nginx-prod` / `podinfo-prod` sync: `HTTPRoute ... is not permitted in project` | в AppProject `demo-prod` не перечислен kind HTTPRoute | проверить `namespaceResourceWhitelist` в `repo/infra/projects/prod/project.yaml` — должен содержать `gateway.networking.k8s.io/HTTPRoute`, плюс `ServiceAccount`, `HPA`, `PDB`, `NetworkPolicy` (bitnami рендерит) |
| `curl -H 'Host: nginx-prod.erlong.ru' http://<ip>/` → 404/no route | HTTPRoute не прицепился к Gateway | `kubectl -n demo-prod get httproute -o yaml` — смотреть `status.parents`: должен быть `Accepted=True` на Gateway `infra/public`; если `Reason: NotAllowedByListeners` — проверить `allowedRoutes.namespaces.from: All` на listener'е http |
| `terraform apply` не видит правок в bootstrap-чарте | helm-provider сравнивает `values` и `Chart.yaml version`, не содержимое templates/ | в values прокинут `_chartSha` (sha1 по файлам чарта) — любая правка триггерит upgrade; если очень надо — bump в `Chart.yaml` |
| Application показывает `Application has N orphaned resources` | в ns `infra` висят ресурсы, созданные оператором (envoy-infra-public-*), cert-manager'ом и кластером — не из Git | в AppProject `infra.orphanedResources.ignore` перечислены известные паттерны (envoy-*, cert-manager-webhook-yc-ca, letsencrypt-account-key, argocd-tls, kube-root-ca.crt, default SA) |
| cert-manager CrashLoopBackOff «Gateway API CRDs do not seem to be present» | стартовал раньше, чем envoy-gateway поставил Gateway API CRD | `kubectl -n infra rollout restart deploy cert-manager` (флаг `--enable-gateway-api` нужен для Certificate-референсов к Gateway, но требует CRD на старте) |
| ApplicationSet не генерирует apps | неверный `gitops_repo_url` или недоступный форк | `kubectl describe applicationset infra -n argocd`, `kubectl logs -n argocd deploy/argocd-applicationset-controller` |
| Application `ComparisonError: ... is not permitted in project` | AppProject блокирует kind/namespace | `kubectl get appproject <name> -n argocd -o yaml`, сверить whitelist |
| `sops` ругается на отсутствие recipient | `.sops.yaml` у нас нет — ключ и regex передаём флагами | `sops --encrypt --age "$PUBKEY" --encrypted-regex '^(secrets\|data)$' values-secret.yaml > values-secret.enc.yaml` |
| Application `secrets` в `Unknown/Missing`: `couldn't find file values-secret.enc.yaml` | ещё не закоммитили зашифрованный файл | выполнить шаг шифрования из §11 и запушить; Argo синкнется сам |
| Application `secrets` в `SyncFailed`: `Error unmarshalling` или `age: no identity matched any recipient` | расшифровка упала — приватного ключа нет в `helm-secrets-private-keys` | проверить `kubectl -n argocd get secret helm-secrets-private-keys -o jsonpath='{.data.key\.txt}' \| base64 -d \| head`; если пусто — `terraform apply` с `age_key_file` или вручную `kubectl -n argocd create secret generic ...` + `rollout restart deploy argocd-repo-server` |
| kubeconfig смотрит не туда | после нескольких apply | `kubectl config get-contexts`, переключиться на YC-контекст |

---

## 14. Очистка стенда

```bash
# 1) снять LoadBalancer, созданный Envoy Gateway — иначе YC не даст удалить subnet
kubectl -n infra delete svc -l gateway.envoyproxy.io/owning-gateway-name=public --ignore-not-found

# 2) удалить Applications и ApplicationSet'ы (finalizer'ы могут мешать destroy)
kubectl delete applicationset --all -n argocd --ignore-not-found
kubectl delete application   --all -n argocd --ignore-not-found

# 3) снести кластер + DNS-запись + зарезервированный IP
cd terraform
terraform destroy
```

Если `terraform destroy` зависнет на `yandex_vpc_address.ingress` — значит не успели снять LB. Посмотреть `yc load-balancer network-load-balancer list`, удалить руками, потом повторить destroy.
