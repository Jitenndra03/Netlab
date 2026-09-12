#!/usr/bin/env bash
# client-network.sh - runs INSIDE the `client` container.
set -euo pipefail

CLIENT_CIDR="$1"; BACK_NET="$2"; ROUTER_FRONT_IP="$3"; MTU="$4"
NFS_MOUNT_PATH="$5"; SERVER_IP="$6"; NFS_EXPORT_PATH="$7"

echo "[client] addressing eth1"
ip addr flush dev eth1 2>/dev/null || true
ip addr add "$CLIENT_CIDR" dev eth1
ip link set eth1 mtu "$MTU"
ip link set eth1 up

echo "[client] route to the back (server) network via the router"
ip route replace "$BACK_NET" via "$ROUTER_FRONT_IP"

echo "[client] installing NFS client + diagnostic tools"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nfs-common tcpdump iputils-ping dnsutils netcat-openbsd nmap iproute2 >/dev/null

mkdir -p "$NFS_MOUNT_PATH"
umount "$NFS_MOUNT_PATH" 2>/dev/null || true

grep -q "$NFS_MOUNT_PATH" /etc/fstab || \
  echo "${SERVER_IP}:${NFS_EXPORT_PATH} ${NFS_MOUNT_PATH} nfs defaults,_netdev,soft,timeo=30,retrans=2 0 0" >> /etc/fstab

echo "[client] mounting NFS share"
mount "$NFS_MOUNT_PATH" || echo "[client] WARNING: mount failed at setup time (server may still be starting) - retry with fix.sh nfs"

echo "[client] baseline network config applied."
