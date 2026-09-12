#!/usr/bin/env bash
# cleanup.sh - destroys the lab: containers first, then the two lab
# networks (networks can't be deleted while a container NIC still uses them).
set -uo pipefail
cd "$(dirname "$0")" || exit 1
source lib/common.sh
source lib/topology.sh

require_lxd

section "Deleting containers"
for node in "$SERVER" "$ROUTER" "$CLIENT"; do
  if lxc info "$node" >/dev/null 2>&1; then
    lxc delete --force "$node"
    info "deleted $node"
  else
    info "$node does not exist, skipping"
  fi
done

section "Deleting lab networks"
for net in "$NET_FRONT" "$NET_BACK"; do
  if lxc network show "$net" >/dev/null 2>&1; then
    lxc network delete "$net"
    info "deleted network $net"
  else
    info "network $net does not exist, skipping"
  fi
done

echo
echo "Lab fully removed."
