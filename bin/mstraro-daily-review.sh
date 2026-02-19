#!/usr/bin/env bash
set -euo pipefail

LOCK=/tmp/mstraro-daily-review.lock
LOG_DIR=/home/concierge/agent-system/logs/cron
LOG_FILE="$LOG_DIR/mstraro-daily-review-$(date +%F).log"
mkdir -p "$LOG_DIR"

if ! ( set -o noclobber; echo "$$" > "$LOCK" ) 2>/dev/null; then
  echo "[skip] lock exists: $LOCK" | tee -a "$LOG_FILE"
  exit 0
fi
trap 'rm -f "$LOCK"' EXIT

AG_URL="http://127.0.0.1:8787/respond"

snippet_headings_only() {
  local p="$1"
  if [ -f "$p" ]; then
    echo "\n\n## FILE: $p (headings only)\n";
    grep -E '^(#|##|###) ' "$p" | head -n 120 || true
  else
    echo "\n\n## FILE: $p (missing)\n";
  fi
}

snippet() {
  local p="$1"
  local n="${2:-160}"
  if [ -f "$p" ]; then
    echo "\n\n## FILE: $p\n";
    head -n "$n" "$p";
  else
    echo "\n\n## FILE: $p (missing)\n";
  fi
}

# Build a compact review pack (avoid leaking secrets)
{
  echo "== daily review (mstraro) $(date -Is) =="

  snippet /home/concierge/tracking/vps-state.md 220

  echo "\n\n## FILE: /home/concierge/docs/secrets.md (SENSITIVE)\n"
  if [ -f /home/concierge/docs/secrets.md ]; then
    echo "(conteúdo omitido; headings only para evitar vazamento)"
    grep -E '^(#|##|###) ' /home/concierge/docs/secrets.md | head -n 120 || true
  else
    echo "missing"
  fi

  snippet /home/concierge/apps/telegram-gateway/docker-compose.yml 160
  snippet /home/concierge/apps/agent-gateway/docker-compose.yml 220
  snippet /home/concierge/apps/opencode/docker-compose.yml 220

  for f in BOT-RULES.md MEMORY.md SOUL.md USER.md IDENTITY.md TOOLS.md policies.md connectors.md DELEGATION.md DAILY-REVIEW.md; do
    snippet "/home/concierge/agent-system/data/opencode/workspace/fileset/$f" 180
  done

} > "$LOG_FILE"

prompt=$(cat <<'PROMPT'
Você é o especialista "Mstraro". Faça uma revisão diária dos arquivos fornecidos (snippets) e produza:

📋 Arquivos para Revisão Diária
- Liste quais arquivos foram revisados e aponte inconsistências/desatualizações.

🚀 Sugestões de Melhorias (peça aprovação antes de mudanças)
- Sugira 3-8 melhorias com risco baixo/médio, e para cada uma inclua:
  - por quê
  - o que mudar (bem concreto)
  - impacto
  - se exige confirmação explícita

Regras:
- NUNCA vaze segredos/chaves.
- Se detectar que um arquivo sensível parece conter segredos expostos indevidamente, recomende mitigação (sem repetir o segredo).
- Não execute mudanças automaticamente; apenas proponha.
PROMPT
)

payload=$(python3 - <<PY
import json
from pathlib import Path
log=Path("$LOG_FILE").read_text(encoding="utf-8")
text=("""%s\n\n%s""" % ("""%s""", log))[:55000]
print(json.dumps({
  "chatId": -1003814554435,
  "threadId": 18,
  "topicKey": "mstraro",
  "from": {"id": 0, "username": "cron"},
  "text": text
}))
PY
)

resp=$(curl -sS --connect-timeout 5 --max-time 110 -X POST "$AG_URL" -H 'content-type: application/json' -d "$payload" || true)
reply=$(python3 - <<PY
import json,sys
raw=sys.stdin.read()
try:
  obj=json.loads(raw)
  print((obj.get('reply') or '').strip())
except Exception:
  print('')
PY
<<<"$resp")

if [ -z "$reply" ]; then
  reply="(sem resposta do agent-gateway; ver $LOG_FILE)"
fi

# Telegram max message ~4096; keep margin
reply_short=$(python3 - <<PY
import sys
s=sys.stdin.read()
print(s[:3500])
PY
<<<"$reply")

# send to telegram topic mstraro
if [ -d /home/concierge/apps/telegram-gateway ]; then
  cd /home/concierge/apps/telegram-gateway
  docker compose exec -T \
    -e TELEGRAM_SEND_TOPIC=mstraro \
    -e TELEGRAM_SEND_TEXT="📋 Daily Review ($(date +%F))\n\n$reply_short" \
    telegram-gateway node scripts/send-message.mjs >/dev/null 2>&1 || true
fi
