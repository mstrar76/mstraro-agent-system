#!/usr/bin/env bash
set -euo pipefail

QWEN_BIN="${QWEN_BIN:-/home/concierge/.npm-global/bin/qwen}"
QWEN_HOME="${QWEN_HOME:-/home/concierge/.qwen}"
DEFAULT_WORKDIR="${DEFAULT_WORKDIR:-/home/concierge}"
MODEL="${MODEL:-}"
APPROVAL_MODE="${APPROVAL_MODE:-default}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-text}"

usage() {
  cat <<'EOF'
Usage:
  qwen-maintenance-host.sh --prompt "..." [--workdir DIR]
  qwen-maintenance-host.sh --prompt-file FILE [--workdir DIR]

Environment:
  QWEN_BIN        Absolute Qwen binary path
  QWEN_HOME       Qwen state directory
  DEFAULT_WORKDIR Default working directory
  MODEL           Optional Qwen model
  APPROVAL_MODE   Qwen approval mode (default: default)
  OUTPUT_FORMAT   Qwen output format (default: text)
EOF
}

PROMPT=""
PROMPT_FILE=""
WORKDIR="$DEFAULT_WORKDIR"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)
      PROMPT="${2:-}"
      shift 2
      ;;
    --prompt-file)
      PROMPT_FILE="${2:-}"
      shift 2
      ;;
    --workdir)
      WORKDIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "$PROMPT_FILE" ]]; then
  [[ -f "$PROMPT_FILE" ]] || { echo "Prompt file not found: $PROMPT_FILE" >&2; exit 2; }
  PROMPT="$(cat "$PROMPT_FILE")"
fi

[[ -n "$PROMPT" ]] || { echo "Missing prompt content" >&2; usage >&2; exit 2; }
[[ -x "$QWEN_BIN" ]] || { echo "Qwen binary not executable: $QWEN_BIN" >&2; exit 127; }
[[ -d "$WORKDIR" ]] || { echo "Workdir not found: $WORKDIR" >&2; exit 2; }

export PATH="$(dirname "$QWEN_BIN"):$PATH"
export HOME="${HOME:-/home/concierge}"

cd "$WORKDIR"

ARGS=(
  -p "$PROMPT"
  -o "$OUTPUT_FORMAT"
  --approval-mode "$APPROVAL_MODE"
)

if [[ -n "$MODEL" ]]; then
  ARGS+=( -m "$MODEL" )
fi

exec "$QWEN_BIN" "${ARGS[@]}"
