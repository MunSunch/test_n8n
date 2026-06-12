#!/usr/bin/env bash
# Резервная копия n8n: дамп PostgreSQL + архив данных n8n (ключ шифрования,
# настройки, бинарные файлы). Запускать на сервере из каталога проекта.
# Использование: ./backup.sh [каталог_для_бэкапов]   (по умолчанию ./backups)
set -euo pipefail
cd "$(dirname "$0")"

BACKUP_DIR=${1:-./backups}
STAMP=$(date +%F_%H-%M-%S)
mkdir -p "$BACKUP_DIR"

# Подхватываем POSTGRES_USER / POSTGRES_DB из .env
set -a; . ./.env; set +a

echo "-> Дамп PostgreSQL..."
docker compose exec -T postgres pg_dump -U "${POSTGRES_USER:-n8n}" -d "${POSTGRES_DB:-n8n}" \
  | gzip > "$BACKUP_DIR/n8n-db-$STAMP.sql.gz"

echo "-> Архив /home/node/.n8n..."
docker compose exec -T n8n tar -czf - -C /home/node .n8n \
  > "$BACKUP_DIR/n8n-data-$STAMP.tar.gz"

# Бэкапы старше 14 дней удаляются
find "$BACKUP_DIR" -name 'n8n-*' -type f -mtime +14 -delete

echo "OK: $BACKUP_DIR/n8n-db-$STAMP.sql.gz"
echo "OK: $BACKUP_DIR/n8n-data-$STAMP.tar.gz"
