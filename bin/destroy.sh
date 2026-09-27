#!/usr/bin/env bash
# terraform destroy. Deletes the instance, firewall and key. Stops billing.
source "$(dirname "$0")/../lib/common.sh"
usage() {
  cat <<'USAGE'
Usage: destroy.sh [--debug] [--auto-approve] [--keep-results]

Destroys everything in terraform/. Fetches results first unless --keep-results
is given (meaning: results already fetched, skip). Powered-off instances still
bill; destroy is the only way to stop charges.

Flags:
  --auto-approve  Skip the terraform confirmation prompt
  --keep-results  Do not attempt fetch-results.sh before destroying
  -h, --help      This help
  --debug         Write a support bundle to /var/tmp/chr-diag/
USAGE
}
parse_common_flags "$@"; set -- "${ARGS[@]}"
AUTO=""; FETCH=1
for a in "$@"; do case "$a" in --auto-approve) AUTO="-auto-approve" ;; --keep-results) FETCH=0 ;; *) die "unknown argument: $a" ;; esac; done
require_cmd terraform
[ -n "${LINODE_TOKEN:-}" ] || die "LINODE_TOKEN is not set"
[ "$FETCH" = 1 ] && "$BENCH_ROOT/bin/fetch-results.sh" || warn "fetch skipped or failed; continuing with destroy"
terraform -chdir="$BENCH_ROOT/terraform" destroy -input=false $AUTO
rm -f "$BENCH_ROOT/results/instance.json"
log "destroyed. Confirm in Cloud Manager that no GPU Linode remains."
debug_finalize
