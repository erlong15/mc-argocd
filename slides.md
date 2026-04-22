# ArgoCD: GitOps с нуля

---

## 1. Зачем вообще менять подход к деплою

- ручные `kubectl apply` плохо масштабируются
- состояние кластера начинает расходиться с тем, что хранится в Git
- после инцидента сложно понять, кто и что поменял
- rollback зависит от памяти инженера, а не от процесса

**Тезис:** GitOps делает Git источником истины, а кластер — исполняемой копией желаемого состояния.

---

## 2. Что такое GitOps

- инфраструктура и приложения описаны декларативно
- изменения проходят через commit / merge request
- контроллер сам приводит систему к desired state
- drift считается отклонением, а не нормой

---

## 3. Где в этой модели ArgoCD

- ArgoCD читает Git
- рендерит manifests / Helm / Kustomize
- сравнивает desired state и live state
- синхронизирует кластер

**Ключевая идея:** не CI пушит в кластер, а кластер pull-моделью забирает изменения сам.

---

## 4. Push vs Pull

### Push-модель
- GitLab CI / Jenkins получают доступ в кластер
- деплой происходит из pipeline
- контроль разбросан между CI и cluster state

### Pull-модель
- доступ в кластер нужен ArgoCD, а не каждому pipeline
- история изменений централизована в Git
- проще контролировать drift и rollback

---

## 5. Базовая архитектура ArgoCD

- **argocd-server** — UI / API / SSO entrypoint
- **repo-server** — рендер Git / Helm / Kustomize
- **application-controller** — reconciliation loop (sync + drift detection)
- **applicationset-controller** — генератор Application'ов из шаблонов
- **redis** — кэш рендеров и reconciliation
- (опционально) dex-server, notifications-controller

Цикл работы:
1. прочитать репозиторий
2. отрендерить манифесты
3. сравнить с live state
4. синхронизировать различия

---

## 6. Ключевые сущности

### Application
Одна логическая единица деплоя: репо + путь + destination + project.

### AppProject
Граница: какие repo, namespace и cluster разрешены этому project'у.

### ApplicationSet
Генератор набора Applications по шаблону — один CR разворачивается в N Application'ов.

---

## 7. Когда Application уже недостаточно

Нужен ApplicationSet, когда:
- несколько окружений (dev / prod)
- много однотипных приложений (микросервисы)
- структура "директория в Git = Application"
- нужен массовый rollout по шаблону

Generators: `list`, `git` (directories / files), `cluster`, `matrix`, `merge`, `scmProvider`, `pullRequest`.

---

## 8. Generators в ApplicationSet — обзор

Generator определяет СПИСОК, из которого ApplicationSet рождает Application'ы. Один ApplicationSet = один (или скомбинированные) generator + template.

| Generator | Что даёт | Пример применения |
|---|---|---|
| `list` | статический список элементов в yaml | фиксированный набор кластеров |
| `git` directories | каждая поддиректория пути в репо | директория = Application |
| `git` files | каждый файл по glob'у, поля файла = параметры | per-app config в одном репо |
| `cluster` | зарегистрированные в ArgoCD clusters | multi-cluster fleet |
| `scmProvider` | все репы в org/group (GitHub/GitLab) | onboarding сервиса без правок |
| `pullRequest` | открытые PR'ы | preview-envs на ревью |
| `matrix` | cartesian product двух generator'ов | env × cluster |
| `merge` | join по ключу | обогащение списка метаданными |

