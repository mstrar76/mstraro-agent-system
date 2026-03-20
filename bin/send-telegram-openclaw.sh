#!/usr/bin/env bash
set -euo pipefail

topic="${1:?topic}"
text="${2:?text}"

config_env="/home/concierge/.config/openclaw/openclaw-gateway.env"
openclaw_bin="/home/concierge/.npm-global/bin/openclaw"
chat_id="-1003814554435"

case "$topic" in
  VPS|vps)
    thread_id="16"
    ;;
  mstraro|MSTRARO|openclaw)
    thread_id="18"
    ;;
  projects|PROJECTS)
    thread_id="19"
    ;;
  alex|Alex|dev)
    thread_id="20"
    ;;
  finance|FINANCE)
    thread_id="74"
    ;;
  seo|SEO)
    thread_id="82"
    ;;
  social|SOCIAL)
    thread_id="84"
    ;;
  *)
    echo "unknown telegram topic: $topic" >&2
    exit 2
    ;;
esac

if [[ -f "$config_env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$config_env"
  set +a
fi

"$openclaw_bin" message send \
  --channel telegram \
  --target "$chat_id" \
  --thread-id "$thread_id" \
  --message "$text" \
  --silent \
  >/dev/null
