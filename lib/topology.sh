#!/usr/bin/env bash
# topology.sh
#
# Single source of truth for the lab's names, addressing plan and "known
# good" values. Every other script (setup/break/diagnose/fix/cleanup)
# sources this file so they can never disagree with each other about what
# "correct" looks like. This is the same idea as a CMDB / IPAM sheet in a
# real network team: one place, one truth.

# ---- Node names (LXD container names) -------------------------------------
SERVER=server   # NFS server, bond0 -> br0
ROUTER=router   # routes + firewalls between the two lab segments
CLIENT=client   # NFS client, runs diagnostics

# ---- LXD data-plane networks (unmanaged: no DHCP/NAT, we address by hand) -
NET_FRONT=lxdbr-front   # client <-> router     10.10.10.0/24
NET_BACK=lxdbr-back     # router <-> server     10.10.20.0/24 (server side is bonded)

# ---- Addressing plan --------------------------------------------------------
FRONT_NET=10.10.10.0/24
BACK_NET=10.10.20.0/24

CLIENT_IP=10.10.10.10
CLIENT_CIDR=${CLIENT_IP}/24
ROUTER_FRONT_IP=10.10.10.1
ROUTER_FRONT_CIDR=${ROUTER_FRONT_IP}/24
ROUTER_BACK_IP=10.10.20.1
ROUTER_BACK_CIDR=${ROUTER_BACK_IP}/24
SERVER_IP=10.10.20.10
SERVER_CIDR=${SERVER_IP}/24

# ---- "Known good" values diagnose.sh compares reality against -------------
EXPECTED_MTU=1500
NFS_TCP_PORTS=(111 2049 20048)   # rpcbind, nfsd, mountd
NFS_UDP_PORTS=(111 2049 20048)
NFS_EXPORT_PATH=/srv/nfsshare
NFS_MOUNT_PATH=/mnt/nfsshare
NFS_EXPORT_CIDR=${FRONT_NET}          # who the server is allowed to export to
NFS_EXPORT_LINE="${NFS_EXPORT_PATH} ${NFS_EXPORT_CIDR}(rw,sync,no_subtree_check,no_root_squash)"

# Interfaces that matter, per node (used by loops in diagnose.sh)
SERVER_LAB_IFACES=(eth1 eth2 bond0 br0)
ROUTER_LAB_IFACES=(eth1 eth2)
CLIENT_LAB_IFACES=(eth1)
