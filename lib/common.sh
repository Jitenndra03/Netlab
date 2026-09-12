#!/usr/bin/env bash
# common.sh - shared helpers sourced by every script in this lab.
# Deliberately NOT using `set -e` here: diagnose.sh in particular needs to
# keep going after a failed check instead of aborting the whole report.

C_RED='\033[0;31m'; C_YEL='\033[0;33m'; C_GRN='\033[0;32m'; C_BLU='\033[0;36m'; C_BOLD='\033[1m'; C_RST='\033[0m'

PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0

pass() { echo -e "${C_GRN}[PASS]${C_RST} $1"; PASS_COUNT=$((PASS_COUNT+1)); }
warn() { echo -e "${C_YEL}[WARN]${C_RST} $1"; WARN_COUNT=$((WARN_COUNT+1)); }
fail() { echo -e "${C_RED}[FAIL]${C_RST} $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
info() { echo -e "${C_BLU}[INFO]${C_RST} $1"; }
section() { echo -e "\n${C_BOLD}== $1 ==${C_RST}"; }

# Run a command inside a container, showing stderr (for debugging setup).
cexec() { lxc exec "$1" -- bash -c "$2"; }
# Same, but swallow stderr and just return stdout - handy inside `if`/`$( )`.
cexec_q() { lxc exec "$1" -- bash -c "$2" 2>/dev/null; }
# Run a command inside a container and just return its exit code (0/1).
cexec_ok() { lxc exec "$1" -- bash -c "$2" >/dev/null 2>&1; }

require_lxd() {
  command -v lxc >/dev/null 2>&1 || { echo "ERROR: lxc (LXD client) not found. Install/init LXD first (snap install lxd; lxd init)." >&2; exit 1; }
}

require_running() {
  local node="$1"
  local state
  state=$(lxc list "$node" --format csv -c s 2>/dev/null)
  if [[ "$state" != "RUNNING" ]]; then
    echo "ERROR: container '$node' is not running. Run ./setup.sh first." >&2
    exit 1
  fi
}

print_summary() {
  echo
  echo -e "${C_BOLD}Summary: ${C_GRN}${PASS_COUNT} PASS${C_RST}, ${C_YEL}${WARN_COUNT} WARN${C_RST}, ${C_RED}${FAIL_COUNT} FAIL${C_RST}"
  if [[ $FAIL_COUNT -gt 0 ]]; then
    echo -e "${C_RED}Lab is UNHEALTHY - see [FAIL] lines above for suggested fixes.${C_RST}"
    return 1
  elif [[ $WARN_COUNT -gt 0 ]]; then
    echo -e "${C_YEL}Lab is mostly healthy but has warnings - review above.${C_RST}"
    return 0
  else
    echo -e "${C_GRN}Lab is fully healthy.${C_RST}"
    return 0
  fi
}
