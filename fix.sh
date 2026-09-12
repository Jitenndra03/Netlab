#!/usr/bin/env bash
# fix.sh <scenario> - applies the exact, minimal fix for a break.sh scenario.
# Scenarios: mtu | bond | firewall | bridge | nfs | all
set -uo pipefail
cd "$(dirname "$0")" || exit 1
source lib/common.sh
source lib/topology.sh

usage() {
  echo "Usage: $0 <mtu|bond|firewall|bridge|nfs|all>"
  exit 1
}

[[ $# -eq 1 ]] || usage
require_lxd

fix_mtu() {
  section "FIX: mtu"
  require_running "$CLIENT"
  cexec "$CLIENT" "ip link set eth1 mtu $EXPECTED_MTU"
  info "client eth1 MTU restored to $EXPECTED_MTU."
}

fix_bond() {
  section "FIX: bond"
  require_running "$SERVER"
  cexec "$SERVER" "
    ip link set eth1 down; ip link set eth1 master bond0; ip link set eth1 up
    ip link set eth2 down; ip link set eth2 master bond0; ip link set eth2 up
    echo eth1 > /sys/class/net/bond0/bonding/primary
  "
  info "eth1 (primary) and eth2 (backup) re-enslaved to bond0."
}

fix_firewall() {
  section "FIX: firewall"
  require_running "$ROUTER"
  cexec "$ROUTER" "nft flush ruleset; nft -f /root/nftables-router.nft"
  info "router firewall reloaded from the known-good baseline ruleset."
}

fix_bridge() {
  section "FIX: bridge"
  require_running "$SERVER"
  cexec "$SERVER" "ip link set bond0 master br0"
  info "bond0 re-attached to br0 on the server."
}

fix_nfs() {
  section "FIX: nfs"
  require_running "$SERVER"
  cexec "$SERVER" "
    sed -i 's/^LAB-DISABLED //' /etc/exports
    grep -qxF '$NFS_EXPORT_LINE' /etc/exports || echo '$NFS_EXPORT_LINE' >> /etc/exports
    exportfs -ra
    systemctl start nfs-kernel-server
  "
  info "NFS export restored and nfs-kernel-server started."
  require_running "$CLIENT"
  cexec "$CLIENT" "umount $NFS_MOUNT_PATH 2>/dev/null; mount $NFS_MOUNT_PATH" || \
    warn "client remount failed - if this persists, wait a few seconds for nfsd to fully register with rpcbind and retry."
}

case "$1" in
  mtu) fix_mtu ;;
  bond) fix_bond ;;
  firewall) fix_firewall ;;
  bridge) fix_bridge ;;
  nfs) fix_nfs ;;
  all) fix_mtu; fix_bond; fix_firewall; fix_bridge; fix_nfs ;;
  *) usage ;;
esac

echo
echo "Fix applied. Run ./diagnose.sh to confirm the lab is healthy again."
