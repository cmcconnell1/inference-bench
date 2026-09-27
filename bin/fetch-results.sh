#!/usr/bin/env bash
# Pull /var/lib/bench/results back to ./results/ for offline analysis.
source "$(dirname "$0")/../lib/common.sh"
usage() {
  cat <<'USAGE'
Usage: fetch-results.sh [--debug] [run-id]

rsync /var/lib/bench/results/<run-id>/ (or all runs) from the instance in
results/instance.json into ./results/. Then run:
  python3 analyze/cost.py results/<run-id>
  python3 analyze/report.py results/<run-id> > results/<run-id>/REPORT.md

Flags:
  -h, --help   This help
  --debug      Write a support bundle to /var/tmp/chr-diag/
USAGE
}
parse_common_flags "$@"; set -- "${ARGS[@]}"
require_cmd rsync jq
IP="$(jq -r .ip "$BENCH_ROOT/results/instance.json" 2>/dev/null || true)"
[ -n "$IP" ] && [ "$IP" != null ] || die "results/instance.json missing"
SUB="${1:-}"
rsync -az "root@$IP:/var/lib/bench/results/${SUB}" "$BENCH_ROOT/results/"
rsync -az "root@$IP:/var/lib/bench/suite.log" "$BENCH_ROOT/results/suite.log" 2>/dev/null || true
ls -1 "$BENCH_ROOT/results"
debug_finalize
