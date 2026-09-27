#!/usr/bin/env bash
# Shared helpers for operator (bin/) and host (host/) scripts.
# Provides: logging, usage printing, --debug support bundle, and safe env loading.
#
# Convention (see README): every script accepts -h/--help and --debug.
# --debug writes /var/tmp/chr-diag/<tool>-<UTC>/ plus a .tgz and prints the
# two DEBUG BUNDLE lines last.

set -o pipefail

BENCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "${BENCH_LIB_DIR}/.." && pwd)"
TOOL_NAME="$(basename "${0:-bench}")"
DEBUG_MODE=0
DEBUG_DIR=""
UTC_NOW() { date -u +%Y%m%dT%H%M%SZ; }

# ---- logging ---------------------------------------------------------------
# All messages go to stderr so stdout stays clean for machine-readable output.
log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
warn() { printf '[%s] WARNING: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; debug_finalize; exit 1; }

# Abort early with a clear message if a dependency is missing.
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# Load KEY=VALUE files without executing arbitrary content.
load_env_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  while IFS='=' read -r k v; do
    [[ -z "$k" || "$k" =~ ^[[:space:]]*# ]] && continue
    k="${k//[[:space:]]/}"
    export "$k=$v"
  done < "$f"
}

# Environment dump for bundles with anything secret-looking masked.
redact_env() {
  env | sort | sed -E 's/^([^=]*(TOKEN|SECRET|PASSWORD|KEY|PASS)[^=]*)=.*/\1=[REDACTED]/I'
}

# ---- debug bundle -----------------------------------------------------------
# Create the bundle directory, record host facts, and tee stdout/stderr into it.
debug_init() {
  DEBUG_MODE=1
  DEBUG_DIR="/var/tmp/chr-diag/${TOOL_NAME%.sh}-$(UTC_NOW)"
  mkdir -p "$DEBUG_DIR"
  {
    echo "tool: $TOOL_NAME"
    echo "invocation: $0 $*"
    echo "utc: $(date -u +%FT%TZ)"
    echo "host: $(uname -a)"
    echo "user: $(id -un)"
    echo "pwd: $(pwd)"
    echo "bash: $BASH_VERSION"
    for c in terraform docker nvidia-smi jq rsync python3 guidellm curl; do
      if command -v "$c" >/dev/null 2>&1; then
        printf '%s: ' "$c"; ("$c" --version 2>/dev/null || "$c" version 2>/dev/null) | head -1
      fi
    done
  } > "$DEBUG_DIR/environment.txt" 2>&1
  redact_env > "$DEBUG_DIR/env-redacted.txt"
  : > "$DEBUG_DIR/manifest.txt"
  exec > >(tee -a "$DEBUG_DIR/stdout.log") 2> >(tee -a "$DEBUG_DIR/stderr.log" >&2)
  log "debug bundle: $DEBUG_DIR"
}

# Copy a file or directory into the bundle with a one-line description.
debug_add() {
  # debug_add <path> <description>
  [ "$DEBUG_MODE" = 1 ] || return 0
  local src="$1" desc="${2:-}"
  [ -e "$src" ] || return 0
  cp -R "$src" "$DEBUG_DIR/" 2>/dev/null || true
  printf '%s\t%s\n' "$(basename "$src")" "$desc" >> "$DEBUG_DIR/manifest.txt"
}

# Append a free-text note to the bundle.
debug_note() {
  [ "$DEBUG_MODE" = 1 ] || return 0
  printf '%s\n' "$*" >> "$DEBUG_DIR/notes.txt"
}

# Write the manifest, tar the bundle, print the two DEBUG BUNDLE lines last.
# Safe to call more than once; the second call is a no-op.
debug_finalize() {
  [ "$DEBUG_MODE" = 1 ] || return 0
  {
    printf 'environment.txt\thost, versions, invocation\n'
    printf 'env-redacted.txt\tenvironment variables with secrets redacted\n'
    printf 'stdout.log\tcaptured stdout\n'
    printf 'stderr.log\tcaptured stderr\n'
  } >> "$DEBUG_DIR/manifest.txt"
  local tgz="${DEBUG_DIR}.tgz"
  tar -czf "$tgz" -C "$(dirname "$DEBUG_DIR")" "$(basename "$DEBUG_DIR")" 2>/dev/null || true
  echo "DEBUG BUNDLE: $DEBUG_DIR"
  echo "DEBUG BUNDLE TAR: $tgz"
  DEBUG_MODE=0
}

# ---- argument handling ----------------------------------------------------
# Parse the two universal flags out of "$@"; leaves the rest in ARGS array.
parse_common_flags() {
  ARGS=()
  local a
  for a in "$@"; do
    case "$a" in
      -h|--help) usage; exit 0 ;;
      --debug) WANT_DEBUG=1 ;;
      *) ARGS+=("$a") ;;
    esac
  done
  if [ "${WANT_DEBUG:-0}" = 1 ]; then debug_init "$@"; fi
}

# Terraform output helper (operator side).
tf_output() {
  terraform -chdir="${BENCH_ROOT}/terraform" output -raw "$1" 2>/dev/null
}
