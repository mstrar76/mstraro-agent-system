#!/usr/bin/env bash
set -euo pipefail

LOCK=/home/concierge/agent-system/data/heartbeat/auto-upgrade.lock
LOG_DIR=/home/concierge/agent-system/logs/cron
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/auto-upgrade-stateless-$(date -I).log"

exec >>"$LOG" 2>&1

echo "[$(date -Is)] auto-upgrade-stateless start"

send_telegram() {
  local topic="${1:?topic}"
  local text="${2:?text}"
  (cd /home/concierge/apps/telegram-gateway \
    && docker compose exec -T \
      -e TELEGRAM_SEND_TOPIC="$topic" \
      -e TELEGRAM_SEND_TEXT="$text" \
      telegram-gateway node scripts/send-message.mjs) >/dev/null || true
}

healthcheck() {
  local failures=0

  docker ps --format "{{.Names}}" | grep -qx "agent_telegram_gateway" || failures=$((failures+1))
  docker ps --format "{{.Names}}" | grep -qx "agent_opencode" || failures=$((failures+1))
  docker ps --format "{{.Names}}" | grep -qx "agent_agent_gateway" || failures=$((failures+1))

  curl -fsS --max-time 3 http://127.0.0.1:8787/health >/dev/null || failures=$((failures+1))

  return "$failures"
}

with_lock() {
  flock -n 9 || { echo "lock busy"; exit 0; }
  "$@"
}

main() {
  local before_tg before_oc
  before_tg="$(docker inspect -f "{{.Image}}" agent_telegram_gateway 2>/dev/null || true)"
  before_oc="$(docker inspect -f "{{.Image}}" agent_opencode 2>/dev/null || true)"

  echo "before: telegram=$before_tg opencode=$before_oc"

  # Update allowlist (stateless): telegram-gateway + opencode + agent-gateway (restart/build)
  echo "--- telegram-gateway pull+restart"
  (cd /home/concierge/apps/telegram-gateway && docker compose pull && docker compose up -d)

  echo "--- opencode pull+restart"
  (cd /home/concierge/apps/opencode && docker compose pull && docker compose up -d)

  echo "--- agent-gateway build (pull base) + restart"
  # Agent-gateway é build local; por padrão só puxa base image e rebuild (sem mexer no código)
  (cd /home/concierge/apps/agent-gateway && docker compose build --pull && docker compose up -d)

  if healthcheck; then
    local after_tg after_oc
    after_tg="$(docker inspect -f "{{.Image}}" agent_telegram_gateway 2>/dev/null || true)"
    after_oc="$(docker inspect -f "{{.Image}}" agent_opencode 2>/dev/null || true)"
    echo "after: telegram=$after_tg opencode=$after_oc"

    send_telegram VPS "✅ Auto-upgrade (stateless) OK. telegram=${after_tg:0:12} opencode=${after_oc:0:12}"
    echo "[$(date -Is)] auto-upgrade-stateless ok"
    exit 0
  fi

  echo "healthcheck failed: attempting rollback"
  # Rollback best-effort for image-tag based services
  if [[ -n "$before_tg" ]]; then
    docker image tag "$before_tg" node:22-slim || true
    (cd /home/concierge/apps/telegram-gateway && docker compose up -d) || true
  fi
  if [[ -n "$before_oc" ]]; then
    docker image tag "$before_oc" openeuler/opencode:1.1.48-oe2403lts || true
    (cd /home/concierge/apps/opencode && docker compose up -d) || true
  fi

  # Agent-gateway rollback não é garantido (build). Apenas reinicia.
  (cd /home/concierge/apps/agent-gateway && docker compose up -d) || true

  send_telegram VPS "⚠️ Auto-upgrade (stateless) falhou e tentou rollback. Verifique: $LOG"
  echo "[$(date -Is)] auto-upgrade-stateless fail"
  exit 1
}

with_lock main 9>"$LOCK"
