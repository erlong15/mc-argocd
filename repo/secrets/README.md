# SOPS example

Структура для демонстрации шифрования секретов через SOPS + age.

## Файлы

- `.sops.yaml` — правила шифрования (публичные recipients, путь-паттерн). Публичные ключи безопасны в Git.
- `dev-secret.example.yaml` — **шаблон** plaintext-Secret'а (в репо ок, реальных данных не содержит).
- `dev-secret.enc.yaml` — **не коммитится заранее**, генерируется шагом `sops -e` из локальной копии `dev-secret.yaml`.

## Почему это только скелет

Шифрование файла — половина решения. Чтобы ArgoCD смог развернуть зашифрованный Secret в кластер, нужен один из паттернов:

- Custom Management Plugin (CMP) + helm-secrets
- KSOPS (Kustomize plugin)
- External Secrets Operator / Vault (и тогда SOPS уже не нужен)

В этом репозитории интеграция **не настроена** — это обсуждаем отдельно. Демо показывает только pipeline «plaintext → encrypted в Git».

## Правила

- приватный age-ключ (`~/.config/sops/age/keys.txt`) **никогда** не кладём в Git
- `repo/.gitignore` блокирует любые `secrets/*.yaml` кроме `*.enc.yaml` и `.sops.yaml`
- при ротации публичного ключа — `sops updatekeys secrets/*.enc.yaml`
