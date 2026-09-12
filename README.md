# Mini Network Diagnostics & Config Simulator

A small, reproducible Linux networking lab (3 LXD containers) that stands up
bonding, bridging, routing/firewalling and NFS, then lets you deliberately
break each layer and diagnose/fix it with scripts — like a self-contained
internal KB article you can actually run.

```
setup.sh      builds the lab
break.sh      injects a fault      (mtu | bond | firewall | bridge | nfs | all)
diagnose.sh   detects/explains it  (no arguments - always runs the full suite)
fix.sh        restores it          (mtu | bond | firewall | bridge | nfs | all)
cleanup.sh    tears the lab down
```

---

## 1. Topology

```
          10.10.10.0/24 "front"          10.10.20.0/24 "back"
   +----------+      +-------------------------+      +-----------------------+
   |  client  | eth1 |        router           | eth2 |        server         |
   |   .10    |------| eth1 .1     eth2 .1     |------|                       |
   +----------+      | (ip_forward + nftables) |      | eth1 eth2             |
                     +-------------------------+      |   \   /               |
                                                      |  bond0 (active-backup)|
                                                      |    |                  |
                                                      |   br0 .10             |
                                                      | (NFS server here)     |
                                                      +-----------------------+
 "front"          10.10.20.0/24 "back"
   +----------+           +-------------------------+      +------------------------+
   |  client  |  eth1     |        router           | eth2 |        server          |
   | .10      |-----------| eth1 .1     eth2 .1     |------|                        |
   +----------+           |  (ip_forward + nftables)|      |  eth1 eth2             |
        |                 +-------------------------+      |    \   /               |
   route: 10.10.20.0/24                                    |   bond0 (active-backup)|
   via 10.10.10.1                                          |     |                  |
                                                           |    br0  .10            |
                                                           |  (NFS server here)     |
                                                           +------------------------+

   every node also has an eth0 on the LXD default network (DHCP) used ONLY
   for `apt-get install` during setup - lab traffic never touches eth0.
```

* **client** — NFS client + diagnostics tools (`tcpdump`, `nc`, `ping`, ...)
* **router** — routes and firewalls between the two lab segments (nftables,
  `net.ipv4.ip_forward=1`, no NAT — both segments are private and directly
  routed)
* **server** — `eth1` + `eth2` → **bond0** (active-backup) → **br0**
  (`10.10.20.10/24`), the classic "bond for NIC redundancy, bridge on top so
  the IP lives above it" hypervisor-host pattern. Runs `nfs-kernel-server`
  exporting `/srv/nfsshare`.

### Design notes (why it's built this way)

* **Bonding + bridging live together on `server`.** Rather than bolting on
  an artificial extra segment just to "show a bridge", the lab uses the
  real-world pattern where a bond is enslaved into a bridge and the IP
  address lives on the bridge. A fault in either layer (bond has no active
  slave, or the bridge has no members) has an observable, realistic effect:
  the server becomes unreachable.
* **Live `ip`/`nft` commands, not netplan, drive the lab.** This keeps
  `break.sh`/`fix.sh` fast, precise and idempotent inside ephemeral
  containers. Equivalent netplan YAML (for persisting the same design across
  a reboot on real hardware) is included for reference in
  `configs/netplan-examples/`.
* **Two "unmanaged" LXD networks** (`lxdbr-front`, `lxdbr-back`) are created
  with `ipv4.address=none` so LXD does **not** hand out DHCP/gateway
  addresses on them — every IP in the lab is assigned by hand, like a real
  network build.

---

## 2. Prerequisites

