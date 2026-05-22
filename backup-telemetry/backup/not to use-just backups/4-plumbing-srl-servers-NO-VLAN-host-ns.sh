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

get_server_id() {
  case "$1" in
    server1) echo 1 ;;
    server2) echo 2 ;;
    server3) echo 3 ;;
    server4) echo 4 ;;
    *)
      echo "ERROR: unsupported server: $1" >&2
      exit 1
      ;;
  esac
}

host_if_name() {
  local srv="$1"
  local srv_if="$2"
  local id

  id=$(get_server_id "$srv")

  case "$srv_if" in
    eth1)  echo "s${id}eth1" ;;
    eth2)  echo "s${id}eth2" ;;
    eth11) echo "s${id}eth11" ;;
    eth12) echo "s${id}eth12" ;;
    *)
      echo "ERROR: unsupported server interface: $srv_if" >&2
      exit 1
      ;;
  esac
}

bond_name() {
  local id="$1"
  echo "b${id}"
}

delete_if_in_host() {
  local ifname="$1"
  ip link del "$ifname" 2>/dev/null || true
}

delete_rxe() {
  local rxe="$1"
  rdma link delete "$rxe" 2>/dev/null || true
}

delete_if_in_srl_srbase() {
  local node="$1"
  local ifname="$2"
  local pid

  pid=$(get_srl_pid "$node" 2>/dev/null || true)
  [ -n "$pid" ] || return 0

  nsenter -t "$pid" -m -n ip netns exec srbase ip link del "$ifname" 2>/dev/null || true
}

cleanup_links() {
  echo "[cleanup] deleting RXE devices..."

  for s in server1 server2 server3 server4; do
    delete_rxe "rxe_${s}_11"
    delete_rxe "rxe_${s}_12"
  done

  echo "[cleanup] deleting host-side server interfaces..."

  for i in \
    s1eth1 s1eth2 s1eth11 s1eth12 \
    s2eth1 s2eth2 s2eth11 s2eth12 \
    s3eth1 s3eth2 s3eth11 s3eth12 \
    s4eth1 s4eth2 s4eth11 s4eth12 \
    b1 b2 b3 b4 \
    b1.1001 b2.1001 b3.1001 b4.1001 \
    b1.201 b2.202 b3.201 b4.202 \
    s1e1 s1e2 s1e11 s1e12 \
    s2e1 s2e2 s2e11 s2e12 \
    s3e1 s3e2 s3e11 s3e12 \
    s4e1 s4e2 s4e11 s4e12 \
    p-l1-s1 p-l2-s1 p-l1-s2 p-l2-s2 \
    p-l3-s3 p-l4-s3 p-l3-s4 p-l4-s4 \
    p-r1-s1 p-r2-s1 p-r1-s2 p-r2-s2 \
    p-r1-s3 p-r2-s3 p-r1-s4 p-r2-s4
  do
    delete_if_in_host "$i"
  done

  echo "[cleanup] deleting old SR Linux srbase interfaces..."

  for n in leaf1 leaf2 leaf3 leaf4 rail1 rail2; do
    delete_if_in_srl_srbase "$n" e1-1
    delete_if_in_srl_srbase "$n" e1-2
    delete_if_in_srl_srbase "$n" e1-3
    delete_if_in_srl_srbase "$n" e1-4
  done
}

plug_link() {
  local srv="$1"
  local srv_if="$2"
  local srl_node="$3"
  local srl_if="$4"
  local host_tmp="$5"
  local srl_tmp="$6"

  local srl_pid
  local host_if

  srl_pid=$(get_srl_pid "$srl_node")
  host_if=$(host_if_name "$srv" "$srv_if")

  echo "[plug-host] ${srv}:${srv_if} as ${host_if} <--> ${srl_node}:srbase:${srl_if}"

  # Defensive cleanup
  delete_if_in_host "$host_tmp"
  delete_if_in_host "$srl_tmp"
  delete_if_in_host "$host_if"
  delete_if_in_srl_srbase "$srl_node" "$srl_if"

  ip link add "$host_tmp" type veth peer name "$srl_tmp"

  # Server side stays in HOST namespace because containers use --network host
  ip link set "$host_tmp" name "$host_if"
  ip link set "$host_if" up

  # SR Linux side goes into SR Linux container, then srbase netns
  ip link set "$srl_tmp" netns "$srl_pid"
  nsenter -t "$srl_pid" -m -n ip link set "$srl_tmp" netns srbase
  nsenter -t "$srl_pid" -m -n ip netns exec srbase ip link set "$srl_tmp" name "$srl_if"
  nsenter -t "$srl_pid" -m -n ip netns exec srbase ip link set "$srl_if" up
}

