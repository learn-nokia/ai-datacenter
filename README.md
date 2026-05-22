# Workshop: Building an AI Backend Network with Nokia Event Driven Automation (EDA)

## Overview

This workshop introduces the core concepts of **intent-based networking** using **Nokia Event Driven Automation (EDA)** and **SR Linux** to build an AI backend network fabric.

Participants will learn how to translate high-level network intent into automated infrastructure deployment, allowing Nokia EDA to handle configuration generation, state validation, and continuous reconciliation.

The lab focuses on deploying a realistic AI backend fabric, connecting simulated GPU/server nodes, configuring routed backend interfaces, validating IPv6 reachability, and testing Soft-RoCE/RDMA traffic.

The goal is to demonstrate how Nokia EDA simplifies the deployment and operation of modern AI/HPC data center networks by using intent, automation, event-driven workflows, and closed-loop validation.

---

## What You Will Build

In this workshop, you will build a simulated AI backend network with:

- Nokia EDA
- SR Linux leaf switches - Frontend
- SR Linux rail switches - AI Backend
- Simulated server/GPU nodes
- IPv6 routed backend links
- IP-VRF based backend isolation
- Soft-RoCE/RDMA validation between servers

---

## Access Details

## Access Details

| Component | How to Access | Example |
|---|---|---|
| Nokia EDA | Browser | `https://<EDA-IP-or-FQDN>` |
| Grafana | Browser | `http://<GRAFANA-IP-or-FQDN>:3000` |
| Leaf1/2/3/4 | CLI | `ssh admin@<node-ip>` or `kubectl -n eda-system exec -it <pod> -- sr_cli` |
| Server 1 | Container shell | `docker exec -it server1 bash` |
| Server 2 | Container shell | `docker exec -it server2 bash` |
| Server 3 | Container shell | `docker exec -it server3 bash` |
| Server 4 | Container shell | `docker exec -it server4 bash` |
| Server 5 | Container shell | `docker exec -it server5 bash` |



## Getting Started

## Activity 1: Concepts of Intent-Based Networking
## Activity 2: Deploy the AI Backend Fabric using Intent
## Activity 3: Perform RDMA Traffic between Server1 and Server2 using Soft-RoCE

This section shows how to run a simple IPv6 Soft-RoCE bandwidth test using `ib_send_bw`.

The test uses two RXE devices:

| Role | Node | RXE Device | Purpose |
|---|---|---|---|
| Server | server1 | `rxe2` | Listens for the RDMA connection |
| Client | server2 | `rxe1` | Connects to the server |
| Target IP | server1 | `fd00:60::11` | Server-side IPv6 address |

### Bandwidth Test

**Server Side - Server1**

Start the bandwidth test listener on `server1`

```
ib_send_bw -d rxe2 -F --ipv6 --ipv6-addr -x 2 -R --report_gbits
```

**Client Side - Server2**

Start the bandwidth test client on `server2`:

```
ib_send_bw -d rxe1 -F --ipv6 --ipv6-addr -x 2 -R --report_gbits fd00:60::11
```

### Latency Test

**Server Side - Server1**

Start the bandwidth test listener on `server1`:

```
ib_send_lat -d rxe2 -F --ipv6 --ipv6-addr -x 2 -R --report_gbits
```

**Client Side - Server2**

Start the bandwidth test client on `server2`:

```
ib_send_lat -d rxe1 -F --ipv6 --ipv6-addr -x 2 -R --report_gbits fd00:60::11
```

## Activity 4: Observability and Validation of the AI Backend Fabric (Streaming Telemetry, Grafana Dashboards)


## Solution

**RDMA Latency Test**

```
*** Server Side - Server1 ***

************************************
* Waiting for client to connect... *
************************************

*** Client Side - Server2 ***

---------------------------------------------------------------------------------------
                    Send Latency Test
 Dual-port       : OFF		Device         : rxe1
 Number of qps   : 1		Transport type : IB
 Connection type : RC		Using SRQ      : OFF
 PCIe relax order: ON
 ibv_wr* API     : OFF
 TX depth        : 1
 Mtu             : 1024[B]
 Link type       : Ethernet
 GID index       : 1
 Max inline data : 0[B]
 rdma_cm QPs	 : ON
 Data ex. method : rdma_cm
---------------------------------------------------------------------------------------
 local address: LID 0000 QPN 0x0023 PSN 0xaadffa
 GID: 00:00:00:00:00:00:00:00:00:00:255:255:172:30:60:12
 remote address: LID 0000 QPN 0x0024 PSN 0x2b1d11
 GID: 00:00:00:00:00:00:00:00:00:00:255:255:172:30:60:12
---------------------------------------------------------------------------------------
 #bytes #iterations    t_min[usec]    t_max[usec]  t_typical[usec]    t_avg[usec]    t_stdev[usec]   99% percentile[usec]   99.9% percentile[usec]
 2       1000          6.64           725.77       7.92     	       10.23       	24.62  		25.91   		725.77
---------------------------------------------------------------------------------------
```