* Ubuntu 22.04+ host (or any LXD host)
* [LXD](https://linuxcontainers.org/lxd/) installed and initialized:
  ```bash
  sudo snap install lxd
  sudo lxd init --auto
  ```
* Your user in the `lxd` group (`newgrp lxd` after `sudo usermod -aG lxd $USER`)
* Internet access from the host (containers pull packages via their `eth0`
  DHCP NIC during setup)
* ~2 GB RAM / a few GB disk free for 3 small containers

> KVM is acceptable per the brief if LXD isn't available, but every script
> here assumes `lxc`. Porting to `virsh`/cloud-init is a drop-in swap of the
> node-provisioning step in `setup.sh` — the in-container network/fault
> scripts (`configs/*.sh`) are hypervisor-agnostic.

---

## 3. Setup

```bash
git clone <this-repo>   # or just copy the netlab/ folder
cd netlab
./setup.sh
```

`setup.sh` is idempotent — safe to re-run if it's interrupted. It will:

1. Create the two lab-only networks
2. Launch the 3 containers (`ubuntu:22.04`)
3. Attach the lab NICs (`eth1`/`eth2`) to the right networks
4. Wait for the containers to be ready
5. Push and run `configs/{server,router,client}-network.sh` inside each
   container to build the bond, bridge, routing, firewall and NFS export/mount

Verify it worked:

```bash
./diagnose.sh
```

Expected output ends with:

```
Summary: 27 PASS, 0 WARN, 0 FAIL
Lab is fully healthy.
```

(exact PASS count may vary slightly by Ubuntu point release)

---

## 4. Fault scenarios

Each fault is reproduced with one command and reversed with the matching
`fix.sh` call. Run `./diagnose.sh` before/after each to see it get caught
and cleared.

### 4.1 Wrong MTU

**What's wrong in the real world:** someone lowers the MTU on one hop
(often a VPN, tunnel, or a NIC reset back to a driver default) without
matching it end-to-end. Small packets keep working, so DNS/ping/SSH look
fine — then a large file transfer (like an NFS read) mysteriously hangs or
crawls.

```bash
./break.sh mtu
```
Sets the client's `eth1` MTU to 1400 while the rest of the path stays 1500.

**Expected `diagnose.sh` output:**
```
== 3. MTU consistency along the client <-> server path ==
[FAIL] client/eth1: MTU=1400 (expected 1500) - mismatched MTU along a path
       causes large packets to silently drop or fragment. Fix: ./fix.sh mtu
[PASS] router/eth1: MTU=1500
...
```

**Fix:**
```bash
./fix.sh mtu
```

### 4.2 Incorrect / inactive bond

**What's wrong in the real world:** a bond is configured but ends up with
zero active slaves — a NIC gets manually removed for maintenance and never
re-added, a driver reload drops the enslavement, or a cabling change breaks
both links at once.

```bash
./break.sh bond
```
Removes both `eth1` and `eth2` from `bond0` on the server (`ip link set ...
nomaster`). `bond0` stays up but carries no traffic.

**Expected `diagnose.sh` output:**
```
== 4. Bond state (server bond0) ==
[FAIL] server/bond0: only 0 slave(s) enslaved (expected 2) - bond is
       degraded or fully inactive. Fix: ./fix.sh bond
[FAIL] server/bond0: no active slave - bond0 is up but cannot forward any
       traffic. Fix: ./fix.sh bond
== 6. Reachability (ping) ==
[FAIL] router -> server (back hop): NOT reachable ...
```

**Fix:**
```bash
./fix.sh bond
```

### 4.3 Blocked NFS / firewall port

**What's wrong in the real world:** a firewall change (often "tighten
security" work) blocks a port that a dependent service actually needs —
NFS's 2049/tcp in this case — while general connectivity (ping, other
ports) keeps working, making it look like "the network is fine."

```bash
./break.sh firewall
```
Inserts an explicit `DROP` rule for `tcp dport 2049` from the front to the
back network on the router, ahead of the accept rules.

**Expected `diagnose.sh` output:**
```
== 8. Firewall (router forward chain / functional NFS port test) ==
[WARN] router: found extra DROP rule(s) in the forward chain beyond the
       baseline policy:
         ip saddr 10.10.10.0/24 ip daddr 10.10.20.0/24 tcp dport 2049 drop
[FAIL] client -> server: tcp/2049 (nfsd) is BLOCKED. Fix: ./fix.sh firewall
```