config_server_frontend_and_rdma() {
  local srv="$1"
  local id="$2"

  echo "[config-host] $srv"

  local eth1_vif eth2_vif eth11_vif eth12_vif bond
  eth1_vif=$(host_if_name "$srv" eth1)
  eth2_vif=$(host_if_name "$srv" eth2)
  eth11_vif=$(host_if_name "$srv" eth11)
  eth12_vif=$(host_if_name "$srv" eth12)
  bond=$(bond_name "$id")

  local eth11_v4 eth12_v4
  local eth11_v6 eth12_v6
  local eth11_gw4 eth12_gw4
  local eth11_gw6 eth12_gw6

  case "$id" in
    1)
      eth11_v4="192.168.101.1/24"; eth11_gw4="192.168.101.254"
      eth12_v4="192.168.102.1/24"; eth12_gw4="192.168.102.254"
      eth11_v6="fd00:6500:101:1::2/64"; eth11_gw6="fd00:6500:101:1::1"
      eth12_v6="fd00:6500:201:1::2/64"; eth12_gw6="fd00:6500:201:1::1"
      ;;
    2)
      eth11_v4="192.168.111.2/24"; eth11_gw4="192.168.111.254"
      eth12_v4="192.168.112.2/24"; eth12_gw4="192.168.112.254"
      eth11_v6="fd00:6500:101:2::2/64"; eth11_gw6="fd00:6500:101:2::1"
      eth12_v6="fd00:6500:201:2::2/64"; eth12_gw6="fd00:6500:201:2::1"
      ;;
    3)
      eth11_v4="192.168.201.3/24"; eth11_gw4="192.168.201.254"
      eth12_v4="192.168.202.3/24"; eth12_gw4="192.168.202.254"
      eth11_v6="fd00:6500:101:3::3/64"; eth11_gw6="fd00:6500:101:3::1"
      eth12_v6="fd00:6500:201:3::3/64"; eth12_gw6="fd00:6500:201:3::1"
      ;;
    4)
      eth11_v4="192.168.211.4/24"; eth11_gw4="192.168.211.254"
      eth12_v4="192.168.212.4/24"; eth12_gw4="192.168.212.254"
      eth11_v6="fd00:6500:101:4::4/64"; eth11_gw6="fd00:6500:101:4::1"
      eth12_v6="fd00:6500:201:4::4/64"; eth12_gw6="fd00:6500:201:4::1"
      ;;
    *)
      echo "ERROR: unsupported server id: $id"
      exit 1
      ;;
  esac

  # Frontend bond per server, using unique host bond names b1/b2/b3/b4
  ip link add "$bond" type bond mode 802.3ad xmit_hash_policy layer3+4 2>/dev/null || true
  ip link set addr "00:c1:ab:01:01:0${id}" dev "$bond" || true

  ip link set "$eth1_vif" down || true
  ip link set "$eth2_vif" down || true
  ip link set "$eth1_vif" master "$bond"
  ip link set "$eth2_vif" master "$bond"
  ip link set "$eth1_vif" up
  ip link set "$eth2_vif" up
  ip link set "$bond" up

  # Common frontend VLAN
  ip link add link "$bond" name "${bond}.1001" type vlan id 1001 2>/dev/null || true
  ip addr add "10.10.10.${id}/24" dev "${bond}.1001" 2>/dev/null || true
  ip link set "${bond}.1001" up

  # VLAN 201 for server1/server3, VLAN 202 for server2/server4
  if [ "$id" = "1" ] || [ "$id" = "3" ]; then
    ip link add link "$bond" name "${bond}.201" type vlan id 201 2>/dev/null || true
    ip addr add "10.20.1.${id}/24" dev "${bond}.201" 2>/dev/null || true
    ip link set "${bond}.201" up
  else
    ip link add link "$bond" name "${bond}.202" type vlan id 202 2>/dev/null || true
    ip addr add "10.20.2.${id}/24" dev "${bond}.202" 2>/dev/null || true
    ip link set "${bond}.202" up
  fi

  # Backend RDMA ports stay in host namespace with unique names
  ip link set "$eth11_vif" up
  ip link set "$eth12_vif" up

  ip addr add "$eth11_v4" dev "$eth11_vif" 2>/dev/null || true
  ip addr add "$eth12_v4" dev "$eth12_vif" 2>/dev/null || true

  ip -6 addr flush dev "$eth11_vif" scope global || true
  ip -6 addr flush dev "$eth12_vif" scope global || true
  ip -6 addr add "$eth11_v6" dev "$eth11_vif"
  ip -6 addr add "$eth12_v6" dev "$eth12_vif"

  # IPv4 broad routes, same logic as before, but using host interface names
  ip route replace 192.168.0.0/16 via "$eth11_gw4" dev "$eth11_vif" metric 101 || true
  ip route replace 192.168.0.0/16 via "$eth12_gw4" dev "$eth12_vif" metric 201 || true

  # Remove stale broad IPv6 routes if present
  ip -6 route del fd00::/8 2>/dev/null || true
  ip -6 route del fd00::/8 2>/dev/null || true
  ip -6 route del fd00::/8 2>/dev/null || true
  ip -6 route del fd00::/8 2>/dev/null || true

  # Explicit IPv6 static routes, using host interface names
  case "$id" in
    1)
      ip -6 route replace fd00:6500:101:2::/64 via fd00:6500:101:1::1 dev "$eth11_vif" metric 101 || true
      ip -6 route replace fd00:6500:201:2::/64 via fd00:6500:201:1::1 dev "$eth12_vif" metric 201 || true
      ;;
    2)
      ip -6 route replace fd00:6500:101:1::/64 via fd00:6500:101:2::1 dev "$eth11_vif" metric 101 || true
      ip -6 route replace fd00:6500:201:1::/64 via fd00:6500:201:2::1 dev "$eth12_vif" metric 201 || true
      ;;
    3)
      ip -6 route replace fd00:6500:101:4::/64 via fd00:6500:101:3::1 dev "$eth11_vif" metric 101 || true
      ip -6 route replace fd00:6500:201:4::/64 via fd00:6500:201:3::1 dev "$eth12_vif" metric 201 || true
      ;;
    4)
      ip -6 route replace fd00:6500:101:3::/64 via fd00:6500:101:4::1 dev "$eth11_vif" metric 101 || true
      ip -6 route replace fd00:6500:201:3::/64 via fd00:6500:201:4::1 dev "$eth12_vif" metric 201 || true
      ;;
  esac

  ip -6 neigh flush all || true

  # RXE created directly on host-side server backend interfaces
  rdma link add "rxe_${srv}_11" type rxe netdev "$eth11_vif" 2>/dev/null || true
  rdma link add "rxe_${srv}_12" type rxe netdev "$eth12_vif" 2>/dev/null || true
}

