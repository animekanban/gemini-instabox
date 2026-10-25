#!/usr/bin/env bash
# Unified dispatcher: run agy on whichever InstaBox machine is free, with failover.
# usage:
#   gemini-dispatch.sh [script flags] "prompt"          one prompt, auto-picked machine
#   gemini-dispatch.sh -B prompts.txt [-P N] [flags]    batch: one prompt per line, N in parallel (default 2)
#   gemini-dispatch.sh -S                               status of every machine
# Script flags (-M -e -a -C -t -j -A) are passed to gemini-remote.sh. -m forces one machine (no failover).
# Needs GEMINI_IBX_MACHINES, INSTABOX_API_KEY.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
API="${INSTABOX_API_URL:-https://api.instabox.sh}"
: "${INSTABOX_API_KEY:?set INSTABOX_API_KEY}"
STATE="${GEMINI_IBX_STATE:-${TMPDIR:-/tmp}/gemini-ibx}"; mkdir -p "$STATE"

IFS=',' read -ra PAIRS <<< "${GEMINI_IBX_MACHINES:?set GEMINI_IBX_MACHINES}"
NAMES=(); for kv in "${PAIRS[@]}"; do NAMES+=("${kv%%=*}"); done
idof() { for kv in "${PAIRS[@]}"; do [ "${kv%%=*}" = "$1" ] && echo "${kv#*=}"; done; }

status() {
  local L; L=$(curl -sS -m 20 "$API/v1/machines" -H "X-API-Key: $INSTABOX_API_KEY")
  for n in "${NAMES[@]}"; do
    local id; id=$(idof "$n")
    echo "$L" | jq -r --arg id "$id" --arg n "$n" '.machines[]|select(.id==$id)|"\($n)\t\(.state)\tcooldownUntil=\(.cooldownUntil//"-")"'
  done
}

# order machines: least-recently-used first, skipping ones marked busy/cooling
pick_order() {
  local now; now=$(date +%s)
  for n in "${NAMES[@]}"; do
    local until=0 last=0
    [ -f "$STATE/$n.cool" ] && until=$(cat "$STATE/$n.cool")
    [ -f "$STATE/$n.last" ] && last=$(cat "$STATE/$n.last")
    [ "$until" -gt "$now" ] && continue
    echo "$last $n"
  done | sort -n | awk '{print $2}'
}

run_one() {  # args: passthrough flags..., prompt via stdin
  local out err rc tried=0
  for n in $(pick_order); do
    tried=1
    # simple lock so parallel jobs don't share a machine
    exec {fd}>"$STATE/$n.lock"; flock -n "$fd" || { exec {fd}>&-; continue; }
    date +%s > "$STATE/$n.last"
    out=$(printf '%s' "$PROMPT_IN" | bash "$DIR/gemini-remote.sh" -m "$n" "$@" 2>"$STATE/$$.err"); rc=$?
    err=$(cat "$STATE/$$.err"); flock -u "$fd"; exec {fd}>&-
    if [ $rc = 0 ]; then echo "$out"; echo "[machine: $n]" >&2; return 0; fi
    if [ $rc = 3 ]; then echo $(( $(date +%s)+600 )) > "$STATE/$n.cool"; echo "[$n unavailable, trying next]" >&2; continue; fi
    if echo "$out$err" | grep -q 'RESOURCE_EXHAUSTED\|429'; then
      echo "[quota hit on shared account; waiting 30s then one retry]" >&2; sleep 30
      out=$(printf '%s' "$PROMPT_IN" | bash "$DIR/gemini-remote.sh" -m "$n" "$@"); rc=$?
      [ $rc = 0 ] && { echo "$out"; return 0; }
      return $rc
    fi
    if echo "$out$err" | grep -qi 'authentication required'; then echo "[$n not logged in, trying next]" >&2; continue; fi
    echo "$out"; echo "$err" >&2; return $rc
  done
  [ $tried = 0 ] && echo "no machine available (all cooling/busy)" >&2
  return 4
}

BATCH=""; PAR=2; PASS=(); FORCE=""
while getopts "B:P:Sm:M:e:a:C:t:jALh" o; do
  case $o in
    S) status; exit 0;; B) BATCH=$OPTARG;; P) PAR=$OPTARG;; m) FORCE=$OPTARG;;
    M|e|a|C|t) PASS+=("-$o" "$OPTARG");; j) PASS+=(-j);; A) PASS+=(-A);; L) exec bash "$DIR/gemini-remote.sh" -m "${NAMES[0]}" -L;;
    h) sed -n 2,9p "$0"; exit 0;; *) exit 2;;
  esac
done
shift $((OPTIND-1))
[ -n "$FORCE" ] && exec bash "$DIR/gemini-remote.sh" -m "$FORCE" "${PASS[@]}" "$@"

if [ -n "$BATCH" ]; then
  export -f run_one pick_order idof; export DIR API STATE GEMINI_IBX_MACHINES INSTABOX_API_KEY
  i=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue; i=$((i+1))
    ( PAIRS=(); IFS=',' read -ra PAIRS <<< "$GEMINI_IBX_MACHINES"; NAMES=(); for kv in "${PAIRS[@]}"; do NAMES+=("${kv%%=*}"); done
      PROMPT_IN="$line" run_one "${PASS[@]}" > "$STATE/out.$i" 2>"$STATE/log.$i"; echo $? > "$STATE/rc.$i" ) &
    while [ "$(jobs -rp | wc -l)" -ge "$PAR" ]; do sleep 1; done
  done < "$BATCH"
  wait
  for j in $(seq 1 $i); do echo "=== [$j] rc=$(cat "$STATE/rc.$j") $(grep -o 'machine: [a-z0-9]*' "$STATE/log.$j")"; cat "$STATE/out.$j"; done
  exit 0
fi

PROMPT_IN=""; [ -t 0 ] || PROMPT_IN="$(cat)"
[ $# -gt 0 ] && PROMPT_IN="${PROMPT_IN:+$PROMPT_IN

}$*"
[ -n "$PROMPT_IN" ] || { sed -n 2,9p "$0"; exit 2; }
run_one "${PASS[@]}"
