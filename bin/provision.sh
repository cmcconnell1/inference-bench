#!/usr/bin/env bash
# terraform init + apply, then wait for cloud-init to finish and the GPU to appear.
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: provision.sh [--debug] [--auto-approve] [--no-wait]

Creates the GPU instance and firewall from terraform/, then polls over SSH
until /var/lib/bench/bootstrap-complete exists and nvidia-smi reports a GPU.
Writes results/instance.json with ip, plan, region, created time.

Billing starts at apply. Run bin/budget-guard.sh in another terminal.

Flags:
  --auto-approve  Skip the terraform confirmation prompt
  --no-wait       Return right after apply without waiting for bootstrap
  -h, --help      This help
  --debug         Write a support bundle to /var/tmp/chr-diag/
USAGE
}

parse_common_flags "$@"
set -- "${ARGS[@]}"
AUTO=""; WAIT=1
for a in "$@"; do case "$a" in --auto-approve) AUTO="-auto-approve" ;; --no-wait) WAIT=0 ;; *) die "unknown argument: $a" ;; esac; done
require_cmd terraform jq ssh
[ -n "${LINODE_TOKEN:-}" ] || die "LINODE_TOKEN is not set"
TF="$BENCH_ROOT/terraform"
[ -f "$TF/terraform.tfvars" ] || die "terraform/terraform.tfvars missing; copy terraform.tfvars.example and set allowed_cidrs"

# ---- apply ------------------------------------------------------------------
terraform -chdir="$TF" init -input=false
terraform -chdir="$TF" apply -input=false $AUTO
IP="$(tf_output ip_address)"; PLAN="$(tf_output plan)"; REGION="$(tf_output region)"
mkdir -p "$BENCH_ROOT/results"
jq -n --arg ip "$IP" --arg plan "$PLAN" --arg region "$REGION" --arg created "$(date -u +%FT%TZ)" \
  '{ip:$ip,plan:$plan,region:$region,created:$created}' > "$BENCH_ROOT/results/instance.json"
log "instance $IP ($PLAN in $REGION). Billing has started."

# ---- wait for bootstrap -----------------------------------------------------
# cloud-init installs the driver and reboots; the marker file is created just
# before the reboot and nvidia-smi -L proves the module loaded after it.
if [ "$WAIT" = 1 ]; then
  log "waiting for cloud-init bootstrap and reboot (driver install takes 5 to 10 minutes)"
  SSH=(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "root@$IP")
  start=$(date +%s)
  until "${SSH[@]}" 'test -f /var/lib/bench/bootstrap-complete && nvidia-smi -L' 2>/dev/null; do
    (( $(date +%s) - start > 1500 )) && die "bootstrap did not finish in 25 minutes; ssh in and read /var/log/bench-bootstrap.log"
    sleep 20
  done
  "${SSH[@]}" 'nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv'
  log "bootstrap complete"
fi
echo "IP: $IP"
echo "next: bin/sync.sh && bin/run-remote.sh --engines vllm --workloads smoke"
debug_add "$BENCH_ROOT/results/instance.json" "instance facts"
debug_finalize
