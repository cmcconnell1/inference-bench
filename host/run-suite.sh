#!/usr/bin/env bash
# Orchestrate a full benchmark suite on the GPU host:
#   for each engine: start -> health -> warmup -> for each workload x concurrency: sample GPU + guidellm -> stop
# Results land in $BENCH_RESULTS/<run-id>/<engine>/<workload>/c<N>/.
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: run-suite.sh [--debug] [--engines a,b,c] [--workloads x,y] [--run-id ID] [--model HF_ID]
                    [--repeat N] [--dry-run]

Runs every engine against every workload profile at each configured concurrency.

Options:
  --engines     Comma list of engine profiles (default: vllm,sglang,tgi,ollama,llamacpp)
                NIM is excluded by default; add it explicitly when NGC_API_KEY is set.
  --workloads   Comma list from profiles/workloads/ (default: akamai-blog-200x200,chat-short)
  --run-id      Directory name under $BENCH_RESULTS (default: UTC timestamp)
  --model       Hugging Face model id for HF-backed engines (default: meta-llama/Llama-3.1-8B-Instruct)
  --repeat      Repetitions per concurrency point (default 1; use 3 for a reportable run)
  --dry-run     Print the plan and exit
  -h, --help    This help
  --debug       Write a support bundle to /var/tmp/chr-diag/

Environment: see /opt/bench/env (HF_TOKEN, BENCH_PLAN, BENCH_REGION, BENCH_RESULTS).
Engine image pins: VLLM_TAG, SGLANG_TAG, TGI_TAG, OLLAMA_TAG, LLAMACPP_TAG, NIM_TAG.
USAGE
}

parse_common_flags "$@"
set -- "${ARGS[@]}"
load_env_file /opt/bench/env
# ---- defaults and argument parsing -----------------------------------------
ENGINES="vllm,sglang,tgi,ollama,llamacpp"
WORKLOADS="akamai-blog-200x200,chat-short"
RUN_ID="$(UTC_NOW)"
export MODEL="${MODEL:-meta-llama/Llama-3.1-8B-Instruct}"
REPEAT=1; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --engines) ENGINES="$2"; shift 2 ;;
    --workloads) WORKLOADS="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --model) export MODEL="$2"; shift 2 ;;
    --repeat) REPEAT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
require_cmd docker jq curl nvidia-smi
RESULTS="${BENCH_RESULTS:-/var/lib/bench/results}/${RUN_ID}"
HOST="${BENCH_ROOT}/host"
WL_DIR="${BENCH_ROOT}/profiles/workloads"
mkdir -p "$RESULTS"

# Validate inputs before touching the GPU.
IFS=',' read -r -a ENGINE_LIST <<<"$ENGINES"
IFS=',' read -r -a WL_LIST <<<"$WORKLOADS"
for w in "${WL_LIST[@]}"; do [ -f "$WL_DIR/$w.json" ] || die "unknown workload: $w"; done

log "run-id=$RUN_ID engines=$ENGINES workloads=$WORKLOADS model=$MODEL repeat=$REPEAT"
if [ "$DRY" = 1 ]; then
  for e in "${ENGINE_LIST[@]}"; do for w in "${WL_LIST[@]}"; do
    for c in $(jq -r '.concurrency[]' "$WL_DIR/$w.json"); do echo "  $e / $w / c$c x$REPEAT"; done
  done; done
  exit 0
fi

# ---- run-level metadata -----------------------------------------------------
# Captured once per run: driver, GPU, Docker, guidellm, OS, and the plan.
{
  nvidia-smi -q > "$RESULTS/nvidia-smi-q.txt" 2>&1 || true
  nvidia-smi > "$RESULTS/nvidia-smi.txt" 2>&1 || true
  docker version > "$RESULTS/docker-version.txt" 2>&1 || true
  /opt/bench/venv/bin/guidellm --version > "$RESULTS/guidellm-version.txt" 2>&1 || true
  cat /etc/os-release > "$RESULTS/os-release.txt"
  uname -a > "$RESULTS/uname.txt"
  jq -n --arg run_id "$RUN_ID" --arg model "$MODEL" --arg plan "${BENCH_PLAN:-}" --arg region "${BENCH_REGION:-}" \
        --arg engines "$ENGINES" --arg workloads "$WORKLOADS" --argjson repeat "$REPEAT" --arg started "$(date -u +%FT%TZ)" \
        '{run_id:$run_id,model:$model,plan:$plan,region:$region,engines:($engines|split(",")),workloads:($workloads|split(",")),repeat:$repeat,started:$started}' \
        > "$RESULTS/run.json"
}

