#!/usr/bin/env bash
# Run one guidellm measurement at a fixed concurrency against the local engine.
# Wraps guidellm so the rest of the harness does not depend on its CLI shape.
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: run-bench.sh [--debug] --model <served-name> --prompt-tokens N --output-tokens N \
                    --concurrency N --max-seconds N --out <dir> [--target URL] [--processor HF_ID]

Runs guidellm in "concurrent" mode (N always-open streams) for a fixed duration
against an OpenAI-compatible endpoint and writes results to <dir>/guidellm.json
(plus CSV and HTML when the installed version supports them).

Defaults:
  --target      http://127.0.0.1:8000
  --processor   $MODEL (tokenizer used to size synthetic prompts)

Flags:
  -h, --help    This help
  --debug       Write a support bundle to /var/tmp/chr-diag/
USAGE
}

parse_common_flags "$@"
set -- "${ARGS[@]}"
load_env_file /opt/bench/env
# ---- defaults and argument parsing -----------------------------------------
TARGET="http://127.0.0.1:8000"; PROCESSOR="${MODEL:-meta-llama/Llama-3.1-8B-Instruct}"
SERVED="" PT="" OT="" CONC="" MAXS="" OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --processor) PROCESSOR="$2"; shift 2 ;;
    --model) SERVED="$2"; shift 2 ;;
    --prompt-tokens) PT="$2"; shift 2 ;;
    --output-tokens) OT="$2"; shift 2 ;;
    --concurrency) CONC="$2"; shift 2 ;;
    --max-seconds) MAXS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
for v in SERVED PT OT CONC MAXS OUT; do [ -n "${!v}" ] || die "--$(echo "$v" | tr 'A-Z' 'a-z' | sed 's/served/model/;s/pt/prompt-tokens/;s/ot/output-tokens/;s/conc/concurrency/;s/maxs/max-seconds/') is required"; done
mkdir -p "$OUT"
# ---- locate guidellm ---------------------------------------------------------
GUIDELLM="${GUIDELLM_BIN:-/opt/bench/venv/bin/guidellm}"
[ -x "$GUIDELLM" ] || die "guidellm not found at $GUIDELLM"
export HF_TOKEN="${HF_TOKEN:-}" HUGGING_FACE_HUB_TOKEN="${HF_TOKEN:-}"

# guidellm changed its CLI between 0.3 (guidellm benchmark) and 0.6+ (guidellm run).
# Detect which one is installed and build the matching command line.
"$GUIDELLM" --version > "$OUT/guidellm-version.txt" 2>&1 || true
if "$GUIDELLM" run --help >/dev/null 2>&1; then
  help_text="$("$GUIDELLM" run --help 2>&1)"
  cmd=("$GUIDELLM" run
       --backend "kind=openai_http,target=${TARGET},model=${SERVED}"
       --profile "kind=concurrent,streams=${CONC}"
       --constraint "kind=max_duration,seconds=${MAXS}"
       --data "kind=synthetic_text,prompt_tokens=${PT},output_tokens=${OT},prompt_tokens_stdev=0,output_tokens_stdev=0")
  grep -q -- '--processor' <<<"$help_text" && cmd+=(--processor "$PROCESSOR")
  if grep -q -- '--output-path' <<<"$help_text"; then
    cmd+=(--output-path "$OUT/guidellm.json")
  elif grep -q -- '--outputs' <<<"$help_text"; then
    cmd+=(--output-dir "$OUT" --outputs json,csv,html)
  fi
else
  cmd=("$GUIDELLM" benchmark
       --target "$TARGET" --model "$SERVED" --processor "$PROCESSOR"
       --rate-type concurrent --rate "$CONC" --max-seconds "$MAXS"
       --data "prompt_tokens=${PT},output_tokens=${OT}"
       --output-path "$OUT/guidellm.json")
fi

# ---- run and normalise outputs -------------------------------------------------
# The exact command is saved so any point can be re-run by hand.
printf '%q ' "${cmd[@]}" > "$OUT/command.txt"; echo >> "$OUT/command.txt"
log "guidellm: concurrency=$CONC prompt=$PT output=$OT seconds=$MAXS -> $OUT"
start_ts=$(date -u +%FT%TZ)
if ! "${cmd[@]}" > "$OUT/guidellm.log" 2>&1; then
  tail -30 "$OUT/guidellm.log" >&2
  warn "guidellm exited non-zero; see $OUT/guidellm.log"
fi
# Some versions write to a default filename; normalize to guidellm.json.
if [ ! -f "$OUT/guidellm.json" ]; then
  f="$(ls -t "$OUT"/*.json 2>/dev/null | head -1 || true)"
  [ -n "$f" ] && mv "$f" "$OUT/guidellm.json"
fi
# run.json records what was asked for; guidellm.json records what happened.
jq -n --arg start "$start_ts" --arg end "$(date -u +%FT%TZ)" --arg model "$SERVED" \
      --argjson pt "$PT" --argjson ot "$OT" --argjson c "$CONC" --argjson s "$MAXS" \
      '{start:$start,end:$end,served_model_name:$model,prompt_tokens:$pt,output_tokens:$ot,concurrency:$c,max_seconds:$s}' \
      > "$OUT/run.json"
[ -f "$OUT/guidellm.json" ] || die "no guidellm.json produced in $OUT"
debug_add "$OUT" "guidellm run output"
debug_finalize
