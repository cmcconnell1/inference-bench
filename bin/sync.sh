#!/usr/bin/env bash
# Copy the harness (lib, host, profiles, analyze) to /opt/bench on the instance.
source "$(dirname "$0")/../lib/common.sh"
usage() {
  cat <<'USAGE'
Usage: sync.sh [--debug] [ip]

rsync lib/ host/ profiles/ analyze/ to root@<ip>:/opt/bench/. The ip defaults
to results/instance.json. Excludes caches, results, and tool metadata.

Flags:
  -h, --help   This help
  --debug      Write a support bundle to /var/tmp/chr-diag/
USAGE
}
parse_common_flags "$@"; set -- "${ARGS[@]}"
require_cmd rsync jq
IP="${1:-$(jq -r .ip "$BENCH_ROOT/results/instance.json" 2>/dev/null || true)}"
[ -n "$IP" ] && [ "$IP" != null ] || die "no ip: pass one or run provision.sh"
rsync -az --delete \
  --exclude '__pycache__' --exclude '.venv' --exclude '*.pyc' --exclude '.DS_Store' \
  "$BENCH_ROOT/lib" "$BENCH_ROOT/host" "$BENCH_ROOT/profiles" "$BENCH_ROOT/analyze" \
  "root@$IP:/opt/bench/"
ssh "root@$IP" 'chmod +x /opt/bench/host/*.sh /opt/bench/lib/*.sh; ls /opt/bench'
log "synced to root@$IP:/opt/bench"
debug_finalize
