#!/usr/bin/env bash
# setup.sh - builds the mini network diagnostics lab.
#
# Topology:
#
#     [client]  eth0(mgmt/DHCP)         [router]  eth0(mgmt/DHCP)        [server]  eth0(mgmt/DHCP)
#        |                                  |                                |
#        eth1 --- lxdbr-front (10.10.10.0/24) --- eth1                       |
#                                            |                                |
#                                            eth2 --- lxdbr-back (10.10.20.0/24) --- eth1+eth2
#                                                                                        \  /
#                                                                                       bond0 (active-backup)
#                                                                                          |
#                                                                                         br0  10.10.20.10/24
#
# eth0 on every node is a normal DHCP NIC on LXD's default network, used
# ONLY so `apt-get install` works during setup - the lab itself never uses
# it. All lab traffic rides eth1/eth2 on the two purpose-built,
# unmanaged (no DHCP/NAT) LXD bridges defined in lib/topology.sh.
# Enable strict error handling:
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error.
# -o pipefail: The return value of a pipeline is the status of the last command to exit with a non-zero status.
set -euo pipefail

# Change to the directory where this script is located, ensuring relative paths work correctly.
cd "$(dirname "$0")" || exit 1

# Include common functions (like 'info', 'section', 'cexec', 'cexec_ok') and topology definitions.
source lib/common.sh
source lib/topology.sh

# Ensure that the LXD (Linux Containers) daemon is installed and available before proceeding.
require_lxd

section "1. Creating lab-only L2 networks (no DHCP/NAT - we address these by hand)"
# Loop through the front and back network names defined in topology.sh
for net in "$NET_FRONT" "$NET_BACK"; do
  # Check if the network already exists to make the script idempotent (safe to run multiple times)
  if lxc network show "$net" >/dev/null 2>&1; then
    info "network $net already exists, skipping"
  else
    # Create the network as a pure Layer 2 bridge without IP addressing or DHCP/NAT
    lxc network create "$net" ipv4.address=none ipv6.address=none
    info "created network $net"
  fi
done

section "2. Launching containers"
# We use Ubuntu 22.04 as the base image for all containers in this lab
IMAGE=ubuntu:22.04
# Loop through the three container roles: server, router, and client
for node in "$SERVER" "$ROUTER" "$CLIENT"; do
  # Check if the container already exists
  if lxc info "$node" >/dev/null 2>&1; then
    info "container $node already exists, skipping launch"
  else
    # Launch a new container with the specified image and name
    lxc launch "$IMAGE" "$node"
    info "launched $node"
  fi
done

section "3. Attaching lab NICs"
# Helper function to attach a specific network interface to a container
attach_nic() { # <container> <ifname> <network>
  local c="$1" ifname="$2" net="$3"
  # Check if the interface is already attached to avoid duplicates
  if lxc config device show "$c" 2>/dev/null | grep -q "^${ifname}:"; then
    info "$c/$ifname already attached"
  else
    # Add a new network device (NIC) connected to the specified LXD network
    lxc config device add "$c" "$ifname" nic network="$net" name="$ifname"
    info "attached $c/$ifname -> $net"
  fi
}
# Attach the required NICs according to the topology:
# Server gets two interfaces on the back network (for bonding)
attach_nic "$SERVER" eth1 "$NET_BACK"
attach_nic "$SERVER" eth2 "$NET_BACK"
# Router connects the front and back networks
attach_nic "$ROUTER" eth1 "$NET_FRONT"
attach_nic "$ROUTER" eth2 "$NET_BACK"
# Client only connects to the front network
attach_nic "$CLIENT" eth1 "$NET_FRONT"

section "4. Waiting for containers to be ready (mgmt DHCP + systemd)"
# Wait for the containers to fully boot and acquire a management IP on eth0
for node in "$SERVER" "$ROUTER" "$CLIENT"; do
  for i in $(seq 1 30); do
    # Check if systemd is fully running AND if eth0 has an IPv4 address
    if cexec_ok "$node" "systemctl is-system-running --wait >/dev/null 2>&1 || true; ip addr show eth0 | grep -q 'inet '"; then
      break
    fi
    sleep 2
  done
  info "$node ready"
done
# Give apt and NetworkManager a few extra seconds to settle inside the fresh containers
sleep 5

section "5. Pushing config files into containers"
# Copy configuration scripts and firewall rules from the host into each container's /root directory
lxc file push configs/nftables-router.nft "$ROUTER/root/nftables-router.nft"
lxc file push configs/server-network.sh "$SERVER/root/server-network.sh"
lxc file push configs/router-network.sh "$ROUTER/root/router-network.sh"
lxc file push configs/client-network.sh "$CLIENT/root/client-network.sh"

# Make the pushed shell scripts executable inside the containers
for f in server-network.sh router-network.sh client-network.sh; do
  node="${f%%-*}" # Extract the container name from the script filename (e.g., 'server' from 'server-network.sh')
  cexec "$node" "chmod +x /root/${f}"
done

section "6. Configuring router (routing + firewall)"
# Execute the router setup script inside the router container, passing necessary topology variables
cexec "$ROUTER" "/root/router-network.sh '$ROUTER_FRONT_CIDR' '$ROUTER_BACK_CIDR' '$EXPECTED_MTU'"

section "7. Configuring server (bond0 -> br0 + NFS export)"
# Execute the server setup script inside the server container to configure bonding, bridging, and NFS
cexec "$SERVER" "/root/server-network.sh '$NET_BACK' '$SERVER_CIDR' '$FRONT_NET' '$ROUTER_BACK_IP' '$EXPECTED_MTU' '$NFS_EXPORT_PATH' '$NFS_EXPORT_LINE'"

section "8. Configuring client (addressing + NFS mount)"
# Execute the client setup script inside the client container to configure routing and mount the NFS share
cexec "$CLIENT" "/root/client-network.sh '$CLIENT_CIDR' '$BACK_NET' '$ROUTER_FRONT_IP' '$EXPECTED_MTU' '$NFS_MOUNT_PATH' '$SERVER_IP' '$NFS_EXPORT_PATH'"

section "Done"
# Print post-setup instructions
echo "Lab is up. Try:"
echo "  ./diagnose.sh                # full health check"
echo "  ./break.sh mtu                # inject a fault"
echo "  ./diagnose.sh                # see it get caught"
echo "  ./fix.sh mtu                  # restore it"
echo "  ./cleanup.sh                  # tear everything down"