verify_server_host() {
  local srv="$1"
  local id
  local eth1_vif eth2_vif eth11_vif eth12_vif bond

  id=$(get_server_id "$srv")
  eth1_vif=$(host_if_name "$srv" eth1)
  eth2_vif=$(host_if_name "$srv" eth2)
  eth11_vif=$(host_if_name "$srv" eth11)
  eth12_vif=$(host_if_name "$srv" eth12)
  bond=$(bond_name "$id")

  echo
  echo "========== $srv host-mode interfaces =========="
  ip -br addr show "$eth1_vif" "$eth2_vif" "$eth11_vif" "$eth12_vif" "$bond" 2>/dev/null || true
  ip -br addr show "${bond}.1001" "${bond}.201" "${bond}.202" 2>/dev/null || true

  echo
  echo "========== $srv RXE =========="
  rdma link show | grep "rxe_${srv}_" || true
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

verify_server_host server1
verify_server_host server2
verify_server_host server3
verify_server_host server4


echo
echo "[done]"
echo
echo "Host-mode note:"
echo "  server containers share the host network namespace."
echo "  So inside server1/server2/server3/server4 you will see the same interfaces and RXE devices."
echo
echo "Useful checks:"
echo "  ip -br addr | egrep 's[1-4]eth|b[1-4]'"
echo "  rdma link show"
echo
echo "Example RDMA commands:"
echo "  docker exec -it server1 ib_send_bw -d rxe_server1_11 -F --ipv6 --ipv6-addr -x 1 -R"
echo "  docker exec -it server2 ib_send_bw -d rxe_server2_11 -F --ipv6 --ipv6-addr -x 1 -R fd00:6500:101:1::2"