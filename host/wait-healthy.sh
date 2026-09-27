#!/usr/bin/env bash
# Poll an HTTP health URL until it returns 2xx, failing fast if the container dies.
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: wait-healthy.sh [--debug] --url <http://...> [--container <name>] [--timeout <seconds>]

Polls the URL every 5 seconds until HTTP 2xx. Exits non-zero on timeout or if
the named container stops running. Prints a progress line every 30 seconds
with the container's latest log line so model downloads are visible.

Flags:
  -h, --help   This help
  --debug      Write a support bundle to /var/tmp/chr-diag/
USAGE
}

parse_common_flags "$@"
set -- "${ARGS[@]}"
URL="" CONTAINER="" TIMEOUT=1800
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$URL" ] || die "--url is required"

# ---- poll loop --------------------------------------------------------------
# Three exits: 2xx (success), container gone (fail fast), timeout (fail).
# Progress lines every 30 s include the container's last log line so a long
# model download is visibly progressing rather than silently hanging.
start=$(date +%s); last_report=0
while :; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL" || true)"
  if [[ "$code" =~ ^2 ]]; then log "healthy: $URL ($(( $(date +%s) - start ))s)"; debug_finalize; exit 0; fi
  if [ -n "$CONTAINER" ] && ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    docker logs --tail 50 "$CONTAINER" >&2 || true
    die "container $CONTAINER is not running"
  fi
  now=$(date +%s)
  if (( now - start > TIMEOUT )); then
    [ -n "$CONTAINER" ] && docker logs --tail 50 "$CONTAINER" >&2
    die "timeout after ${TIMEOUT}s waiting for $URL"
  fi
  if (( now - last_report >= 30 )); then
    last_report=$now
    tail_line=""
    [ -n "$CONTAINER" ] && tail_line="$(docker logs --tail 1 "$CONTAINER" 2>&1 | cut -c1-140)"
    log "waiting ($(( now - start ))s, http $code) ${tail_line}"
  fi
  sleep 5
done