# ---- helpers ----------------------------------------------------------------
# Short synchronous burst so lazy initialisation (CUDA graphs, first-token
# kernels, model load into cache) is not charged to the first measured point.
warmup() {
  # A short synchronous burst so the first measured point does not pay for lazy init.
  local served="$1" secs="$2" end=$(( $(date +%s) + secs )) n=0
  while (( $(date +%s) < end )); do
    curl -s -o /dev/null --max-time 60 "http://127.0.0.1:8000/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"${served}\",\"messages\":[{\"role\":\"user\",\"content\":\"Write three sentences about benchmarking.\"}],\"max_tokens\":64}" || true
    n=$((n+1))
  done
  log "warmup: $n requests in ${secs}s"
}

# ---- main loop: engine -> workload -> concurrency -> repetition ---------------
# An engine that fails to start is recorded and skipped; the suite continues so
# one broken image does not cost the whole run.
for engine in "${ENGINE_LIST[@]}"; do
  edir="$RESULTS/$engine"; mkdir -p "$edir"
  log "===== engine: $engine ====="
  if ! "$HOST/engine.sh" start "$engine" > "$edir/engine-start.log" 2>&1; then
    warn "engine $engine failed to start; see $edir/engine-start.log"
    cp /tmp/bench-engine-last.log "$edir/engine-container.log" 2>/dev/null || true
    echo '{"status":"start_failed"}' > "$edir/status.json"
    "$HOST/engine.sh" stop || true
    continue
  fi
  "$HOST/engine.sh" meta "$engine" > "$edir/meta.json"
  served="$(jq -r .served_model_name "$edir/meta.json")"
  for wl in "${WL_LIST[@]}"; do
    wjson="$WL_DIR/$wl.json"
    pt=$(jq -r .prompt_tokens "$wjson"); ot=$(jq -r .output_tokens "$wjson")
    maxs=$(jq -r .max_seconds "$wjson"); warm=$(jq -r '.warmup_seconds // 30' "$wjson")
    wdir="$edir/$wl"; mkdir -p "$wdir"; cp "$wjson" "$wdir/workload.json"
    warmup "$served" "$warm"
    for c in $(jq -r '.concurrency[]' "$wjson"); do
      for r in $(seq 1 "$REPEAT"); do
        out="$wdir/c${c}"; [ "$REPEAT" -gt 1 ] && out="$out/r${r}"
        mkdir -p "$out"
        # Sample the GPU only while guidellm is running so idle seconds do not
        # dilute utilisation and power averages.
        "$HOST/gpu-sampler.sh" start "$out/gpu.csv"
        "$HOST/run-bench.sh" --model "$served" --prompt-tokens "$pt" --output-tokens "$ot" \
          --concurrency "$c" --max-seconds "$maxs" --out "$out" || warn "point failed: $engine/$wl/c$c"
        "$HOST/gpu-sampler.sh" stop
        docker logs --since "${maxs}s" bench-engine > "$out/engine-tail.log" 2>&1 || true
      done
    done
  done
  echo '{"status":"ok"}' > "$edir/status.json"
  "$HOST/engine.sh" stop
done
# Stamp the finish time and print the results path for run-remote.sh/fetch.
jq --arg finished "$(date -u +%FT%TZ)" '. + {finished:$finished}' "$RESULTS/run.json" > "$RESULTS/run.json.tmp" && mv "$RESULTS/run.json.tmp" "$RESULTS/run.json"
log "suite complete: $RESULTS"
echo "RESULTS: $RESULTS"
debug_add "$RESULTS" "full suite results"
debug_finalize