**RDMA Bandwidth Test**

```
*** Server Side - Server1 ***

 WARNING: BW peak won't be measured in this run.

************************************
* Waiting for client to connect... *
************************************

*** Client Side - Server2 ***

---------------------------------------------------------------------------------------
                    Send BW Test
 Dual-port       : OFF		Device         : rxe1
 Number of qps   : 1		Transport type : IB
 Connection type : RC		Using SRQ      : OFF
 PCIe relax order: ON
 ibv_wr* API     : OFF
 TX depth        : 128
 CQ Moderation   : 1
 Mtu             : 1024[B]
 Link type       : Ethernet
 GID index       : 1
 Max inline data : 0[B]
 rdma_cm QPs	 : ON
 Data ex. method : rdma_cm
---------------------------------------------------------------------------------------
 local address: LID 0000 QPN 0x0027 PSN 0x559c3
 GID: 00:00:00:00:00:00:00:00:00:00:255:255:172:30:60:12
 remote address: LID 0000 QPN 0x0028 PSN 0x1d252a
 GID: 00:00:00:00:00:00:00:00:00:00:255:255:172:30:60:12
---------------------------------------------------------------------------------------
 #bytes     #iterations    BW peak[MB/sec]    BW average[MB/sec]   MsgRate[Mpps]
 65536      1000             367.17             318.37 		   0.005094
---------------------------------------------------------------------------------------
```

**AI Backend Fabric Intent**

```
apiVersion: aifabrics.eda.nokia.com/v1
kind: Backend
metadata:
  name: ai-backend-fabric
  namespace: eda
spec:
  addressAllocation:
    edaManagedIPv6:
      leafIndexPoolScope: Global
      prefixLength: '64'
    type: EDAManagedIPv6
  asnPool: asn-pool
  gpuIsolationGroups:
    - interfaceSelectors:
        - eda.nokia.com/gpu_group = nvidia
      name: nvidia
    - interfaceSelectors:
        - eda.nokia.com/gpu_group = amd
      name: amd
  ipMTU: 4200
  rocev2QoS:
    ecnMaxDropProbabilityPercent: 100
    ecnSlopeMaxThresholdPercent: 80
    ecnSlopeMinThresholdPercent: 5
    pfcDeadlockDetectionTimerMs: 750
    pfcDeadlockRecoveryTimerMs: 750
    queueMaximumBurstSizeBytes: 1024000
  stripes:
    - asnPool: asn-pool
      name: stripe1
      nodeSelectors:
        - eda.nokia.com/role = rail
      stripeID: 101
      systemPoolIPv4: systemipv4-pool
  systemPoolIPv4: systemipv4-pool
```

## Tools

### SPING

```
# Normal
sping s1 s2

# 100 normal pings
sping s1 s2 count 100

# Aggressive, 1400-byte payload, 100 pings/sec
sping s1 s2 size 1400 interval 0.01 count 10000

# Safe MTU 1500 max payload with DF
sping s1 s2 size 1472 df count 10

# Try 4000-byte payload, requires MTU bigger than 4028
sping s1 s2 size 4000 df count 10

# Jumbo payload, requires MTU 9000 end-to-end
sping s1 s2 size 8972 df count 10

# Jumbo with lower rate
sping s1 s2 size 8972 interval 0.5 df count 20
```

### SIPERF

```
# Basic TCP test from server1 to server2
siperf s1 s2

# 30-second TCP test
siperf s1 s2 time 30

# TCP test with 4 parallel streams
siperf s1 s2 time 30 parallel 4

# UDP test at 1G for 20 seconds
siperf s1 s2 udp bandwidth 1G time 20

# Reverse direction test using iperf3 -R
siperf s1 s2 reverse time 20

# Cross-rack test
siperf s1 s4 time 30 parallel 4

# Server3 to server4 local-pair test
siperf s3 s4 time 20 parallel 2
```

