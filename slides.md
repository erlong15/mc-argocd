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

Генераторы: `list`, `git` (directories / files), `cluster`, `matrix`, `merge`, `scmProvider`, `pullRequest`.

---

## 8. Self-bootstrap / App-of-apps pattern

ArgoCD может управлять **сам собой** и своими дочерними Application'ами:

- ArgoCD ставится один раз (в нашем случае — Terraform'ом через Helm chart)
- внутри Git лежит **корневой** Application / ApplicationSet, описывающий все остальные ArgoCD-объекты (AppProject, дочерние ApplicationSet, конфиги)
- любая правка GitOps-слоя → commit → ArgoCD подхватывает

**Следствие:** кроме установки ArgoCD, всё управляется одной pull-моделью. Нет разделения «ansible ставит X, ArgoCD ставит Y».

---

## 9. Трёхуровневая архитектура демо

```
Terraform (раз в жизни)
    │
    └── ArgoCD + bootstrap-chart (AppProject infra + 2 ApplicationSet)
             │
             ├── ApplicationSet "infra" → Helm-чарты: envoy-gateway, cert-manager, cert-manager-webhook-yc
             │        (repo/infra/envoy-gateway — Gateway+HTTPRoute+Certificate;
             │         repo/infra/cert-manager — базовый jetstack-чарт;
             │         repo/infra/cert-manager-webhook-yc — вендорные шаблоны YC DNS-01 webhook + наш ClusterIssuer)
             │
             └── ApplicationSet "infra-projects" → raw YAML: projects/{dev,prod}/
                      │
                      └── AppProject demo-dev + ApplicationSet apps-dev
                               │
                               └── Application nginx-dev (repo/apps/dev/nginx)
                      └── AppProject demo-prod + ApplicationSet apps-prod
                               │
                               └── Application nginx-prod (repo/apps/prod/nginx)
```

Всё, что ниже Terraform'а, — в Git. Любой новый сервис в prod = коммит в `repo/apps/prod/<name>/config.json`.

---

## 10. Платформенный слой через GitOps

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

## 11. Как мы поднимаем стенд (мастер-класс)

Один `terraform apply`:
1. VPC + managed K8s кластер (Yandex Cloud)
2. резервирует статический IP, создаёт DNS A-запись
3. ставит ArgoCD (Helm chart `argo-cd` 9.5.2)
4. создаёт YC service-account `cert-manager-webhook` с ролью `dns.editor`, выпускает ключ и сразу кладёт его в ns `infra` как `Secret cm-sa-creds`. Вендорный webhook-чарт (`repo/infra/cert-manager-webhook-yc`) не содержит `secret.yaml` — terraform владеет этим Secret'ом единолично
5. ставит bootstrap-chart → AppProject `infra` + два ApplicationSet; `folder_id` прокидывается в `valuesObject` → попадает в ClusterIssuer `yc-clusterissuer`
6. ArgoCD подхватывает из Git и поднимает Envoy Gateway, cert-manager, cert-manager-webhook-yc, per-env AppProject'ы и ApplicationSet'ы
7. cert-manager через вебхук пишет `_acme-challenge` TXT в YC DNS → LE staging выдаёт сертификат (2–3 мин)

~10–15 мин ждём. Пока ждём — слайды 1–10. После apply: UI на `https://argocd.erlong.ru` с LE staging-сертом (браузер ругнётся — это осознанный trade-off).

---

## 12. Структура репозитория

```text
repo/
  charts/
    nginx-demo/            # Helm chart демо-приложения
  apps/
    dev/nginx/config.json  # per-env values
    prod/nginx/config.json
  infra/
    envoy-gateway/         # Helm chart + Gateway + HTTPRoute + Certificate для argocd.erlong.ru
    cert-manager/                 # базовый jetstack-чарт v1.15.3 (только CRDs + controller)
    cert-manager-webhook-yc/      # вендорные шаблоны YC DNS-01 webhook + ClusterIssuer (без secret.yaml)
    projects/
      dev/{project.yaml,appset.yaml}
      prod/{project.yaml,appset.yaml}
```

Соответствие слоям:
- `charts/` — переиспользуемый код
- `apps/<env>/<name>/` — конфиг per env, дальше Helm
- `infra/*` — платформа
- `infra/projects/<env>/` — ArgoCD-объекты, управляющие прикладным слоем

---

## 13. Почему Helm, а не просто YAML

- меньше дублирования
- параметры вынесены в values
- проще поддерживать несколько env через один chart
- удобная интеграция с helm-secrets для SOPS

Но:
- chart легко усложнить
- плохой chart превращается в шаблонизатор хаоса

---

## 14. Environments в нашем демо

### dev
- 1 реплика
- малые requests/limits
- project `demo-dev` ограничен ns `demo-dev`

### prod
- 2 реплики
- более строгие requests/limits
- project `demo-prod` ограничен ns `demo-prod`

Разница между окружениями живёт в `repo/apps/<env>/nginx/config.json` — один chart, два config'а.

---

## 15. Sync policy

- **manual** — безопасно для обучения, нужен `argocd app sync`
- **automated** — GitOps-поток, sync на любое изменение Git
- **prune: true** — удалять объекты, которых больше нет в Git
- **selfHeal: true** — исправлять drift без участия инженера

В демо стартуем с **manual**, включаем автосинк на шаге rollback — коммитом в Git, не `kubectl patch`.

---

## 16. Демонстрация drift и self-heal

Сценарий:
- приложение в статусе Synced
- `kubectl scale deployment/nginx-dev --replicas=5` руками
- ArgoCD показывает OutOfSync
- с `selfHeal: true` — возвращает к Git'овому desired state за 30–60 сек
- без selfHeal — диффа видно в UI, решение на инженере

Это один из самых наглядных моментов мастер-класса.

---

## 17. Rollback в GitOps

Не нужно «откатывать кластер руками».

Подход:
- `git revert <bad-commit>` → push
- ArgoCD видит новый desired state
- возвращает систему к прошлой версии

Аудит отката остаётся в `git log`, а не в голове дежурного.

---

## 18. AppProject как граница безопасности

Ограничивает для каждого project'а:
- список разрешённых Git repo (`sourceRepos`)
- cluster destinations (`destinations`)
- namespaces
- whitelist / blacklist kinds

В нашем демо — **три** project'а:
- `infra` → ns `infra` + `argocd` (платформа + HTTPRoute для argocd-server)
- `demo-dev` → ns `demo-dev`
- `demo-prod` → ns `demo-prod`

Покажем попытку кросс-граничного деплоя (Application с `project: demo-dev`, целящий в ns `demo-prod`) — получит `project destination is not permitted`.

**Тезис:** без Project multi-tenant GitOps быстро становится опасным.

---

## 19. ApplicationSet — рекурсивная генерация

В нашем демо четыре ApplicationSet, вложенных друг в друга:

| ApplicationSet | Генератор | Что рождает |
|---|---|---|
| `infra` | git directories `repo/infra/*` | Application'ы `envoy-gateway`, `cert-manager`, `cert-manager-webhook-yc` |
| `infra-projects` | git directories `repo/infra/projects/*` | Application'ы `projects-dev`, `projects-prod` |
| `apps-dev` | git files `repo/apps/dev/*/config.json` | Application'ы `nginx-dev` (и любые новые) |
| `apps-prod` | git files `repo/apps/prod/*/config.json` | Application'ы `nginx-prod` |

Добавить новое приложение в prod = положить `config.json` в `repo/apps/prod/<name>/`. Commit → push → новый Application появляется сам.

---

## 20. Секреты и почему обычный Git не подходит

Проблема:
- plaintext secret в Git — почти всегда плохая идея

Варианты:
- External Secrets Operator (из Vault / AWS SM / YC Lockbox)
- Sealed Secrets (controller расшифровывает)
- SOPS (шифрование на этапе commit)
- KSOPS / Vault plugin / Vals

Для мастер-класса берём **SOPS + helm-secrets** как понятный и компактный пример.

---

## 21. Что делает SOPS

- шифрует только чувствительные поля, остальной YAML читается
- файл остаётся YAML / JSON / ENV
- можно хранить в Git, diff-ать по нечувствительным частям
- расшифровка завязана на age / KMS / PGP

Важно:
- ArgoCD сам по себе SOPS не понимает
- нужен plugin — в нашем случае `helm-secrets` установлен в `argocd-repo-server` через init-контейнер (см. `terraform/argocd-values.yaml`)
- приватный age-ключ монтируется из Secret `helm-secrets-private-keys` — его Terraform кладёт из `var.age_key_file`

---

## 22. Что покажем по SOPS

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

## 23. Типовые ошибки внедрения

- нет Application / ApplicationSet в Git — всё «на коленке» через UI
- смешивание cluster bootstrap и app manifests без иерархии
- отсутствие AppProject → любой может задеплоить куда угодно
- auto-sync без понимания `prune` и `selfHeal` → потеря данных при удалении файла
- plaintext секреты в Git
- ручные изменения в кластере «на всякий случай»

---

## 24. Когда ArgoCD действительно окупается

- несколько сервисов и окружений
- команда уже работает через Git (PR review культура)
- нужен audit trail изменений
- есть требования к воспроизводимости и rollback
- multi-cluster fleet, единый control plane

---

## 25. Когда он будет лишним

- нет Kubernetes
- один стенд, один сервис и ручное управление допустимо
- команда пока не готова к GitOps-дисциплине (`kubectl edit` в проде — обычное дело)

---

## 26. Итог мастер-класса

После занятия участник должен:
- понимать модель GitOps и pull-деплой
- читать иерархию ArgoCD: AppProject / Application / ApplicationSet
- понимать self-bootstrap и app-of-apps паттерн
- разворачивать Helm chart по нескольким env через ApplicationSet
- использовать AppProject как реальную границу безопасности
- знать, куда вкручивается SOPS / helm-secrets

---

## 27. Q&A
