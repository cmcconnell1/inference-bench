#!/usr/bin/env bash
# Sample GPU utilization, memory, power and clocks to CSV once per second.
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: gpu-sampler.sh [--debug] start <out.csv> | stop

start  Run nvidia-smi in the background writing CSV to <out.csv>; PID stored in /tmp/gpu-sampler.pid
stop   Stop the background sampler

Columns: timestamp, gpu index, name, utilization.gpu, utilization.memory,
memory.used, memory.total, power.draw, temperature.gpu, clocks.sm, clocks.mem

Flags:
  -h, --help   This help
  --debug      Write a support bundle to /var/tmp/chr-diag/
USAGE
}

parse_common_flags "$@"
set -- "${ARGS[@]}"
# Single sampler at a time; the PID file lets stop find it from another shell.
PIDFILE=/tmp/gpu-sampler.pid
case "${1:-}" in
  start)
    [ -n "${2:-}" ] || die "start needs an output path"
    require_cmd nvidia-smi
    "$0" stop >/dev/null 2>&1 || true
    nohup nvidia-smi --query-gpu=timestamp,index,name,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,temperature.gpu,clocks.sm,clocks.mem \
      --format=csv -l 1 > "$2" 2>/dev/null &
    echo $! > "$PIDFILE"
    log "gpu sampler pid $(cat "$PIDFILE") -> $2"
    ;;
  stop)
    if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; fi
    ;;
  *) usage; exit 1 ;;
esac
debug_finalize
