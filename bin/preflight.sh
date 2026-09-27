#!/usr/bin/env bash
# Verify the Akamai account can build the target before spending anything:
# token works, plan exists, region offers GPU plans and the Metadata service,
# and print the live hourly price next to profiles/pricing.json.
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: preflight.sh [--debug] [--plan TYPE] [--region ID]

Checks, via the Linode API v4 using $LINODE_TOKEN:
  1. token is valid (GET /profile)
  2. plan type exists and prints vCPU, RAM, GPUs, hourly and monthly price
  3. region exists and lists "GPU Linodes" and "Metadata" capabilities
  4. local tools present: terraform, jq, rsync, ssh
  5. profiles/pricing.json agrees with the API price (warns on drift)

Defaults come from terraform/terraform.tfvars if present, else
plan=g2-gpu-rtx4000a1-s region=us-ord.

Flags:
  -h, --help   This help
  --debug      Write a support bundle to /var/tmp/chr-diag/
USAGE
}

parse_common_flags "$@"
set -- "${ARGS[@]}"
# ---- defaults: read plan and region from tfvars when present ----------------
TFVARS="$BENCH_ROOT/terraform/terraform.tfvars"
PLAN="$( [ -f "$TFVARS" ] && grep -E '^plan' "$TFVARS" | sed -E 's/.*"(.*)".*/\1/' || true)"
REGION="$( [ -f "$TFVARS" ] && grep -E '^region' "$TFVARS" | sed -E 's/.*"(.*)".*/\1/' || true)"
PLAN="${PLAN:-g2-gpu-rtx4000a1-s}"; REGION="${REGION:-us-ord}"
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
require_cmd curl jq
[ -n "${LINODE_TOKEN:-}" ] || die "LINODE_TOKEN is not set (create a Personal Access Token in Cloud Manager)"
# Thin wrapper over the Linode API v4; fails on non-2xx so checks are simple.
api() { curl -fsS -H "Authorization: Bearer $LINODE_TOKEN" "https://api.linode.com/v4$1"; }

# ---- checks -------------------------------------------------------------------
# Each check prints ok/FAIL and sets fail=1; the script exits non-zero at the
# end so all problems are visible in one pass.
fail=0
echo "== 1. token"
if api /profile | jq -r '"   ok: " + .username' ; then :; else echo "   FAIL: token rejected"; fail=1; fi

echo "== 2. plan $PLAN"
if t="$(api "/linode/types/$PLAN" 2>/dev/null)"; then
  echo "$t" | jq -r '"   \(.label): vcpus=\(.vcpus) ram_mb=\(.memory) disk_mb=\(.disk) gpus=\(.gpus) hourly=$\(.price.hourly) monthly=$\(.price.monthly) transfer_gb=\(.transfer)"'
  api_hourly="$(echo "$t" | jq -r .price.hourly)"
  local_hourly="$(jq -r --arg p "$PLAN" '.plans[$p].hourly_usd // "null"' "$BENCH_ROOT/profiles/pricing.json")"
  if [ "$local_hourly" != "null" ] && [ "$local_hourly" != "$api_hourly" ]; then
    echo "   WARNING: profiles/pricing.json says $local_hourly/hr, API says $api_hourly/hr. Update pricing.json."
  fi
else
  echo "   FAIL: plan not found (list with: curl ... /linode/types | jq '.data[] | select(.class==\"gpu\") | .id')"; fail=1
fi

echo "== 3. region $REGION"
if r="$(api "/regions/$REGION" 2>/dev/null)"; then
  caps="$(echo "$r" | jq -r '.capabilities | join(", ")')"
  echo "   capabilities: $caps"
  echo "$caps" | grep -q "GPU Linodes" || { echo "   FAIL: region has no GPU plans"; fail=1; }
  echo "$caps" | grep -q "Metadata"    || { echo "   FAIL: region lacks Metadata service (cloud-init user_data)"; fail=1; }
else
  echo "   FAIL: region not found"; fail=1
fi

echo "== 4. local tools"
for c in terraform jq rsync ssh; do
  if command -v "$c" >/dev/null; then echo "   ok: $c"; else echo "   FAIL: missing $c"; fail=1; fi
done
[ -f "$TFVARS" ] || echo "   NOTE: terraform/terraform.tfvars missing; copy terraform.tfvars.example"
echo "== 5. operator public IP (for allowed_cidrs)"
echo "   $(curl -4 -s --max-time 5 https://ifconfig.me || echo unknown)/32"

debug_note "plan=$PLAN region=$REGION fail=$fail"
debug_finalize
[ "$fail" = 0 ] && echo "PREFLIGHT: OK" || { echo "PREFLIGHT: FAILED"; exit 1; }
