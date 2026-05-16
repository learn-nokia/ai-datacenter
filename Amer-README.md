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
## Activity 3: Observability and Validation of the AI Backend Fabric (Streaming Telemetry, Grafana Dashboards)


## Solution

AI Backend Fabric Intent:

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