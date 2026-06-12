#!/usr/bin/env bash
# ============================================================================
# Развёртывание n8n одним скриптом: Docker -> .env -> файрвол -> запуск
# контейнеров -> установка community-нод.
#
# Запускать НА СЕРВЕРЕ из каталога проекта:
#   sudo bash setup.sh                  # полная установка (спросит домен/IP)
#   sudo bash setup.sh n8n.example.com  # то же, но домен передан аргументом
#   bash setup.sh nodes                 # только (до)установить ноды из списка
#
# Скрипт идемпотентен: повторный запуск ничего не ломает (существующий .env
# не перезаписывается, установка нод просто обновляет список).
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# ----------------------------------------------------------------------------
# Community-ноды, устанавливаемые автоматически.
# Добавьте пакет в список и выполните:  bash setup.sh nodes
# ----------------------------------------------------------------------------
NODES=(
  n8n-nodes-mcp                        # MCP-серверы как инструменты AI-агентов
  n8n-nodes-globals                    # глобальные константы для всех workflow
  n8n-nodes-text-manipulation          # продвинутая обработка текста
  n8n-nodes-imap                       # полноценная работа с почтой по IMAP
  n8n-nodes-evolution-api              # WhatsApp через Evolution API
  n8n-nodes-chatwoot                   # Chatwoot (клиентская поддержка)
  n8n-nodes-kommo                      # Kommo CRM (бывшая amoCRM)
  "@mendable/n8n-nodes-firecrawl"      # скрейпинг сайтов в markdown (Firecrawl)
  "@elevenlabs/n8n-nodes-elevenlabs"   # синтез речи ElevenLabs
  n8n-nodes-deepseek                   # DeepSeek LLM
  n8n-nodes-tesseractjs                # OCR (картинка -> текст) без внешних API
)
# Сознательно НЕ включены — в стандартном образе n8n они не заработают:
#   n8n-nodes-puppeteer   — нужен Chromium внутри образа
#   n8n-nodes-browserless — нужен отдельный контейнер browserless
#   n8n-nodes-python      — нужен Python внутри образа
#   n8n-nodes-claudecode  — нужен установленный Claude Code CLI

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mОшибка: %s\033[0m\n' "$*" >&2; exit 1; }

wait_n8n() {
  log "Ожидание готовности n8n (до 3 минут)..."
  local i
  for i in $(seq 1 90); do
    if docker compose exec -T n8n wget -qO- http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
      log "n8n отвечает"
      return 0
    fi
    sleep 2
  done
  warn "n8n не ответил на healthcheck — смотрите: docker compose logs n8n"
  return 1
}

install_nodes() {
  [ ${#NODES[@]} -gt 0 ] || { warn "Список NODES пуст — пропускаю"; return 0; }
  docker compose ps n8n 2>/dev/null | grep -qiE 'running|up' \
    || die "контейнер n8n не запущен — сначала: docker compose up -d"

  log "Установка community-нод (${#NODES[@]} шт.)..."
  docker compose exec -T n8n sh -c \
    "mkdir -p /home/node/.n8n/nodes && cd /home/node/.n8n/nodes \
     && npm install --no-fund --no-audit --loglevel=error ${NODES[*]}"

  log "Перезапуск n8n, чтобы ноды подхватились..."
  docker compose restart n8n >/dev/null
  wait_n8n || true

  log "Итоговый список установленных пакетов:"
  docker compose exec -T n8n sh -c \
    "cd /home/node/.n8n/nodes && npm ls --depth=0" || true
}

# ============================ режим "только ноды" ============================
if [ "${1:-}" = "nodes" ]; then
  install_nodes
  exit 0
fi

DOMAIN_ARG=${1:-}
[ -f docker-compose.yml ] || die "запустите скрипт из каталога с docker-compose.yml"

# ------------------------------- 1. Docker ----------------------------------
if ! command -v curl >/dev/null 2>&1; then
  if [ "$(id -u)" -eq 0 ] && command -v apt-get >/dev/null 2>&1; then
    log "Установка curl..."
    apt-get update -qq && apt-get install -y -qq curl
  else
    die "не найден curl — установите его и запустите скрипт снова"
  fi
fi

if ! command -v docker >/dev/null 2>&1; then
  [ "$(id -u)" -eq 0 ] || die "нужен root для установки Docker: sudo bash setup.sh"
  log "Установка Docker..."
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || die "docker compose недоступен"

# -------------------------------- 2. .env -----------------------------------
# Защита от переноса локального тестового конфига на сервер
if [ -f .env ] && grep -q '^N8N_HOST=localhost$' .env; then
  warn "Найден тестовый .env (localhost) — для сервера он не подходит."
  if [ -t 0 ]; then
    read -rp "Пересоздать .env для сервера? [Y/n]: " R
    case "${R:-Y}" in n|N) ;; *) rm -f .env ;; esac
  else
    die "тестовый .env (localhost) — удалите его (rm .env) и запустите снова"
  fi
fi

if [ -f .env ]; then
  log ".env уже существует — оставляю без изменений"
else
  log "Создание .env"
  DOMAIN=$DOMAIN_ARG
  if [ -z "$DOMAIN" ] && [ -t 0 ]; then
    read -rp "Домен для n8n (Enter = доступ только по IP, без HTTPS): " DOMAIN
  fi

  ENC_KEY=$(openssl rand -hex 32)
  PG_PASS=$(openssl rand -hex 16)

  if [ -n "$DOMAIN" ]; then
    SITE=$DOMAIN; HOST=$DOMAIN; PROTO=https
    URL="https://$DOMAIN/"; SECURE=true
    log "Режим HTTPS: убедитесь, что A-запись $DOMAIN указывает на этот сервер"
  else
    IP_GUESS=$(curl -fsS4 --max-time 10 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    IP=$IP_GUESS
    if [ -t 0 ]; then
      read -rp "IP сервера [$IP_GUESS]: " IP_INPUT
      IP=${IP_INPUT:-$IP_GUESS}
    fi
    [ -n "$IP" ] || die "не удалось определить IP сервера"
    warn "Режим без HTTPS: трафик не шифруется, вебхуки Telegram и ряда сервисов работать не будут"
    SITE=":80"; HOST=$IP; PROTO=http
    URL="http://$IP/"; SECURE=false
  fi

  cat > .env <<EOF
# Сгенерировано setup.sh $(date +%F)
N8N_SITE_ADDRESS=$SITE
N8N_HOST=$HOST
N8N_PROTOCOL=$PROTO
WEBHOOK_URL=$URL
N8N_SECURE_COOKIE=$SECURE

# ВАЖНО: сохраните копию N8N_ENCRYPTION_KEY в надёжном месте.
# Без него нельзя восстановить сохранённые credentials из бэкапа.
N8N_ENCRYPTION_KEY=$ENC_KEY

POSTGRES_PASSWORD=$PG_PASS
POSTGRES_USER=n8n
POSTGRES_DB=n8n

GENERIC_TIMEZONE=Asia/Tashkent
EOF
  chmod 600 .env
  warn "Секреты сгенерированы и записаны в .env — сохраните копию N8N_ENCRYPTION_KEY!"
fi

# ------------------------- 3. Папка обмена файлами ---------------------------
mkdir -p local-files backups
chown -R 1000:1000 local-files 2>/dev/null \
  || warn "не удалось выполнить chown local-files (запустите от root)"

# ------------------------------ 4. Файрвол ----------------------------------
if command -v ufw >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
  log "Настройка ufw: открываю 22 (SSH), 80, 443..."
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null
  ufw allow 80/tcp  >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw --force enable >/dev/null
else
  warn "ufw пропущен (нет ufw или нет root) — откройте порты 22/80/443 вручную"
fi

# ------------------------------- 5. Запуск ----------------------------------
log "Запуск контейнеров (docker compose up -d)..."
docker compose up -d
wait_n8n || true

# --------------------------------- 6. Ноды ----------------------------------
install_nodes

# --------------------------------- 7. Итог ----------------------------------
FINAL_URL=$(grep '^WEBHOOK_URL=' .env | cut -d= -f2-)
log "Готово! Откройте в браузере: $FINAL_URL"
echo "  1. При первом входе создайте аккаунт владельца (email + пароль)."
echo "  2. Включите 2FA: Settings -> Personal -> Two-factor authentication."
echo "  3. Бэкапы: ./backup.sh  (cron-пример в README, раздел 9)."
