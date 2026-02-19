#!/usr/bin/env bash
set -euo pipefail

LOG_DIR=/home/concierge/agent-system/logs/cron
APPROVALS_DIR=/home/concierge/agent-system/data/approvals
APT_LOCK=/home/concierge/agent-system/data/heartbeat/apt.lock
mkdir -p "$LOG_DIR" "$APPROVALS_DIR" "$(dirname "$APT_LOCK")"
LOG="$LOG_DIR/packages-install-$(date -I).log"

exec >>"$LOG" 2>&1

echo "[$(date -Is)] packages-install start"

send_telegram() {
  local topic="${1:?topic}"
  local text="${2:?text}"
  (cd /home/concierge/apps/telegram-gateway \
    && docker compose exec -T \
      -e TELEGRAM_SEND_TOPIC="$topic" \
      -e TELEGRAM_SEND_TEXT="$text" \
      telegram-gateway node scripts/send-message.mjs) >/dev/null || true
}

with_apt_lock() {
  flock -n 9 || { echo "apt lock busy"; exit 0; }
  "$@"
}

is_pkg_safe() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9+.-]{0,62}$ ]]
}

now_epoch() { date +%s; }

shopt -s nullglob
files=("$APPROVALS_DIR"/install-*.json)

if ((${#files[@]} == 0)); then
  echo "no install approvals"
  exit 0
fi

with_apt_lock sudo -n apt-get update -qq 9>"$APT_LOCK"

for f in "${files[@]}"; do
  raw="$(cat "$f" 2>/dev/null || true)"

  pkg="$(python3 - <<'PY' "$raw"
import json,sys
try:
  obj=json.loads(sys.argv[1])
except Exception:
  print(''); sys.exit(0)
print(obj.get('target') or '')
PY
)"

  exp="$(python3 - <<'PY' "$raw"
import json,sys
try:
  obj=json.loads(sys.argv[1])
except Exception:
  print('0'); sys.exit(0)
print(int(obj.get('expiresAtEpoch') or 0))
PY
)"

  if [[ -z "$pkg" ]] || ! is_pkg_safe "$pkg"; then
    echo "invalid install approval file: $f"
    rm -f "$f" || true
    continue
  fi

  now="$(now_epoch)"
  if (( exp > 0 && now > exp )); then
    echo "expired install approval: $pkg (file=$f)"
    rm -f "$f" || true
    continue
  fi

  echo "installing: $pkg"
  with_apt_lock env DEBIAN_FRONTEND=noninteractive sudo -n apt-get install -y --no-install-recommends "$pkg" 9>"$APT_LOCK"

  rm -f "$f" || true
  send_telegram VPS "✅ Pacote instalado: $pkg"
done

echo "[$(date -Is)] packages-install done"
