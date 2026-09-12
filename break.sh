#!/usr/bin/env bash
# break.sh <scenario> - deliberately injects a common real-world fault.
# Scenarios: mtu | bond | firewall | bridge | nfs | all
set -uo pipefail
cd "$(dirname "$0")" || exit 1
source lib/common.sh
source lib/topology.sh

usage() {
  cat <<EOF
Usage: $0 <scenario>

Scenarios:
  mtu       Mismatch the client's MTU (1400) vs the rest of the path (1500)
  bond      Rip both slaves out of bond0 on the server (bond goes inactive)
  firewall  Block NFS (tcp/2049) on the router's forward chain
  bridge    Detach bond0 from br0 on the server (bridge has no members)
  nfs       Unexport the share and stop nfsd on the server
  all       Inject every scenario above, one after another
EOF
  exit 1
}

[[ $# -eq 1 ]] || usage
require_lxd

break_mtu() {
  section "BREAK: mtu"
  require_running "$CLIENT"
  cexec "$CLIENT" "ip link set eth1 mtu 1400"
  info "client eth1 MTU set to 1400 (rest of path is still $EXPECTED_MTU) - large packets will now silently blackhole or fragment unexpectedly."
}

break_bond() {
  section "BREAK: bond"
  require_running "$SERVER"
  cexec "$SERVER" "ip link set eth1 nomaster || true; ip link set eth2 nomaster || true"
  info "both slaves removed from bond0 on server - bond0 is up but carries no traffic (classic 'inactive bond' fault)."
}

break_firewall() {
  section "BREAK: firewall"
  require_running "$ROUTER"
  cexec "$ROUTER" "nft insert rule inet filter forward ip saddr $FRONT_NET ip daddr $BACK_NET tcp dport 2049 drop"
  info "inserted a DROP rule for tcp/2049 (nfsd) on the router - NFS traffic from client->server is now blocked, everything else still works."
}

break_bridge() {
  section "BREAK: bridge"
  require_running "$SERVER"
  cexec "$SERVER" "ip link set bond0 nomaster || true"
  info "bond0 detached from br0 on server - br0 is up but empty, server becomes completely unreachable at $SERVER_IP."
}

break_nfs() {
  section "BREAK: nfs"
  require_running "$SERVER"
  cexec "$SERVER" "sed -i '\\#^${NFS_EXPORT_PATH}#s#^#LAB-DISABLED #' /etc/exports; exportfs -ra; systemctl stop nfs-kernel-server"
  info "NFS export commented out and nfs-kernel-server stopped on the server - network path is fine, but the NFS service itself is down."
}

case "$1" in
  mtu) break_mtu ;;
  bond) break_bond ;;
  firewall) break_firewall ;;
  bridge) break_bridge ;;
  nfs) break_nfs ;;
  all) break_mtu; break_bond; break_firewall; break_bridge; break_nfs ;;
  *) usage ;;
esac

echo
echo "Fault injected. Run ./diagnose.sh to see it detected, and ./fix.sh $1 to restore."
