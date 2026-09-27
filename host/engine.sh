#!/usr/bin/env bash
# Start, stop, inspect one serving engine container from a profile in
# profiles/engines/<name>.env. Runs on the GPU host.
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: engine.sh [--debug] <start|stop|status|logs|meta|list> [engine]

Manage the serving engine container "bench-engine" from a profile.

Commands:
  list             Show available engine profiles
  start <engine>   Pull the image, start the container on 127.0.0.1:8000, wait for health
  stop             Stop and remove the container
  status           Container state and health
  logs [engine]    Tail container logs
  meta <engine>    Print JSON metadata: image digest, model, precision, GPU, driver

Environment (usually from /opt/bench/env and the suite runner):
  MODEL            Hugging Face model id (default meta-llama/Llama-3.1-8B-Instruct)
  MAX_MODEL_LEN    context length passed to the engine (default 4096)
  HF_TOKEN         needed for gated models
  HEALTH_TIMEOUT   seconds to wait for readiness (default 1800; first run downloads weights)
  <ENGINE>_TAG     pin an image tag, for example VLLM_TAG=v0.11.0

Flags:
  -h, --help       This help
  --debug          Write a support bundle to /var/tmp/chr-diag/ and print its path last
USAGE
}

parse_common_flags "$@"
set -- "${ARGS[@]}"

# ---- configuration ----------------------------------------------------------
# One container name for every engine so stop/status never need the profile.
CONTAINER="bench-engine"
HOST_PORT="${HOST_PORT:-8000}"
PROFILE_DIR="${BENCH_ROOT}/profiles/engines"
load_env_file /opt/bench/env
export MODEL="${MODEL:-meta-llama/Llama-3.1-8B-Instruct}"
export MAX_MODEL_LEN="${MAX_MODEL_LEN:-4096}"
export HF_HOME="${HF_HOME:-/var/lib/bench/hf-cache}"

# ---- helpers ----------------------------------------------------------------
# Source a profile with allexport so its ENGINE_* variables reach docker run.
load_profile() {
  local name="$1" f="${PROFILE_DIR}/${name}.env"
  [ -f "$f" ] || die "unknown engine profile: $name (see: engine.sh list)"
  # Profiles are trusted repository files; they use ${VAR:-default} expansion.
  set -a; # shellcheck disable=SC1090
  source "$f"; set +a
}

cmd_list() { ls "$PROFILE_DIR" | sed 's/\.env$//'; }

# Save the last log before removing the container; run-suite.sh copies it on failure.
cmd_stop() {
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    log "stopping $CONTAINER"
    docker logs "$CONTAINER" > "/tmp/${CONTAINER}-last.log" 2>&1 || true
    docker rm -f "$CONTAINER" >/dev/null
  fi
}

# Pull, run with GPU access on loopback, wait for health, run any post-start hook.
cmd_start() {
  local name="$1"; load_profile "$name"
  require_cmd docker curl
  cmd_stop
  log "engine=$ENGINE_NAME image=$ENGINE_IMAGE model=$MODEL"
  if [ "$ENGINE_NAME" = "nim" ]; then
    [ -n "${NGC_API_KEY:-}" ] || die "NIM needs NGC_API_KEY in /opt/bench/env"
    echo "$NGC_API_KEY" | docker login nvcr.io -u '$oauthtoken' --password-stdin >/dev/null
  fi
  docker pull "$ENGINE_IMAGE"
  # --ipc=host and a large shm are required by vLLM and SGLang for tensor
  # parallel and CUDA graph capture even on a single GPU.
  local entry=()
  [ -n "${ENGINE_ENTRYPOINT:-}" ] && entry=(--entrypoint "$ENGINE_ENTRYPOINT")
  # shellcheck disable=SC2086
  docker run -d --name "$CONTAINER" --gpus all --ipc=host --shm-size=8g \
    -p "127.0.0.1:${HOST_PORT}:${ENGINE_PORT}" \
    -v "${HF_HOME}:/root/.cache/huggingface" \
    -e "HF_TOKEN=${HF_TOKEN:-}" -e "HUGGING_FACE_HUB_TOKEN=${HF_TOKEN:-}" \
    $ENGINE_ENV "${entry[@]}" "$ENGINE_IMAGE" $ENGINE_ARGS >/dev/null
  "${BENCH_ROOT}/host/wait-healthy.sh" --url "http://127.0.0.1:${HOST_PORT}${ENGINE_HEALTH_PATH}" \
    --container "$CONTAINER" --timeout "${HEALTH_TIMEOUT:-1800}"
  if [ -n "${ENGINE_POST_START:-}" ]; then
    log "post-start: $ENGINE_POST_START"
    bash -c "$ENGINE_POST_START"
  fi
  # Confirm the model is served under the expected name.
  curl -fsS "http://127.0.0.1:${HOST_PORT}/v1/models" | jq -r '.data[].id' | sed 's/^/  served model: /'
  log "engine $ENGINE_NAME ready on 127.0.0.1:${HOST_PORT} (model name in requests: $ENGINE_MODEL_NAME)"
}

cmd_status() {
  docker ps -a --filter "name=^${CONTAINER}$" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
  curl -fsS -o /dev/null -w 'http /v1/models: %{http_code}\n' "http://127.0.0.1:${HOST_PORT}/v1/models" || true
}

cmd_logs() { docker logs -f --tail 200 "$CONTAINER"; }

# Emit the metadata that makes a result reproducible: image digest, model,
# precision, engine arguments, GPU, driver, kernel, plan, region.
cmd_meta() {
  local name="$1"; load_profile "$name"
  local digest="" image_id=""
  if docker image inspect "$ENGINE_IMAGE" >/dev/null 2>&1; then
    digest="$(docker image inspect "$ENGINE_IMAGE" --format '{{join .RepoDigests ","}}')"
    image_id="$(docker image inspect "$ENGINE_IMAGE" --format '{{.Id}}')"
  fi
  local gpu driver
  gpu="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1 || echo unknown)"
  driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo unknown)"
  jq -n --arg engine "$ENGINE_NAME" --arg image "$ENGINE_IMAGE" --arg digest "$digest" \
        --arg image_id "$image_id" --arg model "$MODEL" --arg served "$ENGINE_MODEL_NAME" \
        --arg precision "$ENGINE_PRECISION" --arg notes "$ENGINE_NOTES" --arg args "$ENGINE_ARGS" \
        --arg gpu "$gpu" --arg driver "$driver" --arg plan "${BENCH_PLAN:-}" --arg region "${BENCH_REGION:-}" \
        --arg max_model_len "$MAX_MODEL_LEN" --arg kernel "$(uname -r)" \
        '{engine:$engine,image:$image,image_digest:$digest,image_id:$image_id,model:$model,served_model_name:$served,
          precision:$precision,engine_args:$args,notes:$notes,gpu:$gpu,driver:$driver,plan:$plan,region:$region,
          max_model_len:($max_model_len|tonumber),kernel:$kernel}'
}

# ---- dispatch ---------------------------------------------------------------
case "${1:-}" in
  list) cmd_list ;;
  start) [ -n "${2:-}" ] || die "start needs an engine name"; cmd_start "$2" ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  logs) cmd_logs ;;
  meta) [ -n "${2:-}" ] || die "meta needs an engine name"; cmd_meta "$2" ;;
  *) usage; exit 1 ;;
esac
debug_add "/tmp/${CONTAINER}-last.log" "last engine container log"
debug_finalize
