#!/usr/bin/env bash
set -euo pipefail

LOCK=/home/concierge/agent-system/data/heartbeat/telegram-media-purge.lock
LOG_DIR=/home/concierge/agent-system/logs/cron
mkdir -p "$LOG_DIR" "$(dirname "$LOCK")"
LOG="$LOG_DIR/telegram-media-purge-$(date -I).log"

exec >>"$LOG" 2>&1

echo "[$(date -Is)] telegram-media-purge start"

send_telegram() {
  local topic="${1:?topic}"
  local text="${2:?text}"
  /home/concierge/agent-system/bin/send-telegram-openclaw.sh "$topic" "$text" >/dev/null || true
}

with_lock() {
  flock -n 9 || { echo "lock busy"; exit 0; }
  "$@"
}

purge() {
  local media_dir="${TELEGRAM_MEDIA_DIR:-/home/concierge/agent-system/data/telegram/media}"
  local ttl_days="${TELEGRAM_MEDIA_TTL_DAYS:-10}"

  if [[ ! -d "$media_dir" ]]; then
    echo "media_dir missing: $media_dir (ok)"
    return 0
  fi

  if ! [[ "$ttl_days" =~ ^[0-9]+$ ]]; then
    echo "invalid TELEGRAM_MEDIA_TTL_DAYS: $ttl_days" >&2
    return 1
  fi

  local before_files
  before_files=$(find "$media_dir" -type f 2>/dev/null | wc -l | tr -d " ")

  # Delete old files (no path echo to avoid leaking data into logs)
  local deleted
  deleted=$(find "$media_dir" -type f -mtime "+$ttl_days" 2>/dev/null -print -delete | wc -l | tr -d " ")

  # Remove empty directories
  find "$media_dir" -type d -empty -mindepth 1 -delete 2>/dev/null || true

  local after_files
  after_files=$(find "$media_dir" -type f 2>/dev/null | wc -l | tr -d " ")

  echo "ttl_days=$ttl_days before=$before_files deleted=$deleted after=$after_files"
  send_telegram mstraro "🧹 Telegram media purge: deleted ${deleted} files (TTL=${ttl_days}d)."
}

main() {
  purge
  echo "[$(date -Is)] telegram-media-purge done"
}

with_lock main 9>"$LOCK"
