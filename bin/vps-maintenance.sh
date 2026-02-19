#!/usr/bin/env bash
set -euo pipefail

LOCK=/tmp/vps-maintenance.lock
LOG_DIR=/home/concierge/agent-system/logs/cron
LOG_FILE="$LOG_DIR/vps-maintenance-$(date +%F).log"
mkdir -p "$LOG_DIR"

if ! ( set -o noclobber; echo "$$" > "$LOCK" ) 2>/dev/null; then
  echo "[skip] lock exists: $LOCK" | tee -a "$LOG_FILE"
  exit 0
fi
trap 'rm -f "$LOCK"' EXIT

{
  echo "== VPS maintenance $(date -Is) =="
  echo

  echo "-- uptime --"
  uptime || true
  echo

  echo "-- disk --"
  df -h / | tail -n 1 || true
  echo

  echo "-- docker ps --"
  docker ps --format "{{.Names}}\t{{.Status}}" | sort || true
  echo

  echo "-- nginx-proxy status (known issue) --"
  docker ps --filter name=nginx-proxy --format "{{.Names}}\t{{.Status}}" || true
  echo

  echo "-- finished --"
} | tee -a "$LOG_FILE"

# Notify Telegram (VPS topic)
if [ -d /home/concierge/apps/telegram-gateway ]; then
  cd /home/concierge/apps/telegram-gateway
  summary=$(tail -n 35 "$LOG_FILE")
  docker compose exec -T \
    -e TELEGRAM_SEND_TOPIC=VPS \
    -e TELEGRAM_SEND_TEXT="✅ VPS maintenance $(date +%F)\n\n$summary" \
    telegram-gateway node scripts/send-message.mjs >/dev/null 2>&1 || true
fi
