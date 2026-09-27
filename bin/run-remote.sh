#!/usr/bin/env bash
# Start run-suite.sh on the instance inside tmux so an SSH drop does not kill the run.
source "$(dirname "$0")/../lib/common.sh"
usage() {
  cat <<'USAGE'
Usage: run-remote.sh [--debug] [--attach] [run-suite.sh options...]

Launches /opt/bench/host/run-suite.sh in a detached tmux session named "bench"
on the instance from results/instance.json, logging to /var/lib/bench/suite.log.
All other arguments are passed through to run-suite.sh, for example:

  run-remote.sh --engines vllm,sglang --workloads akamai-blog-200x200 --repeat 3

Flags:
  --attach     Attach to the tmux session after starting
  -h, --help   This help
  --debug      Write a support bundle to /var/tmp/chr-diag/
USAGE
}
parse_common_flags "$@"; set -- "${ARGS[@]}"
require_cmd ssh jq
ATTACH=0; PASS=()
for a in "$@"; do case "$a" in --attach) ATTACH=1 ;; *) PASS+=("$a") ;; esac; done
IP="$(jq -r .ip "$BENCH_ROOT/results/instance.json" 2>/dev/null || true)"
[ -n "$IP" ] && [ "$IP" != null ] || die "results/instance.json missing; run provision.sh"
# Quote arguments for the remote shell, then start run-suite.sh inside tmux so
# the run survives an SSH disconnect. The trailing sleep keeps the pane open
# for attach after completion.
remote_args="$(printf '%q ' "${PASS[@]}")"
ssh "root@$IP" "tmux has-session -t bench 2>/dev/null && { echo 'a bench session is already running; attach with: ssh root@$IP tmux attach -t bench'; exit 1; }
  tmux new-session -d -s bench \"bash -lc '/opt/bench/host/run-suite.sh ${remote_args} 2>&1 | tee -a /var/lib/bench/suite.log; echo SUITE-EXIT; sleep 3600'\""
log "started. follow with: ssh root@$IP tail -f /var/lib/bench/suite.log"
[ "$ATTACH" = 1 ] && ssh -t "root@$IP" tmux attach -t bench
debug_finalize
