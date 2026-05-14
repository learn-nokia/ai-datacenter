#!/bin/bash

set -e

TOPO_NS=${TOPO_NS:-eda}
CORE_NS=${CORE_NS:-eda-system}

echo "Waiting for simlinks to be created"
kubectl -n ${TOPO_NS} wait --for=create simlink l1-l2-e1-1-lag-1 --timeout=120s
kubectl -n ${TOPO_NS} wait --for=create simlink l1-l2-e1-2-lag-2 --timeout=120s
kubectl -n ${TOPO_NS} wait --for=create simlink l3-l4-e1-1-lag-1 --timeout=120s
kubectl -n ${TOPO_NS} wait --for=create simlink l3-l4-e1-2-lag-2 --timeout=120s

echo "Waiting for server pods to be ready..."
for server in server1 server2 server3 server4; do
  echo "Waiting for $server pod..."
  kubectl -n ${CORE_NS} wait --for=condition=ready pod -l eda.nokia.com/app=sim-${server} --timeout=300s
done

echo "Waiting for server interfaces..."
for server in server1 server2 server3 server4; do
  POD=$(kubectl get -n ${CORE_NS} pods -l eda.nokia.com/app=sim-${server} -o jsonpath="{.items[0].metadata.name}")
  echo "Waiting for $server interfaces on $POD..."

  kubectl -n ${CORE_NS} exec -c ${server} ${POD} -- bash -lc '
    for i in eth1 eth2 eth11 eth12; do
      until ip link show $i >/dev/null 2>&1; do
        echo "waiting for $i"
        sleep 2
      done
    done
  '
done

echo "Configuring server IPs and interfaces..."
for server in server1 server2 server3 server4; do
  POD=$(kubectl get -n ${CORE_NS} pods -l eda.nokia.com/app=sim-${server} -o jsonpath="{.items[0].metadata.name}")
  echo "Configuring $server on $POD..."

  kubectl -n ${CORE_NS} exec -c ${server} ${POD} -- bash -lc "$(cat configs/servers/${server}.sh)" || true

  echo "Forcing $server bond0 to active-backup and bringing links up..."
  kubectl -n ${CORE_NS} exec -c ${server} ${POD} -- bash -lc '
    ip link set eth1 up || true
    ip link set eth2 up || true
    ip link set eth11 up || true
    ip link set eth12 up || true

    if [ -d /sys/class/net/bond0/bonding ]; then
      ip link set bond0 down || true
      echo active-backup > /sys/class/net/bond0/bonding/mode || true
      ip link set bond0 up || true
    fi

    for v in bond0.1001 bond0.201 bond0.202; do
      ip link show $v >/dev/null 2>&1 && ip link set $v up || true
    done

    ip -br addr
  '
done

echo "Server configuration completed."