#!/usr/bin/env bash
set -euo pipefail

LOCK=/home/concierge/agent-system/data/heartbeat/heartbeat.lock
STATE=/home/concierge/agent-system/data/heartbeat/state.json
LOG_DIR=/home/concierge/agent-system/logs/cron
mkdir -p "$LOG_DIR" "$(dirname "$STATE")"
LOG="$LOG_DIR/heartbeat-$(date -I).log"

exec >>"$LOG" 2>&1

echo "[$(date -Is)] heartbeat start"

send_telegram() {
  local topic="${1:?topic}"
  local text="${2:?text}"
  (cd /home/concierge/apps/telegram-gateway \
    && docker compose exec -T \
      -e TELEGRAM_SEND_TOPIC="$topic" \
      -e TELEGRAM_SEND_TEXT="$text" \
      telegram-gateway node scripts/send-message.mjs) >/dev/null || true
}

json_get() {
  local file="$1" key="$2" default="$3"
  python3 - "$file" "$key" "$default" <<'PY'
import json,sys
p,k,d=sys.argv[1],sys.argv[2],sys.argv[3]
try:
  obj=json.load(open(p))
except Exception:
  print(d); sys.exit(0)
cur=obj
for part in k.split('.'):
  if isinstance(cur, dict) and part in cur:
    cur=cur[part]
  else:
    print(d); sys.exit(0)
print(cur if cur is not None else d)
PY
}

json_set() {
  local file="$1" key="$2" value="$3"
  python3 - "$file" "$key" "$value" <<'PY'
import json,sys,os
p,k,v=sys.argv[1],sys.argv[2],sys.argv[3]
try:
  obj=json.load(open(p))
except Exception:
  obj={}
cur=obj
parts=k.split('.')
for part in parts[:-1]:
  if part not in cur or not isinstance(cur[part], dict):
    cur[part]={}
  cur=cur[part]
cur[parts[-1]]=v
os.makedirs(os.path.dirname(p), exist_ok=True)
open(p,'w').write(json.dumps(obj, indent=2, sort_keys=True))
PY
}

with_lock() {
  flock -n 9 || { echo "lock busy"; exit 0; }
  "$@"
}

check_containers() {
  local missing=()
  for name in agent_telegram_gateway agent_agent_gateway agent_opencode; do
    if ! docker ps --format "{{.Names}}" | grep -qx "$name"; then
      missing+=("$name")
    fi
  done
  if ((${#missing[@]})); then
    echo "missing_containers=${missing[*]}"
    return 1
  fi
  return 0
}

check_agent_gateway() {
  curl -fsS --max-time 3 http://127.0.0.1:8787/health >/dev/null
}

check_disk() {
  local used
  used="$(df -P / | awk 'NR==2{gsub(/%/,"",$5);print $5}')"
  [[ -n "$used" ]] || used=0
  if (( used >= 85 )); then
    echo "disk_used=${used}%"
    return 1
  fi
  return 0
}

check_memory() {
  local avail
  avail="$(free -m | awk '/Mem:/ {print $7}')"
  [[ -n "$avail" ]] || avail=0
  if (( avail <= 500 )); then
    echo "mem_avail=${avail}MB"
    return 1
  fi
  return 0
}

main() {
  local ok=1
  local issues=()

  if ! check_containers; then
    issues+=("containers")
    ok=0
  fi

  if ! check_agent_gateway; then
    issues+=("agent-gateway")
    ok=0
  fi

  if ! check_disk; then
    issues+=("disk")
    ok=0
  fi

  if ! check_memory; then
    issues+=("memory")
    ok=0
  fi

  local now
  now="$(date +%s)"

  local prev
  prev="$(json_get "$STATE" 'status.overall' 'unknown')"

  if (( ok )); then
    json_set "$STATE" 'status.overall' 'ok'
    json_set "$STATE" 'status.last_ok_epoch' "$now"

    if [[ "$prev" != "ok" ]]; then
      send_telegram VPS "✅ Heartbeat OK (recuperado)."
    fi
    echo "[$(date -Is)] heartbeat ok"
    exit 0
  fi

  json_set "$STATE" 'status.overall' 'fail'
  json_set "$STATE" 'status.last_fail_epoch' "$now"

  local last_alert
  last_alert="$(json_get "$STATE" 'status.last_alert_epoch' '0')"
  last_alert=${last_alert:-0}

  # throttle: 30min
  if (( now - last_alert < 1800 )); then
    echo "throttled (last_alert=$last_alert)"
    exit 0
  fi

  json_set "$STATE" 'status.last_alert_epoch' "$now"
  send_telegram VPS "🔴 Heartbeat FAIL: ${issues[*]}. Log: $LOG"
  echo "[$(date -Is)] heartbeat fail issues=${issues[*]}"
  exit 1
}

with_lock main 9>"$LOCK"
