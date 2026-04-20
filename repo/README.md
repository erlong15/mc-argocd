# ArgoCD masterclass demo repository

Содержимое:

- `charts/nginx-demo` — Helm chart для демонстрационного приложения
- `environments/dev` — config.json + values.yaml для dev
- `environments/prod` — config.json + values.yaml для prod
- `bootstrap/project.yaml` — AppProject
- `apps/appset-nginx.yaml` — ApplicationSet, генерит `nginx-dev` и `nginx-prod` из `environments/*/config.json`
- `secrets/` — скелет под SOPS (см. `secrets/README.md`)

## Что заменить перед запуском

Три места с плейсхолдером `https://github.com/example/argocd-masterclass-demo.git` на URL вашего Git-remote:

- `bootstrap/project.yaml` (`spec.sourceRepos`)
- `apps/appset-nginx.yaml` (generator `repoURL` + source `repoURL`)

Команда-однострочник:

```bash
sed -i.bak 's|https://github.com/example/argocd-masterclass-demo.git|<YOUR_REMOTE>|g' \
  bootstrap/project.yaml apps/appset-nginx.yaml && rm *.bak apps/*.bak bootstrap/*.bak 2>/dev/null || true
```

Для SOPS — заменить плейсхолдер публичного ключа в `secrets/.sops.yaml` на ваш age recipient.

## Что здесь демонстрируется

- GitOps-поток через ArgoCD
- Helm chart + values per environment
- генерация нескольких Applications через ApplicationSet (git file generator)
- базовая изоляция через AppProject
- структура и pipeline шифрования секретов через SOPS

## Что здесь НЕ сделано

Интеграция SOPS с ArgoCD (CMP / helm-secrets / KSOPS / ESO) — намеренно не настроена, это тема отдельного шага.

ApplicationSet стартует **без** automated sync — это педагогический приём: сначала вручную показываем `argocd app sync`, потом включаем `automated: prune, selfHeal`. Как включить — см. закомментированный блок в `apps/appset-nginx.yaml`.
