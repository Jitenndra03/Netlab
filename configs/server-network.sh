#!/usr/bin/env bash
# server-network.sh - runs INSIDE the `server` container.
# Builds: eth1 + eth2 -> bond0 (active-backup) -> br0 (IP lives here).
# This bond+bridge pattern is the classic "hypervisor host networking"
# layout: bond for NIC redundancy, bridge on top so the IP (and, in a real
# deployment, VM taps) can attach above the bond.
set -euo pipefail

BACK_NET="$1"; SERVER_CIDR="$2"; FRONT_NET="$3"; ROUTER_BACK_IP="$4"; MTU="$5"
NFS_EXPORT_PATH="$6"; NFS_EXPORT_LINE="$7"

echo "[server] resetting any previous lab config (idempotent)"
ip link set br0 down 2>/dev/null || true
ip link del br0 2>/dev/null || true
ip link set bond0 down 2>/dev/null || true
ip link del bond0 2>/dev/null || true

echo "[server] bringing slave NICs down before enslaving (required by bonding)"
ip link set eth1 down
ip link set eth2 down

echo "[server] creating bond0 in active-backup mode"
# active-backup = only ONE slave carries traffic at a time; the other is a
# hot standby. It is the "safe" bond mode for a lab because it needs no
# switch-side configuration (unlike 802.3ad/LACP, which requires the
# upstream switch to be in on the same port-channel).
ip link add bond0 type bond mode active-backup miimon 100
# miimon=100 -> check link carrier every 100ms so failover is fast/reliable.

echo "[server] enslaving eth1 (primary) and eth2 (backup) to bond0"
ip link set eth1 master bond0
ip link set eth2 master bond0
# 'primary' tells the bond driver to always prefer eth1 when it is
# available, instead of "sticking" to whichever NIC happened to come up
# last electric - a common gotcha in real active-backup deployments.
echo eth1 > /sys/class/net/bond0/bonding/primary

ip link set eth1 up
ip link set eth2 up
ip link set bond0 up

echo "[server] creating br0 and enslaving bond0 to it"
ip link add br0 type bridge
ip link set bond0 master br0
ip link set br0 up

echo "[server] setting MTU=$MTU consistently end-to-end on the whole stack"
ip link set eth1 mtu "$MTU"
ip link set eth2 mtu "$MTU"
ip link set bond0 mtu "$MTU"
ip link set br0 mtu "$MTU"

echo "[server] assigning IP to br0 (never to bond0 or the raw slaves)"
ip addr flush dev br0 2>/dev/null || true
ip addr add "$SERVER_CIDR" dev br0

echo "[server] route to the front network via the router"
ip route replace "$FRONT_NET" via "$ROUTER_BACK_IP"

echo "[server] installing NFS server + exporting $NFS_EXPORT_PATH"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nfs-kernel-server >/dev/null

mkdir -p "$NFS_EXPORT_PATH"
chmod 777 "$NFS_EXPORT_PATH"
echo "hello from the NFS server - $(date)" > "$NFS_EXPORT_PATH/welcome.txt"

grep -qxF "$NFS_EXPORT_LINE" /etc/exports || echo "$NFS_EXPORT_LINE" >> /etc/exports
exportfs -ra
systemctl enable --now nfs-kernel-server >/dev/null 2>&1
systemctl restart nfs-kernel-server

echo "[server] baseline network config applied."