**Fix:**
```bash
./fix.sh firewall
```

### 4.4 Broken bridge configuration

**What's wrong in the real world:** during maintenance, an interface gets
detached from a bridge (or the bridge itself is misconfigured) and the host
silently loses reachability even though every individual link looks "up".

```bash
./break.sh bridge
```
Detaches `bond0` from `br0` on the server. `br0` is up but has no members.

**Expected `diagnose.sh` output:**
```
== 5. Bridge membership (server br0) ==
[FAIL] server/br0: has NO members - bridge exists but is empty, so nothing
       reaches the IP on br0. Fix: ./fix.sh bridge
== 6. Reachability (ping) ==
[FAIL] router -> server (back hop): NOT reachable ...
```

**Fix:**
```bash
./fix.sh bridge
```

### 4.5 NFS mount / connectivity issue

**What's wrong in the real world:** the network path is completely healthy,
but the NFS *service* itself is down or the export was removed — a
config-management change silently dropped an `/etc/exports` line, or someone
`systemctl stop`'d the daemon for "just a minute."

```bash
./break.sh nfs
```
Comments out the export line and stops `nfs-kernel-server` on the server.

**Expected `diagnose.sh` output:**
```
== 7. Listening ports (server: NFS services) ==
[FAIL] server: nothing listening on tcp/2049. Fix: ./fix.sh nfs
== 9. NFS export / mount ==
[FAIL] server: /srv/nfsshare is NOT exported ... Fix: ./fix.sh nfs
[FAIL] client: showmount cannot see the export on 10.10.20.10 ...
[FAIL] client: /mnt/nfsshare is NOT mounted. Fix: ./fix.sh nfs
```
Note interfaces/routes/ping/bond/bridge all still show `[PASS]` — a good
example of diagnostics correctly narrowing the fault to "application layer,
not network layer."

**Fix:**
```bash
./fix.sh nfs
```

### Run everything at once

```bash
./break.sh all      # inject all 5 faults
./diagnose.sh        # see a fully "unhealthy" report
./fix.sh all          # restore everything
./diagnose.sh        # back to fully healthy
```

---

## 5. What `diagnose.sh` checks

| # | Area | How |
|---|------|-----|
| 1 | Interface/link state | `operstate` of every lab interface on every node |
| 2 | IP addressing / routes | compares live `ip addr`/`ip route get` to the topology's known-good plan |
| 3 | MTU consistency | compares `ip link` MTU on every hop + a real `ping -M do -s 1472` end-to-end test |
| 4 | Bond state | parses `/proc/net/bonding/bond0`: mode, slave count, active slave |
| 5 | Bridge membership | `ip link show master br0` |
| 6 | Ping/connectivity | client→router, router→server, client→server |
| 7 | Listening ports | `ss -ltn` on the server for NFS's ports |
| 8 | Firewall | static check for stray `DROP` rules **and** a functional `nc -z` test through the firewall |
| 9 | NFS export/mount | `exportfs -v`, `showmount -e`, `mount`, and an actual file read |
| 10 | Logs | recent `dmesg` bonding messages, `nfs-kernel-server` service status, router kernel log tail |

Every `[FAIL]` line names the exact `./fix.sh <scenario>` to run. `[WARN]`
is used where something looks off but isn't necessarily broken (e.g. an
unexpected firewall rule that hasn't yet been proven to block traffic).

---

## 6. Concepts, briefly

**Bonding** combines two (or more) physical NICs into one logical interface
for redundancy and/or throughput. This lab uses **active-backup** mode: one
slave carries traffic, the other is a hot standby, and failover happens
purely on the host — no switch-side configuration (like LACP/802.3ad would
need) is required, which is exactly why it's the safe choice for a lab or
any environment where you don't control the upstream switch.

