#!/usr/bin/env bash
# Run Google Antigravity CLI (agy, Gemini models) headless on an InstaBox machine and print its answer.
# Needs: curl, jq, env INSTABOX_API_KEY.
set -euo pipefail

usage() {
  cat <<'U'
usage: gemini-remote.sh [-m MACHINE] [-M MODEL] [-a MODE] [-C DIR] [-t SECONDS] [-j] [PROMPT...]
  -m  machine alias (from GEMINI_IBX_MACHINES) or id m_...  (default: env GEMINI_IBX_MACHINE, else agent01)
  -M  model: alias (flash|flash-medium|flash-low|sonnet|opus|gpt-oss) or full slug from 'agy models'
      (default: env GEMINI_IBX_MODEL, else the CLI default = Gemini 3.8 Flash high)
  -L  list the models this account can use on the machine, then exit
  -e  effort: low|medium|high                            (default: CLI default)
  -a  permissions: safe|yolo  (safe = shell commands denied; yolo = auto-approve all) (default: safe)
  -C  working directory on the machine                   (default: /data/home)
  -t  timeout seconds, max 600                           (default: 300)
  -j  print Gemini's raw JSON instead of just the answer
  PROMPT  prompt text; if omitted, read from stdin. Piped stdin + PROMPT are combined.
U
}

MACHINE="${GEMINI_IBX_MACHINE:-agent01}"; MODEL="${GEMINI_IBX_MODEL:-}"; LIST=0; MODE="safe"; EFFORT=""; CWD="/data/home"; TO=300; RAW=0
while getopts "m:M:e:a:C:t:jLh" o; do
  case $o in
    m) MACHINE=$OPTARG;; M) MODEL=$OPTARG;; e) EFFORT=$OPTARG;; a) MODE=$OPTARG;; C) CWD=$OPTARG;;
    t) TO=$OPTARG;; j) RAW=1;; L) LIST=1;; h) usage; exit 0;; *) usage; exit 2;;
  esac
done
shift $((OPTIND-1))

# Machine aliases come from env, never hard-coded:
#   GEMINI_IBX_MACHINES="agent01=m_xxx,agent02=m_yyy"
ID=""
if [[ "$MACHINE" == m_* ]]; then ID=$MACHINE; else
  IFS=',' read -ra PAIRS <<< "${GEMINI_IBX_MACHINES:-}"
  for kv in "${PAIRS[@]}"; do [ "${kv%%=*}" = "$MACHINE" ] && ID="${kv#*=}"; done
fi
[ -n "$ID" ] || { echo "unknown machine '$MACHINE': pass a machine id (m_...) or set GEMINI_IBX_MACHINES" >&2; exit 2; }
case "$MODE" in safe|yolo) ;; *) echo "bad -a: $MODE" >&2; exit 2;; esac
: "${INSTABOX_API_KEY:?set INSTABOX_API_KEY}"
API="${INSTABOX_API_URL:-https://api.instabox.sh}"

case "$MODEL" in
  flash) MODEL=gemini-3.8-flash-high;; flash-medium) MODEL=gemini-3.8-flash-medium;; flash-low) MODEL=gemini-3.8-flash-low;;
  sonnet) MODEL=claude-sonnet-4-6;; opus) MODEL=claude-opus-4-6-thinking;; gpt-oss) MODEL=gpt-oss-120b-medium;;
esac
if [ "$LIST" = 1 ]; then
  jq -n '{cmd:"\"$HOME/.local/bin/agy\" models 2>&1 | grep -v Fetching", timeoutSeconds:60}' | \
    curl -sS -m 70 -X POST "$API/v1/machines/$ID/exec" -H "X-API-Key: $INSTABOX_API_KEY" -H 'Content-Type: application/json' -d @- | jq -r '.stdout'
  exit 0
fi

PROMPT=""
[ -t 0 ] || PROMPT="$(cat)"
if [ $# -gt 0 ]; then PROMPT="${PROMPT:+$PROMPT

}$*"; fi
[ -n "$PROMPT" ] || { usage; exit 2; }

CMD='"$HOME/.local/bin/agy" -p "$(cat)" --output-format json'" --print-timeout $((TO-5))s"
[ -n "$MODEL" ] && CMD="$CMD --model $(printf %q "$MODEL")"
[ -n "$EFFORT" ] && CMD="$CMD --effort $(printf %q "$EFFORT")"
[ "$MODE" = yolo ] && CMD="$CMD --dangerously-skip-permissions"

BODY=$(jq -n --arg cmd "$CMD" --arg stdin "$PROMPT" --arg cwd "$CWD" --argjson t "$TO" \
  '{cmd:$cmd, stdin:$stdin, cwd:$cwd, timeoutSeconds:$t}')
RES=$(curl -sS -m $((TO+30)) -X POST "$API/v1/machines/$ID/exec" \
  -H "X-API-Key: $INSTABOX_API_KEY" -H 'Content-Type: application/json' -d "$BODY")

if ! echo "$RES" | jq -e 'has("exitCode")' >/dev/null 2>&1; then
  echo "InstaBox error (machine may be suspended or cooling down): $RES" >&2; exit 3
fi
CODE=$(echo "$RES" | jq -r .exitCode)
OUT=$(echo "$RES" | jq -r '.stdout // ""')
ERR=$(echo "$RES" | jq -r '.stderr // ""')

if [ "$RAW" = 1 ]; then echo "$OUT"; else
  ANS=$(echo "$OUT" | jq -r '.response // empty' 2>/dev/null || true)
  if [ -n "$ANS" ]; then echo "$ANS"; else echo "$OUT"; fi
fi
if [ "$CODE" != 0 ]; then
  echo "agy exited $CODE" >&2; echo "$OUT" | jq -r '.error // empty' 2>/dev/null >&2 || true
  echo "$ERR" | tail -20 >&2
  echo "$OUT$ERR" | grep -qi 'auth\|login\|credential' && \
    echo "hint: log in once on $MACHINE: open its terminal, run 'agy', choose Google OAuth, paste the code." >&2
  exit "$CODE"
fi
