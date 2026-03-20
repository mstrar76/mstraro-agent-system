#!/usr/bin/env bash
set -euo pipefail

LOG_DIR=/home/concierge/agent-system/logs/cron
APPROVALS_DIR=/home/concierge/agent-system/data/approvals
APT_LOCK=/home/concierge/agent-system/data/heartbeat/apt.lock
mkdir -p "$LOG_DIR" "$APPROVALS_DIR" "$(dirname "$APT_LOCK")"
LOG="$LOG_DIR/packages-upgrade-$(date -I).log"

exec >>"$LOG" 2>&1

echo "[$(date -Is)] packages-upgrade start"

send_telegram() {
  local topic="${1:?topic}"
  local text="${2:?text}"
  /home/concierge/agent-system/bin/send-telegram-openclaw.sh "$topic" "$text" >/dev/null || true
}

with_apt_lock() {
  flock -n 9 || { echo "apt lock busy"; exit 0; }
  "$@"
}

approval_file="$APPROVALS_DIR/packages.json"
state_file="$APPROVALS_DIR/state.json"

today() { date -I; }

is_approved() {
  [[ -f "$approval_file" ]] || return 1
  python3 - "$approval_file" <<'PY'
import json,sys,time
p=sys.argv[1]
try:
  obj=json.load(open(p))
except Exception:
  sys.exit(1)
exp=obj.get('expiresAtEpoch')
if not isinstance(exp,(int,float)):
  sys.exit(1)
if time.time() > float(exp):
  sys.exit(1)
print('ok')
PY
}

should_notify_today() {
  local d
  d="$(today)"
  python3 - "$state_file" "$d" <<'PY'
import json,sys
p=sys.argv[1]
d=sys.argv[2]
try:
  s=json.load(open(p))
except Exception:
  print('yes'); sys.exit(0)
print('no' if s.get('lastNotifiedDate')==d else 'yes')
PY
}

mark_notified_today() {
  local d
  d="$(today)"
  python3 - "$state_file" "$d" <<'PY'
import json,sys,os
p=sys.argv[1]
d=sys.argv[2]
os.makedirs(os.path.dirname(p), exist_ok=True)
open(p,'w').write(json.dumps({'lastNotifiedDate': d}, indent=2))
PY
}

if is_approved >/dev/null 2>&1; then
  with_apt_lock sudo -n apt-get update -qq 9>"$APT_LOCK"

  echo "approved: applying apt-get upgrade"
  with_apt_lock env DEBIAN_FRONTEND=noninteractive sudo -n apt-get upgrade -y 9>"$APT_LOCK"
  rm -f "$approval_file" || true
  send_telegram VPS "✅ Pacotes do sistema atualizados (apt-get upgrade)."
  exit 0
fi

upgradable_count="$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
if [[ "${upgradable_count:-0}" != "0" ]]; then
  if [[ "$(should_notify_today)" == "yes" ]]; then
    mark_notified_today
    send_telegram VPS "ℹ️ Existem ${upgradable_count} updates pendentes (apt). Para aplicar por tempo limitado: envie /approve packages no tópico VPS."
  fi
fi

echo "[$(date -Is)] packages-upgrade done"