В нашем демо:
- `infra`, `infra-projects`, `apps-prod` → git **directories** (директория = Application)
- `apps-dev` → git **files** (читает `config.json`, поля доступны в template'е)

---

## 9. Template substitution

Template — скелет Application'а. Generator подставляет переменные в поля шаблона.

Что доступно в подстановке (из git generator):
- **fasttemplate** (default): `{{path}}`, `{{path.basename}}`, `{{path[N]}}`
- **goTemplate**: `{{ .path.path }}`, `{{ .path.basename }}`, `{{ .path.segments }}`
- любое поле файла, матчнутого files generator (`{{replicaCount}}`, `{{message}}`)
- произвольные ключи из `list`-generator

Два синтаксиса:
- **fasttemplate** (default) — простые `{{key}}`, строковая подстановка. Набор переменных ограничен и называются иначе: `{{path}}`, а не `{{path.path}}`.
- **goTemplate: true** + `goTemplateOptions: ["missingkey=error"]` — полноценный `{{ .path.basename }}` с условиями, циклами и strict-валидацией опечаток. Рекомендуется для всего нетривиального — опечатка в ключе сразу даёт ошибку, а не молчаливую подстановку литерала.

В этом демо:
- `apps-dev` / `apps-prod` — fasttemplate (простые шаблоны)
- `infra` / `infra-projects` (bootstrap-чарт) — goTemplate: хочется ошибку при опечатке в ключе, а не молчаливую пустую строку

Для точечных правок отдельных Application'ов есть `templatePatch` — редко нужно, но мощная штука (например, добавить annotation конкретному env).

---

## 10. Sync policy — подробности

У Application два «слоя» поведения синка.

**automated:**
- `prune: true` — удалять ресурсы, ушедшие из Git. Без этого Argo оставит в кластере всё, что когда-то задеплоил.
- `selfHeal: true` — возвращать desired state при ручных правках. Без selfHeal drift только показывается в UI.
- `allowEmpty: false` — не позволять prune'ить всё до нуля (защита от пустого рендера).

**syncOptions** (флаги для каждого sync'а):
- `CreateNamespace=true` — создать ns, если нет
- `ServerSideApply=true` — SSA вместо client-side (нужно для Gateway API-ресурсов и любых CR со сложными дефолтами, иначе server дописывает поля и даёт вечный diff)
- `PrunePropagationPolicy=foreground` — аккуратный каскадный delete
- `PruneLast=true` — prune в конце wave, а не в начале
- `Replace=true` — `kubectl replace` вместо apply (last-resort для залипших объектов)

**Sync hooks** (аннотация на ресурсе):
- `argocd.argoproj.io/hook: PreSync | Sync | PostSync | SyncFail` — фаза
- `argocd.argoproj.io/hook-delete-policy: HookSucceeded | BeforeHookCreation | HookFailed` — когда удалять hook-ресурс

**Sync waves** (`argocd.argoproj.io/sync-wave: "-1"`) — порядок применения внутри одного sync'а. Меньше wave = раньше. В нашем демо AppProject идёт в wave -1, чтобы ApplicationSet controller не проиграл гонку и не ругнулся «AppProject not found».

**В демо:** `syncPolicy.automated` закомментирована — первый sync делаем руками `argocd app sync`, потом включаем автосинк коммитом. Это сам по себе показ GitOps: даже «включить автосинк» — это change через Git.

---

## 11. Self-bootstrap / App-of-apps pattern

ArgoCD может управлять **сам собой** и своими дочерними Application'ами:

- ArgoCD ставится один раз (в нашем случае — Terraform'ом через Helm chart)
- внутри Git лежит **корневой** Application / ApplicationSet, описывающий все остальные ArgoCD-объекты (AppProject, дочерние ApplicationSet, конфиги)
- любая правка GitOps-слоя → commit → ArgoCD подхватывает

**Следствие:** кроме установки ArgoCD, всё управляется одной pull-моделью. Нет разделения «ansible ставит X, ArgoCD ставит Y».

---

## 12. Трёхуровневая архитектура демо

```
Terraform (раз в жизни)
    │
    └── ArgoCD + bootstrap-chart (AppProject infra + 2 ApplicationSet)
             │
             ├── ApplicationSet "infra" (git directories) → envoy-gateway, cert-manager, cert-manager-webhook-yc
             │
             └── ApplicationSet "infra-projects" (git directories) → raw YAML projects/{dev,prod}/
                      │
                      ├── AppProject demo-dev + ApplicationSet apps-dev (git FILES)
                      │        └── Application nginx-dev       ← repo/apps/dev/nginx/config.json
                      │
                      └── AppProject demo-prod + ApplicationSet apps-prod (git DIRECTORIES)
                               ├── Application nginx-prod      ← repo/apps/prod/nginx/    (umbrella chart)
                               └── Application podinfo-prod    ← repo/apps/prod/podinfo/  (umbrella chart)
```

dev и prod ведут себя по-разному намеренно — показываем два паттерна:
- **dev** — общий чарт (`repo/charts/nginx-demo`) + per-app `config.json`, files-generator прокидывает поля в helm values шаблона.
- **prod** — umbrella-чарт в директории приложения: `Chart.yaml` тянет upstream как dependency, свой `templates/httproute.yaml` поверх.

Всё, что ниже Terraform'а, — в Git.

---

## 13. Платформенный слой через GitOps

ArgoCD ставит не только приложения, но и инфраструктуру:

- **Envoy Gateway** (Gateway API implementation) — приносит Gateway API CRDs, роль Ingress
- **cert-manager** — базовый jetstack-чарт v1.15.3: CRDs + controller + cainjector + webhook
- **cert-manager-webhook-yc** — вендорные шаблоны из `oci://cr.yandex/.../cert-manager-webhook-yandex` (subchart cert-manager выкинут), DNS-01 webhook для Yandex Cloud DNS + ClusterIssuer `yc-clusterissuer` на LE staging. Секрет с SA-ключом создаёт terraform, templates/secret.yaml из оригинального чарта удалён
- **HTTPRoute для самой ArgoCD UI** — `argocd.erlong.ru` терминируется Envoy'ем с LE staging-сертом (браузер предупредит — осознанный trade-off на время мастер-класса)

Почему через ArgoCD, а не руками / terraform'ом:
- единая история изменений инфры и приложений
- drift detection работает и для платформы
- повторяемый перезапуск кластера — `terraform destroy && terraform apply`

---

## 14. Как мы поднимаем стенд (мастер-класс)

Один `terraform apply`:
1. VPC + managed K8s кластер (Yandex Cloud)
2. резервирует статический IP, создаёт DNS A-запись
3. ставит ArgoCD (Helm chart `argo-cd` 9.5.2)
4. создаёт YC service-account `cert-manager-webhook` с ролью `dns.editor`, выпускает ключ и сразу кладёт его в ns `infra` как `Secret cm-sa-creds`. Вендорный webhook-чарт (`repo/infra/cert-manager-webhook-yc`) не содержит `secret.yaml` — terraform владеет этим Secret'ом единолично
5. ставит bootstrap-chart → AppProject `infra` + два ApplicationSet; `folder_id` прокидывается в `valuesObject` → попадает в ClusterIssuer `yc-clusterissuer`
6. ArgoCD подхватывает из Git и поднимает Envoy Gateway, cert-manager, cert-manager-webhook-yc, per-env AppProject'ы и ApplicationSet'ы
7. cert-manager через вебхук пишет `_acme-challenge` TXT в YC DNS → LE staging выдаёт сертификат (2–3 мин)

~10–15 мин ждём. Пока ждём — слайды 1–13. После apply: UI на `https://argocd.erlong.ru` с LE staging-сертом (браузер ругнётся — это осознанный trade-off).

---

## 15. Структура репозитория

```text
repo/
  charts/
    nginx-demo/                # общий Helm-чарт для dev-приложений
  apps/
    dev/
      nginx/config.json        # per-app конфиг (files-generator)
    prod/
      nginx/                   # umbrella: Chart.yaml (bitnami/nginx) + values + templates/httproute.yaml
      podinfo/                 # umbrella: Chart.yaml (podinfo)        + values + templates/httproute.yaml
  infra/
    envoy-gateway/             # Gateway API + HTTPRoute + Certificate для argocd.erlong.ru
    cert-manager/              # jetstack-чарт v1.15.3 (CRDs + controller)
    cert-manager-webhook-yc/   # вендорные шаблоны YC DNS-01 webhook + ClusterIssuer
    projects/
      dev/{project.yaml,appset.yaml}
      prod/{project.yaml,appset.yaml}
      secretapp/application.yaml
  secrets/                     # Helm-чарт для SOPS-секретов (см. §25)
```

Соответствие слоям:
- `charts/` — переиспользуемый код (для dev-подхода)
- `apps/dev/<name>/` — per-env конфиг, дальше общий чарт
- `apps/prod/<name>/` — самодостаточный umbrella-чарт (Chart.yaml ссылается на upstream)
- `infra/*` — платформа
- `infra/projects/<env>/` — ArgoCD-объекты, управляющие прикладным слоем

---

## 16. Почему Helm, а не просто YAML

- меньше дублирования
- параметры вынесены в values
- проще поддерживать несколько env через один chart
- удобная интеграция с helm-secrets для SOPS
- umbrella-pattern (`dependencies` в Chart.yaml) позволяет брать upstream чарты как зависимости и добавлять сверху свои templates (у нас так сделан весь prod: bitnami/nginx + свой HTTPRoute; cert-manager с jetstack-subchart; envoy-gateway с gateway-helm-subchart)

Но:
- chart легко усложнить
- плохой chart превращается в шаблонизатор хаоса

---

## 17. Environments в нашем демо — два паттерна

### dev — один чарт, много конфигов
- 1 реплика, малые requests/limits
- `repo/apps/dev/<app>/config.json` — поля читает files-generator ApplicationSet'а `apps-dev` и прокидывает в inline-values helm source'а
- все dev-приложения рендерятся из общего `repo/charts/nginx-demo`
- **когда выбирать:** много однотипных сервисов, хочется максимально лаконичный per-app конфиг

### prod — umbrella-чарт per приложение
- `repo/apps/prod/<app>/` — самодостаточный Helm-чарт: `Chart.yaml` с upstream в dependencies, `values.yaml` под alias субчарта, `templates/httproute.yaml` с маршрутом на Envoy Gateway
- `nginx-prod` → bitnami/nginx 23.0.0 (образ подменён на `nginx:alpine`)
- `podinfo-prod` → stefanprodan/podinfo 6.11.2
- **когда выбирать:** приложения разные, у каждого свой upstream чарт; нужна полная изоляция per-app values

Два разных подхода в одном репо — осознанно: обе стороны trade-off'а видны рядом.

---

## 18. Sync policy — практический выбор в демо

- **manual** — безопасно для обучения, нужен `argocd app sync`
- **automated** — GitOps-поток, sync на любое изменение Git
- **prune: true** — удалять объекты, которых больше нет в Git
- **selfHeal: true** — исправлять drift без участия инженера

В демо стартуем с **manual**, включаем автосинк на шаге rollback — коммитом в Git, не `kubectl patch`. (Теорию по syncOptions, hooks, waves см. слайд 10.)

---

## 19. Демонстрация drift и self-heal

Сценарий:
- приложение в статусе Synced
- `kubectl scale deployment/nginx-dev --replicas=5` руками
- ArgoCD показывает OutOfSync
- с `selfHeal: true` — возвращает к Git'овому desired state за 30–60 сек
- без selfHeal — диффа видно в UI, решение на инженере

Это один из самых наглядных моментов мастер-класса.

---

## 20. Rollback в GitOps

Не нужно «откатывать кластер руками».

Подход:
- `git revert <bad-commit>` → push
- ArgoCD видит новый desired state
- возвращает систему к прошлой версии

Аудит отката остаётся в `git log`, а не в голове дежурного.

---

## 21. AppProject как граница безопасности

Ограничивает для каждого project'а:
- список разрешённых Git repo (`sourceRepos`)
- cluster destinations (`destinations`)
- namespaces
- whitelist / blacklist kinds (`clusterResourceWhitelist` / `namespaceResourceWhitelist`)

В нашем демо — **три** project'а:
- `infra` → ns `infra` + `argocd` (платформа + HTTPRoute для argocd-server)
- `demo-dev` → ns `demo-dev`, узкий whitelist kinds (под dev-чарт)
- `demo-prod` → ns `demo-prod`, расширенный whitelist (под upstream чарты: ServiceAccount, HPA, PDB, NetworkPolicy, HTTPRoute)

Покажем попытку кросс-граничного деплоя (Application с `project: demo-dev`, целящий в ns `demo-prod`) — получит `project destination is not permitted`.

**Тезис:** без Project multi-tenant GitOps быстро становится опасным.

---

## 22. ApplicationSet — рекурсивная генерация

В нашем демо четыре ApplicationSet, вложенных друг в друга:

| ApplicationSet | Generator | Что рождает |
|---|---|---|
| `infra` | git **directories** `repo/infra/*` (projects/ исключён) | `envoy-gateway`, `cert-manager`, `cert-manager-webhook-yc` |
| `infra-projects` | git **directories** `repo/infra/projects/*` | `projects-dev`, `projects-prod`, `secretapp` |
| `apps-dev` | git **files** `repo/apps/dev/*/config.json` | `nginx-dev` |
| `apps-prod` | git **directories** `repo/apps/prod/*` | `nginx-prod`, `podinfo-prod` |

Files vs directories — выбор паттерна:
- **files**: читает содержимое файла, его поля доступны в template (`{{replicaCount}}`, `{{message}}`). Хорошо, когда значения per-app надо засунуть inline в один общий чарт.
- **directories**: даёт только путь, всё остальное — внутри самой директории (umbrella-чарт, полноценный Helm-сорс). Хорошо, когда каждое приложение самодостаточно.

Добавить новое приложение:
- в **dev**: новая директория + `config.json`
- в **prod**: новая директория + `Chart.yaml` + `values.yaml` + `templates/httproute.yaml`

В обоих случаях ApplicationSet сам подхватит новый элемент на refresh'е — править его манифест не нужно.

---

## 23. Секреты и почему обычный Git не подходит

Проблема:
- plaintext secret в Git — почти всегда плохая идея

Варианты:
- External Secrets Operator (из Vault / AWS SM / YC Lockbox)
- Sealed Secrets (controller расшифровывает)
- SOPS (шифрование на этапе commit)
- KSOPS / Vault plugin / Vals

Для мастер-класса берём **SOPS + helm-secrets** как понятный и компактный пример.

---

## 24. Что делает SOPS

- шифрует только чувствительные поля, остальной YAML читается
- файл остаётся YAML / JSON / ENV
- можно хранить в Git, diff-ать по нечувствительным частям
- расшифровка завязана на age / KMS / PGP

Важно:
- ArgoCD сам по себе SOPS не понимает
- нужен plugin — в нашем случае `helm-secrets` установлен в `argocd-repo-server` через init-контейнер (см. `terraform/argocd-values.yaml`)
- приватный age-ключ монтируется из Secret `helm-secrets-private-keys` — его Terraform кладёт из `var.age_key_file`

---

## 25. Что покажем по SOPS

- чарт `repo/secrets/` — рендерит k8s Secret'ы по списку из values
- генерацию age-ключа + шифрование `values-secret.yaml` → `values-secret.enc.yaml` (`sops --encrypted-regex '^(secrets|data)$'` — метаданные остаются plaintext, diff читаем)
- Application `secrets` с `helm.valueFiles: [values.yaml, secrets://values-secret.enc.yaml]`
- расшифровку `argocd-repo-server` через helm-secrets при рендере chart'а

Почему YC DNS-01-ключ НЕ через SOPS:
- terraform и так владеет yandex_iam_service_account_key → честнее положить JSON сразу в `kubernetes_secret`, чем гонять plaintext через руки
- SOPS выигрывает, когда секрет **рождается у человека** (DB-пароль, токен 3rd-party) и должен лежать рядом с конфигом

На мастер-классе — честно:
- для продакшена нужно заранее выбрать supported integration pattern
- хранить приватные age-ключи в Git нельзя
- staging LE — тоже осознанный trade-off; для прода — DNS-01 с production directory и лимитами

---

## 26. Типовые ошибки внедрения

- нет Application / ApplicationSet в Git — всё «на коленке» через UI
- смешивание cluster bootstrap и app manifests без иерархии
- отсутствие AppProject → любой может задеплоить куда угодно
- auto-sync без понимания `prune` и `selfHeal` → потеря данных при удалении файла
- plaintext секреты в Git
- ручные изменения в кластере «на всякий случай»

---

## 27. Когда ArgoCD действительно окупается

- несколько сервисов и окружений
- команда уже работает через Git (PR review культура)
- нужен audit trail изменений
- есть требования к воспроизводимости и rollback
- multi-cluster fleet, единый control plane

---

## 28. Когда он будет лишним

- нет Kubernetes
- один стенд, один сервис и ручное управление допустимо
- команда пока не готова к GitOps-дисциплине (`kubectl edit` в проде — обычное дело)

---

## 29. Итог мастер-класса

После занятия участник должен:
- понимать модель GitOps и pull-деплой
- читать иерархию ArgoCD: AppProject / Application / ApplicationSet
- понимать self-bootstrap и app-of-apps паттерн
- разворачивать Helm chart по нескольким env через ApplicationSet (и различать два паттерна — общий чарт + per-app config vs umbrella-чарт per app)
- использовать AppProject как реальную границу безопасности
- знать, куда вкручивается SOPS / helm-secrets

---

## 30. Q&A
