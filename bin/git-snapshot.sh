#!/usr/bin/env bash
set -euo pipefail

LOCK=/home/concierge/agent-system/data/heartbeat/git-snapshot.lock
LOG_DIR=/home/concierge/agent-system/logs/cron
mkdir -p "$LOG_DIR" "$(dirname "$LOCK")"
LOG="$LOG_DIR/git-snapshot-$(date -I).log"

exec >>"$LOG" 2>&1

echo "[$(date -Is)] git-snapshot start"

send_telegram() {
  local topic="${1:?topic}"
  local text="${2:?text}"
  (cd /home/concierge/apps/telegram-gateway \
    && docker compose exec -T \
      -e TELEGRAM_SEND_TOPIC="$topic" \
      -e TELEGRAM_SEND_TEXT="$text" \
      telegram-gateway node scripts/send-message.mjs) >/dev/null || true
}

with_lock() {
  flock -n 9 || { echo "lock busy"; exit 0; }
  "$@"
}

snapshot_repo() {
  local dir="$1"
  local label="$2"

  if [[ ! -d "$dir/.git" ]]; then
    echo "[$label] not a git repo: $dir"
    return 0
  fi

  git -C "$dir" add -A
  if git -C "$dir" diff --cached --quiet; then
    echo "[$label] no changes"
    return 0
  fi

  local msg="chore(snapshot): $(date -Is)"
  git -C "$dir" commit -m "$msg" --no-gpg-sign

  local sha
  sha="$(git -C "$dir" rev-parse --short HEAD)"
  echo "[$label] committed $sha"

  # best-effort push if origin exists
  if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    git -C "$dir" push -u origin HEAD >/dev/null 2>&1 || true
  fi

  send_telegram mstraro "✅ git snapshot: ${label} @ ${sha}"
}

main() {
  snapshot_repo /home/concierge/agent-system agent-system
  snapshot_repo /home/concierge/agent-system/data/athena/workspace athena-private
  snapshot_repo /home/concierge/apps apps
  echo "[$(date -Is)] git-snapshot done"
}

with_lock main 9>"$LOCK"
