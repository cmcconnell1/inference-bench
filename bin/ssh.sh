#!/usr/bin/env bash
# SSH to the instance, or open a tunnel for the engine port.
source "$(dirname "$0")/../lib/common.sh"
usage() {
  cat <<'USAGE'
Usage: ssh.sh [--debug] [--tunnel] [command...]

Without arguments: interactive shell as root on the instance from results/instance.json.
--tunnel: forward local 8000 to the engine on the instance (Ctrl-C to stop), so
          curl http://127.0.0.1:8000/v1/models works from this machine.
Any other arguments run as a remote command.

Flags:
  -h, --help   This help
  --debug      Write a support bundle to /var/tmp/chr-diag/
USAGE
}
parse_common_flags "$@"; set -- "${ARGS[@]}"
require_cmd ssh jq
IP="$(jq -r .ip "$BENCH_ROOT/results/instance.json" 2>/dev/null || true)"
[ -n "$IP" ] && [ "$IP" != null ] || die "results/instance.json missing"
if [ "${1:-}" = "--tunnel" ]; then
  log "tunnel: http://127.0.0.1:8000 -> $IP:8000"
  exec ssh -N -L 8000:127.0.0.1:8000 "root@$IP"
fi
exec ssh -o StrictHostKeyChecking=accept-new "root@$IP" "$@"
