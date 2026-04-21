# ArgoCD masterclass demo repository

GitOps-репозиторий, из которого ArgoCD тянет всё, что работает в кластере.

## Структура

```
repo/
  charts/
    nginx-demo/            # Helm chart демо-приложения (один на все окружения)
  apps/
    dev/
      nginx/
        config.json        # per-env значения (replicaCount, resources, message)
    prod/
      nginx/
        config.json
  infra/
    envoy-gateway/         # Helm chart: Envoy Gateway + Gateway + HTTPRoute argocd
    cert-manager/          # Helm chart: cert-manager + ClusterIssuer + Certificate
    projects/
      dev/
        project.yaml       # AppProject demo-dev (destinations: demo-dev)
        appset.yaml        # ApplicationSet apps-dev (apps/dev/*/config.json)
      prod/
        project.yaml       # AppProject demo-prod
        appset.yaml        # ApplicationSet apps-prod
  secrets/                 # Helm chart, рендерит k8s Secret'ы по values;
                           # чувствительные значения — через helm-secrets/sops
                           # (см. secrets/README.md)
```

## Слои (как ArgoCD видит репо)

1. **Terraform** ставит ArgoCD и bootstrap-чарт (`terraform/charts/argocd-bootstrap`).
2. Bootstrap-чарт создаёт AppProject `infra` + два ApplicationSet:
   - `infra` → Helm-чарты из `repo/infra/*` (envoy-gateway, cert-manager).
   - `infra-projects` → raw YAML из `repo/infra/projects/*` (AppProject + ApplicationSet на окружение).
3. ApplicationSet'ы из `projects/{env}` (`apps-dev`, `apps-prod`) сами генерируют `Application` на каждый каталог в `repo/apps/{env}/`.

## Что заменить перед запуском

Во всех файлах, где встречается `https://github.com/erlong15/mc-argocd.git`, подменить на свой форк:

- `repo/infra/projects/dev/{project,appset}.yaml`
- `repo/infra/projects/prod/{project,appset}.yaml`
- `repo/infra/projects/secretapp/application.yaml`

```bash
sed -i.bak 's|https://github.com/erlong15/mc-argocd.git|<YOUR_REMOTE>|g' \
  infra/projects/dev/*.yaml infra/projects/prod/*.yaml infra/projects/secretapp/*.yaml
find infra/projects -name '*.bak' -delete
```

`gitops_repo_url` в `terraform.tfvars` надо выставить туда же (его использует bootstrap-чарт).

Для SOPS — `.sops.yaml` в репе нет; recipient и regex передаём флагами `sops --age "$PUBKEY" --encrypted-regex '^(secrets|data)$'` (см. `repo/secrets/README.md`).

## Pedagogical notes

- ApplicationSet'ы `apps-dev` / `apps-prod` стартуют **без** automated sync — сначала вручную `argocd app sync`, потом включаем `syncPolicy.automated` коммитом в гит (закомментированный блок в `infra/projects/{env}/appset.yaml`).
- `sourceRepos` в AppProject'ах ограничен нашим форком — это граница multi-tenancy, не метка.
- Интеграция SOPS с ArgoCD (helm-secrets через custom tool в argocd-repo-server) настроена в `terraform/argocd-values.yaml`.