| Server  | Interface | Connected rail | Server IPv6            | Gateway             |
| ------- | --------- | -------------- | ---------------------- | ------------------- |
| server1 | `s1eth11` | rail1 e1/1     | `fd00:100:101:1::2/64` | `fd00:100:101:1::1` |
| server2 | `s2eth11` | rail1 e1/2     | `fd00:100:101:2::2/64` | `fd00:100:101:2::1` |
| server3 | `s3eth11` | rail1 e1/3     | `fd00:100:101:3::3/64` | `fd00:100:101:3::1` |
| server4 | `s4eth11` | rail1 e1/4     | `fd00:100:101:4::4/64` | `fd00:100:101:4::1` |
| server1 | `s1eth12` | rail2 e1/1     | `fd00:100:201:1::2/64` | `fd00:100:201:1::1` |
| server2 | `s2eth12` | rail2 e1/2     | `fd00:100:201:2::2/64` | `fd00:100:201:2::1` |
| server3 | `s3eth12` | rail2 e1/3     | `fd00:100:201:3::3/64` | `fd00:100:201:3::1` |
| server4 | `s4eth12` | rail2 e1/4     | `fd00:100:201:4::4/64` | `fd00:100:201:4::1` |

## AI Back Ping Test

Local Gateway from Server-1 to GW1

```
ip vrf exec vrf-s1 ping6 -I s1eth11 -c 5 fd00:100:101:1::1
```

GPU1 to GPU 2

```
ip vrf exec vrf-s1 ping6 -I s1eth11 -c 5 fd00:100:101:2::2
```

## Prepare VM Host for RDMA


```
dnf install -y libibverbs-utils
dnf install -y rdma-core rdma-core-devel libibverbs libibverbs-utils perftest iproute iproute-tc kernel-modules-extra

modinfo rdma_rxe
modprobe rdma_rxe
lsmod | grep rxe
```

Make sure you get these modules loaded from the last command:

```
rdma_rxe
ib_uverbs
ib_core
```

sample:

```
[root@chinog2026 mozaman]# lsmod | grep rxe
rdma_rxe              208896  0
ib_uverbs             217088  1 rdma_rxe
ip6_udp_tunnel         16384  1 rdma_rxe
udp_tunnel             36864  1 rdma_rxe
ib_core               573440  2 rdma_rxe,ib_uverbs
```

How to make it persistent across reboots:

```
cat >/etc/modules-load.d/rdma-rxe.conf <<'EOF'
rdma_rxe
EOF
```

### Security patch

```
dnf config-manager --set-enabled security
dnf update -y 
```

Expected output:

```
5.14.0-611.55.1.el9_7.0.3.x86_64
```

```
root@chinog2026:/# ib_send_lat -d rxe2 -F --ipv6 --ipv6-addr -x 2 -R --report_gbits

************************************
* Waiting for client to connect... *
************************************
---------------------------------------------------------------------------------------
                    Send Latency Test
 Dual-port       : OFF		Device         : rxe2
 Number of qps   : 1		Transport type : IB
 Connection type : RC		Using SRQ      : OFF
 PCIe relax order: ON
 ibv_wr* API     : OFF
 RX depth        : 512
 Mtu             : 1024[B]
 Link type       : Ethernet
 GID index       : 2
 Max inline data : 0[B]
 rdma_cm QPs	 : ON
 Data ex. method : rdma_cm
---------------------------------------------------------------------------------------
 Waiting for client rdma_cm QP to connect
 Please run the same command with the IB/RoCE interface IP
---------------------------------------------------------------------------------------
 local address: LID 0000 QPN 0x002c PSN 0xc03c9c
 GID: 253:00:00:96:00:00:00:00:00:00:00:00:00:00:00:17
 remote address: LID 0000 QPN 0x002b PSN 0x574fdb
 GID: 253:00:00:96:00:00:00:00:00:00:00:00:00:00:00:17
---------------------------------------------------------------------------------------
 #bytes #iterations    t_min[usec]    t_max[usec]  t_typical[usec]    t_avg[usec]    t_stdev[usec]   99% percentile[usec]   99.9% percentile[usec]
 2       1000          4.06           15.17        5.36     	       5.48        	0.88   		11.58   		15.17
---------------------------------------------------------------------------------------
```

### INstall show gids utility

```
# 1. Download the tool directly into your system executable directory
sudo curl -sSLo /usr/local/bin/show_gids https://raw.githubusercontent.com/Mellanox/mlnx-tools/master/sbin/show_gids

# 2. Grant execution permissions 
sudo chmod +x /usr/local/bin/show_gids

# 3. Force a quick system path rehash to register the binary instantly
hash -r

```