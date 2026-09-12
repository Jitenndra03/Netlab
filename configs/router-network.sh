#!/usr/bin/env bash
# router-network.sh - runs INSIDE the `router` container.
# eth1 faces the front (client) segment, eth2 faces the back (server)
# segment. The router forwards + firewalls between them with nftables -
# no NAT is needed since both segments are private and the router owns
# routes to both.
set -euo pipefail

ROUTER_FRONT_CIDR="$1"; ROUTER_BACK_CIDR="$2"; MTU="$3"

echo "[router] addressing eth1 (front) and eth2 (back)"
ip addr flush dev eth1 2>/dev/null || true
ip addr flush dev eth2 2>/dev/null || true
ip addr add "$ROUTER_FRONT_CIDR" dev eth1
ip addr add "$ROUTER_BACK_CIDR" dev eth2
ip link set eth1 mtu "$MTU"
ip link set eth2 mtu "$MTU"
ip link set eth1 up
ip link set eth2 up

echo "[router] enabling IPv4 forwarding (this container's whole job)"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
# Persist across container restarts.
mkdir -p /etc/sysctl.d
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-lab-router.conf

echo "[router] installing nftables"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nftables netcat-openbsd >/dev/null

echo "[router] loading baseline firewall ruleset"
nft flush ruleset
nft -f /root/nftables-router.nft

echo "[router] baseline network config applied."
