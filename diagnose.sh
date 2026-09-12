#!/usr/bin/env bash
# diagnose.sh - runs a full health check across client/router/server and
# prints [PASS]/[WARN]/[FAIL] lines with a short explanation and, on
# failure, the exact `./fix.sh <scenario>` to run.
#
# Deliberately does NOT use `set -e`: one failed check must not stop the
# rest of the report from running.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
source lib/common.sh
source lib/topology.sh

require_lxd
for n in "$SERVER" "$ROUTER" "$CLIENT"; do require_running "$n"; done

# -----------------------------------------------------------------------
section "1. Interface / link state"
# -----------------------------------------------------------------------
check_link() { # <node> <iface>
  local node="$1" ifc="$2"
  local state
  state=$(cexec_q "$node" "cat /sys/class/net/$ifc/operstate" 2>/dev/null)
  if [[ -z "$state" ]]; then
    fail "$node/$ifc: interface does not exist"
  elif [[ "$state" == "up" || "$state" == "unknown" ]]; then
    pass "$node/$ifc: link is up (operstate=$state)"
  else
    fail "$node/$ifc: link is DOWN (operstate=$state). Fix: check cabling/'ip link set $ifc up', or if this is bond0/br0, its members may be missing (./fix.sh bond|bridge)."
  fi
}
for i in "${CLIENT_LAB_IFACES[@]}"; do check_link "$CLIENT" "$i"; done
for i in "${ROUTER_LAB_IFACES[@]}"; do check_link "$ROUTER" "$i"; done
for i in "${SERVER_LAB_IFACES[@]}"; do check_link "$SERVER" "$i"; done

# -----------------------------------------------------------------------
section "2. IP addressing / routes"
# -----------------------------------------------------------------------
check_ip() { # <node> <iface> <expected_cidr>
  local node="$1" ifc="$2" expected="$3"
  local got
  got=$(cexec_q "$node" "ip -4 -o addr show dev $ifc | awk '{print \$4}'")
  if [[ "$got" == "$expected" ]]; then
    pass "$node/$ifc: IP is $got as expected"
  else
    fail "$node/$ifc: expected $expected, got '${got:-<none>}'. Fix: re-run ./setup.sh's config step or 'ip addr add $expected dev $ifc' on $node."
  fi
}
check_ip "$CLIENT" eth1 "$CLIENT_CIDR"
check_ip "$ROUTER" eth1 "$ROUTER_FRONT_CIDR"
check_ip "$ROUTER" eth2 "$ROUTER_BACK_CIDR"
check_ip "$SERVER" br0 "$SERVER_CIDR"

check_route() { # <node> <net> <via>
  local node="$1" net="$2" via="$3"
  if cexec_ok "$node" "ip route get ${net%%/*} | grep -q 'via $via'"; then
    pass "$node: has a route to $net via $via"
  else
    fail "$node: missing/incorrect route to $net (expected via $via). Fix: 'ip route replace $net via $via' on $node."
  fi
}
check_route "$CLIENT" "$BACK_NET" "$ROUTER_FRONT_IP"
check_route "$SERVER" "$FRONT_NET" "$ROUTER_BACK_IP"

# -----------------------------------------------------------------------
section "3. MTU consistency along the client <-> server path"
# -----------------------------------------------------------------------
mtu_bad=0
for key in "$CLIENT/eth1" "$ROUTER/eth1" "$ROUTER/eth2" "$SERVER/bond0" "$SERVER/br0"; do
  node="${key%%/*}"; ifc="${key##*/}"
  mtu=$(cexec_q "$node" "cat /sys/class/net/$ifc/mtu")
  if [[ "$mtu" == "$EXPECTED_MTU" ]]; then
    pass "$key: MTU=$mtu"
  else
    fail "$key: MTU=$mtu (expected $EXPECTED_MTU) - mismatched MTU along a path causes large packets to silently drop or fragment. Fix: ./fix.sh mtu"
    mtu_bad=1
  fi
done
if [[ $mtu_bad -eq 0 ]]; then
  # Functional confirmation: a large ping with the Don't-Fragment bit set
  # will fail if ANY hop on the path has a smaller MTU than assumed.
  if cexec_ok "$CLIENT" "ping -M do -s 1472 -c 2 -W 2 $SERVER_IP"; then
    pass "client -> server: 1500-byte (DF) ping succeeds end-to-end - no hidden path-MTU issue"
  else
    warn "client -> server: 1500-byte (DF) ping failed even though interface MTUs look consistent - check for a mid-path device with a smaller MTU, or that ICMP 'frag needed' isn't being filtered."
  fi
fi

# -----------------------------------------------------------------------
section "4. Bond state (server bond0)"
# -----------------------------------------------------------------------
bond_info=$(cexec_q "$SERVER" "cat /proc/net/bonding/bond0" 2>/dev/null)
if [[ -z "$bond_info" ]]; then
  fail "server: bond0 does not exist. Fix: ./fix.sh bond (or re-run setup.sh)."