**Bridging** joins interfaces into a single logical Ethernet segment
(software switch) at layer 2. Enslaving `bond0` into `br0` and putting the
IP on `br0` (not on the bond or its slaves) is the standard pattern for
hypervisor hosts, where the bridge is also where VM taps would attach.

**MTU** (Maximum Transmission Unit) is the largest packet size a link will
carry. Every hop on a path should agree; a mismatched or reduced MTU
somewhere along the way silently drops or fragments large packets while
small packets (pings, DNS, SSH keepalives) keep working — which is exactly
why it's a classic "intermittent" bug that's easy to misdiagnose.

**Firewalling** (here: `nftables` on the router, filtering the `forward`
chain) controls what's allowed to cross between network segments. A
default-drop policy plus explicit allow rules for known-good traffic (NFS
ports, ICMP, established/related state) means an unexpected new `DROP` rule
is easy to spot as the odd one out.

**NFS** (Network File System) lets a client mount a directory exported by a
remote server as if it were local. It depends on more than one moving part
being healthy at once — network reachability, `rpcbind`/`nfsd` listening,
an active export line, and the client's mount actually being live — which
is why the lab's NFS fault is deliberately "everything else is fine, only
the service is down": it's a good test of whether diagnostics correctly
separate network problems from application problems.

---

## 7. Troubleshooting / lessons learned

* **Don't assume "ping works" means "the app works."** Scenario 4.3
  (firewall) and 4.5 (NFS down) both leave basic ping fully healthy —
  `diagnose.sh` deliberately does a port-level (`ss`, `nc -z`) and
  application-level (`showmount`, `mount`, read a file) check for exactly
  this reason.
* **MTU problems hide behind small packets.** A plain `ping` with default
  size (56 bytes) will succeed even with the MTU fault in section 4.1 — the
  script uses `ping -M do -s 1472` specifically to force a full-size,
  non-fragmenting packet that actually exercises the path MTU.
* **Order matters when tearing down/rebuilding a bond.** Slaves must be
  brought `down` before being enslaved (`master bond0`) and the `primary`
  slave must be set via `/sys/class/net/bond0/bonding/primary` **after**
  slaves are attached — setting it earlier silently has no effect.
- **A bridge with no members is a very quiet failure.** `br0` shows `state
  UP` even with zero members; only `ip link show master br0` (empty output)
  or a failed ping reveals the real problem — a good reminder to check
  membership explicitly rather than trusting link state alone.
* **nftables rule *order* matters.** `break.sh firewall` inserts its `DROP`
  rule ahead of the accept rules for the same traffic; `nft` evaluates rules
  top-to-bottom per chain, so an earlier matching rule wins even if a later
  rule would have allowed the traffic.
* **NFS mount failures are often just timing.** `showmount -e` can briefly
  fail right after `nfs-kernel-server` restarts while `rpcbind` re-registers
  services — `fix.sh nfs` deliberately re-runs both the export and the
  client remount rather than assuming one restart is instantly consistent.

---

## 8. Cleanup

```bash
./cleanup.sh
```
Deletes all 3 containers and both lab networks. Nothing outside the `lxd`
storage pool used for these containers is touched.

---

## 9. Repo layout

```
netlab/
├── setup.sh                     # builds the lab
├── break.sh                     # injects a fault scenario
├── diagnose.sh                  # full health check with PASS/WARN/FAIL
├── fix.sh                       # restores a fault scenario
├── cleanup.sh                   # tears the lab down
├── lib/
│   ├── topology.sh              # single source of truth: names/IPs/expected values
│   └── common.sh                # PASS/WARN/FAIL logging + lxc exec helpers
├── configs/
│   ├── server-network.sh        # bond0 -> br0 + NFS export (runs inside `server`)
│   ├── router-network.sh        # addressing + forwarding + nftables (runs inside `router`)
│   ├── client-network.sh        # addressing + NFS mount (runs inside `client`)
│   ├── nftables-router.nft      # baseline firewall ruleset
│   └── netplan-examples/        # reference-only: same design, persisted via netplan
└── README.md
```
