# Secrets chart

Чарт рендерит k8s Secret'ы по списку в values. Чувствительные значения шифруются
через sops + age и коммитятся как `values-secret.enc.yaml`. Расшифровывает
argocd-repo-server на момент Helm-рендера (helm-secrets установлен init-контейнером
в `terraform/argocd-values.yaml`).

## Что где лежит

| Файл | Назначение | В Git? |
|---|---|---|
| `Chart.yaml`, `templates/secret.yaml` | сам чарт | да |
| `values.yaml` | defaultNamespace, пустой `secrets: []` | да |
| `values-secret.example.yaml` | пример формата plaintext | да (без реальных данных) |
| `values-secret.yaml` | plaintext перед шифрованием | **нет** (в .gitignore) |
| `values-secret.enc.yaml` | sops-шифр, его подтягивает ArgoCD | да |

## Формат values

```yaml
defaultNamespace: secrets
secrets:
  - name: demo-db
    namespace: demo-dev      # опционально, иначе defaultNamespace
    data:
      DB_USER: admin
      DB_PASSWORD: s3cret
```

Каждая запись → один k8s Secret (`stringData`, без ручного base64).

## Пайплайн

```bash
# 1. Сгенерировать age-ключ (один раз)
age-keygen -o ~/.config/sops/age/keys.txt
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
PUBKEY=$(grep '# public key:' ~/.config/sops/age/keys.txt | awk '{print $4}')

# 2. Заполнить plaintext
cp values-secret.example.yaml values-secret.yaml
# отредактировать values-secret.yaml

# 3. Шифровать только чувствительные ветки
sops --encrypt \
     --age "$PUBKEY" \
     --encrypted-regex '^(secrets|data)$' \
     values-secret.yaml > values-secret.enc.yaml
rm values-secret.yaml            # plaintext не коммитим
sops --decrypt values-secret.enc.yaml   # проверка

# 4. Коммит
git add values-secret.enc.yaml
git commit -m "add encrypted secrets"
git push
```

Приватный age-ключ загружается в Secret `helm-secrets-private-keys` (ns argocd)
через `terraform.tfvars:age_key_file`. argocd-repo-server монтирует его как файл
и передаёт sops через `SOPS_AGE_KEY_FILE`.

## Как ArgoCD это подтягивает

`repo/infra/projects/secretapp/application.yaml` — плоский Application, который
кладёт себя в ns argocd через `projects-secretapp` (сгенерирован ApplicationSet'ом
`infra-projects`). Он указывает:

```yaml
helm:
  valueFiles:
    - values.yaml
    - secrets://values-secret.enc.yaml
```

Префикс `secrets://` триггерит helm-secrets plugin → sops расшифровывает файл на
лету → helm видит plaintext values → рендерит Secret'ы → ArgoCD применяет.

## Правила

- plaintext `values-secret.yaml` — никогда в Git (`repo/.gitignore`)
- приватный age-ключ (`~/.config/sops/age/keys.txt`) — никогда в Git
- ротация публичного ключа: `sops updatekeys values-secret.enc.yaml`
