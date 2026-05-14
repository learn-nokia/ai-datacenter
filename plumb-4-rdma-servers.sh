#!/bin/bash
set -e

NS="eda-system"
IMAGE="ghcr.io/mfzhsn/network-multitool-roce:0.1"

get_pod() {
  local node="$1"
  kubectl -n "$NS" get pod --no-headers \
    | awk -v n="cx-eda--${node}-sim" '$1 ~ n {print $1; exit}'
}

get_srl_pid() {
  local node="$1"
  local pod cid shortcid pid

  pod=$(get_pod "$node")
  cid=$(kubectl -n "$NS" get pod "$pod" \
    -o jsonpath="{.status.containerStatuses[?(@.name=='$node')].containerID}" \
    | sed 's#containerd://##')

  shortcid=${cid:0:12}

  pid=$(grep -Rsl "$cid\|$shortcid" /proc/*/cgroup 2>/dev/null \
    | awk -F/ '{print $3}' | head -1)

  [ -n "$pid" ] || { echo "ERROR: no PID for $node"; exit 1; }
  echo "$pid"
}

get_docker_pid() {
  docker inspect -f '{{.State.Pid}}' "$1"
}

cleanup() {
  echo "[cleanup] removing old Docker servers/veths"

  for s in server1 server2 server3 server4; do
    docker rm -f "$s" 2>/dev/null || true
  done

  for i in \
    s1e1 s1e2 s1e11 s1e12 \
    s2e1 s2e2 s2e11 s2e12 \
    s3e1 s3e2 s3e11 s3e12 \
    s4e1 s4e2 s4e11 s4e12 \
    l1p1 l1p2 l2p1 l2p2 \
    l3p1 l3p2 l4p1 l4p2 \
    r1p1 r1p2 r1p3 r1p4 \
    r2p1 r2p2 r2p3 r2p4
  do
    ip link del "$i" 2>/dev/null || true
  done
}

create_servers() {
  echo "[setup] creating Docker server containers"

  for s in server1 server2 server3 server4; do
    docker run -dit \
      --name "$s" \
      --privileged \
      --network none \
      -v /dev/infiniband:/dev/infiniband \
      "$IMAGE" sleep infinity
  done
}

plug_link() {
  local srv="$1"
  local srv_if="$2"
  local srl_node="$3"
  local srl_if="$4"
  local host_tmp="$5"
  local srl_tmp="$6"

  local srv_pid srl_pid
  srv_pid=$(get_docker_pid "$srv")
  srl_pid=$(get_srl_pid "$srl_node")

  echo "[plug] ${srv}:${srv_if} <--> ${srl_node}:${srl_if}"

  ip link add "$host_tmp" type veth peer name "$srl_tmp"

  ip link set "$host_tmp" netns "$srv_pid"
  nsenter -t "$srv_pid" -n ip link set "$host_tmp" name "$srv_if"
  nsenter -t "$srv_pid" -n ip link set "$srv_if" up

  ip link set "$srl_tmp" netns "$srl_pid"
  nsenter -t "$srl_pid" -n ip link set "$srl_tmp" name "$srl_if"
  nsenter -t "$srl_pid" -n ip link set "$srl_if" up
}

configure_server() {
  local srv="$1"
  local id="$2"
  local pid

  pid=$(get_docker_pid "$srv")

  echo "[config] configuring $srv"

  nsenter -t "$pid" -n ip link set lo up

  nsenter -t "$pid" -n ip link add bond0 type bond mode 802.3ad xmit_hash_policy layer3+4 || true
  nsenter -t "$pid" -n ip link set addr "00:c1:ab:01:01:0${id}" dev bond0

  nsenter -t "$pid" -n ip link set eth1 down || true
  nsenter -t "$pid" -n ip link set eth2 down || true
  nsenter -t "$pid" -n ip link set eth1 master bond0
  nsenter -t "$pid" -n ip link set eth2 master bond0
  nsenter -t "$pid" -n ip link set eth1 up
  nsenter -t "$pid" -n ip link set eth2 up
  nsenter -t "$pid" -n ip link set bond0 up

  nsenter -t "$pid" -n ip link add link bond0 name bond0.1001 type vlan id 1001 || true
  nsenter -t "$pid" -n ip addr add "10.10.10.${id}/24" dev bond0.1001 || true
  nsenter -t "$pid" -n ip link set bond0.1001 up

  if [ "$id" = "1" ] || [ "$id" = "3" ]; then
    nsenter -t "$pid" -n ip link add link bond0 name bond0.201 type vlan id 201 || true
    nsenter -t "$pid" -n ip addr add "10.20.1.${id}/24" dev bond0.201 || true
    nsenter -t "$pid" -n ip link set bond0.201 up
  else
    nsenter -t "$pid" -n ip link add link bond0 name bond0.202 type vlan id 202 || true
    nsenter -t "$pid" -n ip addr add "10.20.2.${id}/24" dev bond0.202 || true
    nsenter -t "$pid" -n ip link set bond0.202 up
  fi

  nsenter -t "$pid" -n ip link set eth11 up
  nsenter -t "$pid" -n ip link set eth12 up
  nsenter -t "$pid" -n ip addr add "172.30.11.${id}/24" dev eth11 || true
  nsenter -t "$pid" -n ip addr add "172.30.12.${id}/24" dev eth12 || true

  nsenter -t "$pid" -n rdma link add "rxe_${srv}_11" type rxe netdev eth11 || true
  nsenter -t "$pid" -n rdma link add "rxe_${srv}_12" type rxe netdev eth12 || true

  docker exec "$srv" iperf3 -s -p 5201 -D 2>/dev/null || true
  docker exec "$srv" iperf3 -s -p 5202 -D 2>/dev/null || true
}

verify_server() {
  local srv="$1"

  echo
  echo "========== $srv =========="
  docker exec "$srv" ip -br addr
  echo
  docker exec "$srv" cat /proc/net/bonding/bond0 || true
  echo
  docker exec "$srv" rdma link || true
  echo
  docker exec "$srv" ibv_devices || true
}

echo "[setup] loading RDMA modules"
modprobe rdma_rxe
modprobe ib_uverbs
modprobe rdma_ucm

cleanup
create_servers

echo "[setup] plumbing frontend links"

plug_link server1 eth1 leaf1 host-s1e1 s1e1 l1p1
plug_link server1 eth2 leaf2 host-s1e2 s1e2 l2p1

plug_link server2 eth1 leaf1 host-s2e1 s2e1 l1p2
plug_link server2 eth2 leaf2 host-s2e2 s2e2 l2p2

plug_link server3 eth1 leaf3 host-s3e1 s3e1 l3p1
plug_link server3 eth2 leaf4 host-s3e2 s3e2 l4p1

plug_link server4 eth1 leaf3 host-s4e1 s4e1 l3p2
plug_link server4 eth2 leaf4 host-s4e2 s4e2 l4p2

echo "[setup] plumbing backend RDMA rail links"

plug_link server1 eth11 rail1 host-s1e11 s1e11 r1p1
plug_link server1 eth12 rail2 host-s1e12 s1e12 r2p1

plug_link server2 eth11 rail1 host-s2e11 s2e11 r1p2
plug_link server2 eth12 rail2 host-s2e12 s2e12 r2p2

plug_link server3 eth11 rail1 host-s3e11 s3e11 r1p3
plug_link server3 eth12 rail2 host-s3e12 s3e12 r2p3

plug_link server4 eth11 rail1 host-s4e11 s4e11 r1p4
plug_link server4 eth12 rail2 host-s4e12 s4e12 r2p4

configure_server server1 1
configure_server server2 2
configure_server server3 3
configure_server server4 4

verify_server server1
verify_server server2
verify_server server3
verify_server server4

echo
echo "[done] Docker servers deployed and plumbed."
echo
echo "Login examples:"
echo "  docker exec -it server1 bash"
echo "  docker exec -it server2 bash"
echo
echo "Frontend tests:"
echo "  docker exec server1 ping -c 3 10.10.10.2"
echo "  docker exec server1 ping -c 3 10.20.1.3"
echo "  docker exec server2 ping -c 3 10.20.2.4"
echo
echo "RDMA tests:"
echo "  docker exec -it server1 ib_write_bw -d rxe_server1_11"
echo "  docker exec -it server2 ib_write_bw -d rxe_server2_11 172.30.11.1"