else
  slave_count=$(echo "$bond_info" | grep -c "^Slave Interface:")
  mii_up=$(echo "$bond_info" | grep -c "MII Status: up")
  active_slave=$(echo "$bond_info" | grep "Currently Active Slave:" | awk '{print $NF}')
  mode=$(echo "$bond_info" | grep "Bonding Mode:" | cut -d: -f2- | sed 's/^ *//')

  if [[ "$mode" == *"active-backup"* ]]; then
    pass "server/bond0: mode is active-backup (safe lab mode, needs no switch config)"
  else
    warn "server/bond0: mode is '$mode', expected active-backup"
  fi

  if [[ "$slave_count" -eq 2 ]]; then
    pass "server/bond0: has 2 slave interfaces enslaved"
  else
    fail "server/bond0: only $slave_count slave(s) enslaved (expected 2) - bond is degraded or fully inactive. Fix: ./fix.sh bond"
  fi

  if [[ -n "$active_slave" && "$active_slave" != "None" ]]; then
    pass "server/bond0: active slave is $active_slave ($mii_up/$slave_count links reporting MII up)"
  else
    fail "server/bond0: no active slave - bond0 is up but cannot forward any traffic. Fix: ./fix.sh bond"
  fi
fi

# -----------------------------------------------------------------------
section "5. Bridge membership (server br0)"
# -----------------------------------------------------------------------
members=$(cexec_q "$SERVER" "ip -o link show master br0 | awk -F': ' '{print \$2}'")
if [[ -n "$members" ]]; then
  pass "server/br0: has member(s): $members"
else
  fail "server/br0: has NO members - bridge exists but is empty, so nothing reaches the IP on br0. Fix: ./fix.sh bridge"
fi

# -----------------------------------------------------------------------
section "6. Reachability (ping)"
# -----------------------------------------------------------------------
check_ping() { # <src_node> <dst_ip> <label>
  local src="$1" dst="$2" label="$3"
  if cexec_ok "$src" "ping -c 2 -W 2 $dst"; then
    pass "$label: reachable ($src -> $dst)"
  else
    fail "$label: NOT reachable ($src -> $dst). Check link state, bond/bridge, and routes above."
  fi
}
check_ping "$CLIENT" "$ROUTER_FRONT_IP" "client -> router (front hop)"
check_ping "$ROUTER" "$SERVER_IP" "router -> server (back hop)"
check_ping "$CLIENT" "$SERVER_IP" "client -> server (full path)"

# -----------------------------------------------------------------------
section "7. Listening ports (server: NFS services)"
# -----------------------------------------------------------------------
for port in "${NFS_TCP_PORTS[@]}"; do
  if cexec_ok "$SERVER" "ss -ltn | awk '{print \$4}' | grep -qE \":$port\$\""; then
    pass "server: something is listening on tcp/$port"
  else
    fail "server: nothing listening on tcp/$port. Fix: ./fix.sh nfs (nfs-kernel-server may be stopped)."
  fi
done

# -----------------------------------------------------------------------
section "8. Firewall (router forward chain / functional NFS port test)"
# -----------------------------------------------------------------------
extra_drops=$(cexec_q "$ROUTER" "nft list chain inet filter forward" | grep -i "drop" | grep -v "policy drop")
if [[ -n "$extra_drops" ]]; then
  warn "router: found extra DROP rule(s) in the forward chain beyond the baseline policy:"
  echo "$extra_drops" | sed 's/^/         /'
else
  pass "router: forward chain matches the expected baseline (no stray DROP rules)"
fi

if cexec_ok "$CLIENT" "nc -z -w2 $SERVER_IP 2049"; then
  pass "client -> server: tcp/2049 (nfsd) is reachable through the firewall"
else
  fail "client -> server: tcp/2049 (nfsd) is BLOCKED. Fix: ./fix.sh firewall"
fi

# -----------------------------------------------------------------------
section "9. NFS export / mount"
# -----------------------------------------------------------------------
if cexec_q "$SERVER" "exportfs -v" | grep -q "$NFS_EXPORT_PATH"; then
  pass "server: $NFS_EXPORT_PATH is actively exported"
else
  fail "server: $NFS_EXPORT_PATH is NOT exported (check /etc/exports + 'exportfs -ra'). Fix: ./fix.sh nfs"
fi

if cexec_q "$CLIENT" "showmount -e $SERVER_IP" 2>/dev/null | grep -q "$NFS_EXPORT_PATH"; then
  pass "client: showmount confirms server is advertising the export"
else
  fail "client: showmount cannot see the export on $SERVER_IP (network path or nfsd issue)"
fi

if cexec_q "$CLIENT" "mount | grep -q '$NFS_MOUNT_PATH type nfs'" ; then
  if cexec_ok "$CLIENT" "test -r $NFS_MOUNT_PATH/welcome.txt"; then
    pass "client: $NFS_MOUNT_PATH is mounted and readable"
  else
    warn "client: $NFS_MOUNT_PATH is mounted but content is not readable (stale mount?). Try: umount + ./fix.sh nfs"
  fi
else
  fail "client: $NFS_MOUNT_PATH is NOT mounted. Fix: ./fix.sh nfs (also re-checks export + service)."
fi

# -----------------------------------------------------------------------
section "10. Relevant logs (last few lines)"
# -----------------------------------------------------------------------
info "server bonding messages (dmesg):"
cexec_q "$SERVER" "dmesg 2>/dev/null | grep -i bond | tail -5" | sed 's/^/         /' || true
info "server nfs-kernel-server status:"
cexec_q "$SERVER" "systemctl is-active nfs-kernel-server" | sed 's/^/         nfs-kernel-server: /'
info "router recent kernel/firewall messages:"
cexec_q "$ROUTER" "dmesg 2>/dev/null | tail -5" | sed 's/^/         /' || true

print_summary
