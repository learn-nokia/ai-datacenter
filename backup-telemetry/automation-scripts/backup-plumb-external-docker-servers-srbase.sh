#!/bin/bash
set -e

NS="eda-system"

get_pod() {
  local node="$1"
  kubectl -n "$NS" get pod --no-headers | awk -v n="cx-eda--${node}-sim" '$1 ~ n {print $1; exit}'
}

get_srl_pid() {
  local node="$1"
  local pod cid shortcid pid

  pod=$(get_pod "$node")
  [ -n "$pod" ] || { echo "ERROR: pod not found for $node"; exit 1; }

  cid=$(kubectl -n "$NS" get pod "$pod" \
    -o jsonpath="{.status.containerStatuses[?(@.name=='$node')].containerID}" \
    | sed 's#containerd://##')

  shortcid=${cid:0:12}

  pid=$(grep -Rsl "$cid\|$shortcid" /proc/*/cgroup 2>/dev/null \
    | awk -F/ '{print $3}' | head -1)

  [ -n "$pid" ] || { echo "ERROR: PID not found for $node"; exit 1; }
  echo "$pid"
}

get_docker_pid() {
  docker inspect -f '{{.State.Pid}}' "$1"
}

cleanup_links() {
  for i in \
    s1e1 s1e2 s1e11 s1e12 \
    s2e1 s2e2 s2e11 s2e12 \
    s3e1 s3e2 s3e11 s3e12 \
    s4e1 s4e2 s4e11 s4e12 \
    p-l1-s1 p-l2-s1 p-l1-s2 p-l2-s2 \
    p-l3-s3 p-l4-s3 p-l3-s4 p-l4-s4 \
    p-r1-s1 p-r2-s1 p-r1-s2 p-r2-s2 \
    p-r1-s3 p-r2-s3 p-r1-s4 p-r2-s4
  do
    ip link del "$i" 2>/dev/null || true
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

  echo "[plug] ${srv}:${srv_if} <--> ${srl_node}:srbase:${srl_if}"

  ip link add "$host_tmp" type veth peer name "$srl_tmp"

  # Server side into Docker container netns
  ip link set "$host_tmp" netns "$srv_pid"
  nsenter -t "$srv_pid" -n ip link set "$host_tmp" name "$srv_if"
  nsenter -t "$srv_pid" -n ip link set "$srv_if" up

  # SR Linux side: first into container netns, then into srbase netns
  ip link set "$srl_tmp" netns "$srl_pid"
  nsenter -t "$srl_pid" -m -n ip link set "$srl_tmp" netns srbase
  nsenter -t "$srl_pid" -m -n ip netns exec srbase ip link set "$srl_tmp" name "$srl_if"
  nsenter -t "$srl_pid" -m -n ip netns exec srbase ip link set "$srl_if" up
  }

config_server_frontend_and_rdma() {
  local srv="$1"
  local id="$2"
  local pid

  pid=$(get_docker_pid "$srv")

  echo "[config] $srv"

  nsenter -t "$pid" -n ip link set lo up

  # Frontend bond eth1/eth2
  nsenter -t "$pid" -n ip link add bond0 type bond mode 802.3ad xmit_hash_policy layer3+4 || true
  nsenter -t "$pid" -n ip link set addr "00:c1:ab:01:01:0${id}" dev bond0

  nsenter -t "$pid" -n ip link set eth1 down || true
  nsenter -t "$pid" -n ip link set eth2 down || true
  nsenter -t "$pid" -n ip link set eth1 master bond0
  nsenter -t "$pid" -n ip link set eth2 master bond0
  nsenter -t "$pid" -n ip link set eth1 up
  nsenter -t "$pid" -n ip link set eth2 up
  nsenter -t "$pid" -n ip link set bond0 up

  # Common frontend VLAN
  nsenter -t "$pid" -n ip link add link bond0 name bond0.1001 type vlan id 1001 || true
  nsenter -t "$pid" -n ip addr add "10.10.10.${id}/24" dev bond0.1001 || true
  nsenter -t "$pid" -n ip link set bond0.1001 up

  # VLAN 201 for server1/server3, VLAN 202 for server2/server4
  if [ "$id" = "1" ] || [ "$id" = "3" ]; then
    nsenter -t "$pid" -n ip link add link bond0 name bond0.201 type vlan id 201 || true
    nsenter -t "$pid" -n ip addr add "10.20.1.${id}/24" dev bond0.201 || true
    nsenter -t "$pid" -n ip link set bond0.201 up
  else
    nsenter -t "$pid" -n ip link add link bond0 name bond0.202 type vlan id 202 || true
    nsenter -t "$pid" -n ip addr add "10.20.2.${id}/24" dev bond0.202 || true
    nsenter -t "$pid" -n ip link set bond0.202 up
  fi

  # Backend RDMA ports
  nsenter -t "$pid" -n ip link set eth11 up
  nsenter -t "$pid" -n ip link set eth12 up
  nsenter -t "$pid" -n ip addr add "172.30.11.${id}/24" dev eth11 || true
  nsenter -t "$pid" -n ip addr add "172.30.12.${id}/24" dev eth12 || true

  nsenter -t "$pid" -n rdma link add "rxe_${srv}_11" type rxe netdev eth11 || true
  nsenter -t "$pid" -n rdma link add "rxe_${srv}_12" type rxe netdev eth12 || true
}

verify_server() {
  local srv="$1"
  echo
  echo "========== $srv =========="
  docker exec "$srv" ip -br addr
  docker exec "$srv" rdma link || true
  docker exec "$srv" ibv_devices || true
}

verify_srl() {
  local node="$1"
  local pid
  pid=$(get_srl_pid "$node")
  echo
  echo "========== $node srbase =========="
  nsenter -t "$pid" -n ip netns exec srbase ip -br link | egrep 'e1-|mgmt|eth0' || true
}

modprobe rdma_rxe
modprobe ib_uverbs
modprobe rdma_ucm

cleanup_links

# Frontend edge links
plug_link server1 eth1  leaf1 e1-1  s1e1  p-l1-s1
plug_link server1 eth2  leaf2 e1-1  s1e2  p-l2-s1

plug_link server2 eth1  leaf1 e1-2  s2e1  p-l1-s2
plug_link server2 eth2  leaf2 e1-2  s2e2  p-l2-s2

plug_link server3 eth1  leaf3 e1-1  s3e1  p-l3-s3
plug_link server3 eth2  leaf4 e1-1  s3e2  p-l4-s3

plug_link server4 eth1  leaf3 e1-2  s4e1  p-l3-s4
plug_link server4 eth2  leaf4 e1-2  s4e2  p-l4-s4

# Backend RDMA links
plug_link server1 eth11 rail1 e1-1  s1e11 p-r1-s1
plug_link server1 eth12 rail2 e1-1  s1e12 p-r2-s1

plug_link server2 eth11 rail1 e1-2  s2e11 p-r1-s2
plug_link server2 eth12 rail2 e1-2  s2e12 p-r2-s2

plug_link server3 eth11 rail1 e1-3  s3e11 p-r1-s3
plug_link server3 eth12 rail2 e1-3  s3e12 p-r2-s3

plug_link server4 eth11 rail1 e1-4  s4e11 p-r1-s4
plug_link server4 eth12 rail2 e1-4  s4e12 p-r2-s4

config_server_frontend_and_rdma server1 1
config_server_frontend_and_rdma server2 2
config_server_frontend_and_rdma server3 3
config_server_frontend_and_rdma server4 4

verify_server server1
verify_server server2
verify_server server3
verify_server server4

verify_srl leaf1
verify_srl leaf2
verify_srl leaf3
verify_srl leaf4
verify_srl rail1
verify_srl rail2

echo
echo "[done]"
echo "Login:"
echo "  docker exec -it server1 bash"
echo
echo "Frontend test after EDA/SR Linux services are configured:"
echo "  docker exec server1 ping -c 3 10.10.10.2"
echo
echo "RDMA test after rail service path is configured:"
echo "  docker exec -it server1 ib_write_bw -d rxe_server1_11"
echo "  docker exec -it server2 ib_write_bw -d rxe_server2_11 172.30.11.1"
