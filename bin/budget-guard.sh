#!/usr/bin/env bash
# Hard stop on spend: destroy the instance after N hours no matter what.
source "$(dirname "$0")/../lib/common.sh"
usage() {
  cat <<'USAGE'
Usage: budget-guard.sh [--debug] --hours H [--price-per-hour P]

Sleeps H hours (fractional ok), fetches results, then runs terraform destroy
-auto-approve. Prints the projected spend up front. Run it in a second
terminal or under nohup right after provision.sh:

  nohup bin/budget-guard.sh --hours 3 > results/budget-guard.log 2>&1 &

Cancel with: kill $(pgrep -f budget-guard.sh)

Flags:
  --hours H           Time limit
  --price-per-hour P  Override the plan price from profiles/pricing.json
  -h, --help          This help
  --debug             Write a support bundle to /var/tmp/chr-diag/
USAGE
}
parse_common_flags "$@"; set -- "${ARGS[@]}"
HOURS=""; PRICE=""
while [ $# -gt 0 ]; do case "$1" in --hours) HOURS="$2"; shift 2 ;; --price-per-hour) PRICE="$2"; shift 2 ;; *) die "unknown argument: $1" ;; esac; done
[ -n "$HOURS" ] || die "--hours is required"
require_cmd jq terraform
# ---- projected spend --------------------------------------------------------
PLAN="$(jq -r .plan "$BENCH_ROOT/results/instance.json" 2>/dev/null || echo unknown)"
[ -z "$PRICE" ] && PRICE="$(jq -r --arg p "$PLAN" '.plans[$p].hourly_usd // "unknown"' "$BENCH_ROOT/profiles/pricing.json")"
log "plan=$PLAN price=\$${PRICE}/hr limit=${HOURS}h projected=\$$(python3 -c "print(round(float('$HOURS')*float('${PRICE/unknown/0}'),2))")"
log "destroy at $(date -u -v+"${HOURS%.*}"H +%FT%TZ 2>/dev/null || date -u -d "+${HOURS} hours" +%FT%TZ 2>/dev/null || echo 'limit')"
# ---- wait, then destroy -----------------------------------------------------
# Fetch first so the run is not lost; destroy regardless of fetch outcome.
sleep "$(python3 -c "print(int(float('$HOURS')*3600))")"
log "time limit reached; fetching results and destroying"
"$BENCH_ROOT/bin/fetch-results.sh" || warn "fetch failed; destroying anyway"
terraform -chdir="$BENCH_ROOT/terraform" destroy -input=false -auto-approve
rm -f "$BENCH_ROOT/results/instance.json"
log "destroyed by budget guard"
debug_finalize
