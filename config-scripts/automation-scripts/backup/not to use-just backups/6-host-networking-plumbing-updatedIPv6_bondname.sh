#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Host-network server plumbing for EDA/CX AI backend lab
#
# Server containers run with:
#   --network host
#
# Server-facing interfaces live in the HOST namespace:
#   server1: s1eth1/s1eth2/s1eth11/s1eth12
#   server2: s2eth1/s2eth2/s2eth11/s2eth12
#   server3: s3eth1/s3eth2/s3eth11/s3eth12
#   server4: s4eth1/s4eth2/s4eth11/s4eth12
#
# Frontend:
#   bond1/bond2/bond3/bond4 = Linux bonds
#   bond*.1001              = common frontend VLAN 1001, 10.10.10.0/24
#
# Backend:
#   s*eth11 = rail1 path, IPv6 fd00:100:101:X::/64
#   s*eth12 = rail2 path, IPv6 fd00:100:201:X::/64
#
# RDMA:
#   RXE devices are created directly on s*eth11 and s*eth12
# ============================================================

MTU="${MTU:-1500}"

LEAF1="${LEAF1:-leaf1}"
LEAF2="${LEAF2:-leaf2}"
LEAF3="${LEAF3:-leaf3}"
LEAF4="${LEAF4:-leaf4}"
RAIL1="${RAIL1:-rail1}"
RAIL2="${RAIL2:-rail2}"

log() {
  echo "[$1] ${*:2}"
}

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: run as root"
    exit 1
  fi
}

need_cmds() {
  for c in ip docker nsenter modprobe rdma; do
    command -v "$c" >/dev/null 2>&1 || {
      echo "ERROR: missing command: $c"
      exit 1
    }
  done
}

node_pid() {
  local node="$1"
  docker inspect -f '{{.State.Pid}}' "$node"
}

srl_exec() {
  local node="$1"
  shift

  local pid
  pid="$(node_pid "$node")"

  nsenter -t "$pid" -m ip netns exec srbase "$@"
}

delete_srl_if() {
  local node="$1"
  local ifname="$2"

  srl_exec "$node" ip link delete "$ifname" 2>/dev/null || true
}

delete_if() {
  local ifname="$1"
  ip link delete "$ifname" 2>/dev/null || true
}

delete_vrf() {
  local vrf="$1"
  ip link delete "$vrf" 2>/dev/null || true
}

cleanup_rdma() {
  log cleanup "deleting RXE devices..."

  rdma link show 2>/dev/null \
    | awk '/rxe_server/ {split($2,a,"/"); print a[1]}' \
    | while read -r dev; do
        [[ -n "$dev" ]] && rdma link delete "$dev" 2>/dev/null || true
      done
}

cleanup_host_links() {
  log cleanup "deleting host-side server interfaces, bonds, VLANs..."

  for i in \
    s1eth1 s1eth2 s1eth11 s1eth12 \
    s2eth1 s2eth2 s2eth11 s2eth12 \
    s3eth1 s3eth2 s3eth11 s3eth12 \
    s4eth1 s4eth2 s4eth11 s4eth12 \
    bond1.1001 bond1.201 bond1.202 bond1 \
    bond2.1001 bond2.201 bond2.202 bond2 \
    bond3.1001 bond3.201 bond3.202 bond3 \
    bond4.1001 bond4.201 bond4.202 bond4; do
    delete_if "$i"
  done
}

cleanup_vrfs() {
  log cleanup "deleting Linux VRFs..."

  for vrf in vrf-s1 vrf-s2 vrf-s3 vrf-s4; do
    delete_vrf "$vrf"
  done
}

cleanup_srl_links() {
  log cleanup "deleting old SR Linux srbase interfaces..."

  delete_srl_if "$LEAF1" e1-1
  delete_srl_if "$LEAF1" e1-2

  delete_srl_if "$LEAF2" e1-1
  delete_srl_if "$LEAF2" e1-2

  delete_srl_if "$LEAF3" e1-1
  delete_srl_if "$LEAF3" e1-2

  delete_srl_if "$LEAF4" e1-1
  delete_srl_if "$LEAF4" e1-2

  delete_srl_if "$RAIL1" e1-1
  delete_srl_if "$RAIL1" e1-2
  delete_srl_if "$RAIL1" e1-3
  delete_srl_if "$RAIL1" e1-4

  delete_srl_if "$RAIL2" e1-1
  delete_srl_if "$RAIL2" e1-2
  delete_srl_if "$RAIL2" e1-3
  delete_srl_if "$RAIL2" e1-4
}

plug_host_to_srl() {
  local label="$1"
  local host_if="$2"
  local srl_node="$3"
  local srl_if="$4"

  log plug-host "$label as $host_if <--> $srl_node:srbase:$srl_if"

  delete_if "$host_if"
  delete_srl_if "$srl_node" "$srl_if"

  local peer="tmp-${host_if}"

  ip link add "$host_if" type veth peer name "$peer"

  ip link set "$host_if" mtu "$MTU"
  ip link set "$host_if" up

  local pid
  pid="$(node_pid "$srl_node")"

  ip link set "$peer" netns "$pid"

  nsenter -t "$pid" -n ip link set "$peer" down
  nsenter -t "$pid" -n ip link set "$peer" name "$srl_if"
  nsenter -t "$pid" -n ip link set "$srl_if" mtu "$MTU"

  nsenter -t "$pid" -m bash -lc "ip link set '$srl_if' netns srbase"

  srl_exec "$srl_node" ip link set "$srl_if" up
}

create_vrf() {
  local vrf="$1"
  local table="$2"

  ip link add "$vrf" type vrf table "$table"
  ip link set "$vrf" up
}

create_bond() {
  local bond="$1"
  local mac="$2"
  local slave1="$3"
  local slave2="$4"

  log bond-create "$bond using $slave1 $slave2"

  modprobe bonding || true

  ip link add "$bond" type bond mode 802.3ad xmit_hash_policy layer3+4
  ip link set dev "$bond" address "$mac"

  ip link set "$slave1" down || true
  ip link set "$slave2" down || true

  ip link set "$slave1" master "$bond"
  ip link set "$slave2" master "$bond"

  ip link set "$slave1" up
  ip link set "$slave2" up
  ip link set "$bond" up

  sleep 1

  echo "[bond-debug] $bond"
  cat "/proc/net/bonding/$bond" || true
}

config_server() {
  local id="$1"

  local vrf table bond mac
  local fe_vlan extra_vlan
  local fe_ip extra_ip
  local eth1 eth2 eth11 eth12
  local eth11_v6 eth12_v6
  local eth11_gw6 eth12_gw6

  case "$id" in
    1)
      vrf="vrf-s1"; table="101"; bond="bond1"; mac="00:c1:ab:01:01:01"
      eth1="s1eth1"; eth2="s1eth2"; eth11="s1eth11"; eth12="s1eth12"
      fe_vlan="1001"; fe_ip="10.10.10.1/24"
      extra_vlan="201"; extra_ip="10.20.1.1/24"
      eth11_v6="fd00:100:101:1::2/64"; eth11_gw6="fd00:100:101:1::1"
      eth12_v6="fd00:100:201:1::2/64"; eth12_gw6="fd00:100:201:1::1"
      ;;
    2)
      vrf="vrf-s2"; table="102"; bond="bond2"; mac="00:c1:ab:01:01:02"
      eth1="s2eth1"; eth2="s2eth2"; eth11="s2eth11"; eth12="s2eth12"
      fe_vlan="1001"; fe_ip="10.10.10.2/24"
      extra_vlan="202"; extra_ip="10.20.2.2/24"
      eth11_v6="fd00:100:101:2::2/64"; eth11_gw6="fd00:100:101:2::1"
      eth12_v6="fd00:100:201:2::2/64"; eth12_gw6="fd00:100:201:2::1"
      ;;
    3)
      vrf="vrf-s3"; table="103"; bond="bond3"; mac="00:c1:ab:01:01:03"
      eth1="s3eth1"; eth2="s3eth2"; eth11="s3eth11"; eth12="s3eth12"
      fe_vlan="1001"; fe_ip="10.10.10.3/24"
      extra_vlan="201"; extra_ip="10.20.1.3/24"
      eth11_v6="fd00:100:101:3::3/64"; eth11_gw6="fd00:100:101:3::1"
      eth12_v6="fd00:100:201:3::3/64"; eth12_gw6="fd00:100:201:3::1"
      ;;
    4)
      vrf="vrf-s4"; table="104"; bond="bond4"; mac="00:c1:ab:01:01:04"
      eth1="s4eth1"; eth2="s4eth2"; eth11="s4eth11"; eth12="s4eth12"
      fe_vlan="1001"; fe_ip="10.10.10.4/24"
      extra_vlan="202"; extra_ip="10.20.2.4/24"
      eth11_v6="fd00:100:101:4::4/64"; eth11_gw6="fd00:100:101:4::1"
      eth12_v6="fd00:100:201:4::4/64"; eth12_gw6="fd00:100:201:4::1"
      ;;
    *)
      echo "ERROR: unsupported server id $id"
      exit 1
      ;;
  esac

  log config-host-vrf "server$id"

  create_vrf "$vrf" "$table"
  create_bond "$bond" "$mac" "$eth1" "$eth2"

  # Frontend VLANs
  ip link add link "$bond" name "${bond}.${fe_vlan}" type vlan id "$fe_vlan"
  ip link add link "$bond" name "${bond}.${extra_vlan}" type vlan id "$extra_vlan"

  ip link set "${bond}.${fe_vlan}" master "$vrf"
  ip link set "${bond}.${extra_vlan}" master "$vrf"

  ip link set "${bond}.${fe_vlan}" up
  ip link set "${bond}.${extra_vlan}" up

  ip addr add "$fe_ip" dev "${bond}.${fe_vlan}"
  ip addr add "$extra_ip" dev "${bond}.${extra_vlan}"

  # Backend rail interfaces go directly into the server VRF
  ip link set "$eth11" master "$vrf"
  ip link set "$eth12" master "$vrf"

  ip link set "$eth11" up
  ip link set "$eth12" up

  ip -6 addr flush dev "$eth11" || true
  ip -6 addr flush dev "$eth12" || true

  ip -6 addr add "$eth11_v6" dev "$eth11" nodad
  ip -6 addr add "$eth12_v6" dev "$eth12" nodad

  # Static IPv6 routes between paired servers through rails.
  # server1 <-> server2 in rail VRF nvidia
  # server3 <-> server4 in rail VRF amd
  # Static IPv6 routes between paired servers through rails.
  # server1 <-> server2 in rail VRF nvidia
  # server3 <-> server4 in rail VRF amd
  case "$id" in
    1)
      ip -6 route replace table "$table" fd00:100:101:2::/64 via fd00:100:101:1::1 dev "$eth11" metric 101 onlink
      ip -6 route replace table "$table" fd00:100:201:2::/64 via fd00:100:201:1::1 dev "$eth12" metric 201 onlink
      ;;
    2)
      ip -6 route replace table "$table" fd00:100:101:1::/64 via fd00:100:101:2::1 dev "$eth11" metric 101 onlink
      ip -6 route replace table "$table" fd00:100:201:1::/64 via fd00:100:201:2::1 dev "$eth12" metric 201 onlink
      ;;
    3)
      ip -6 route replace table "$table" fd00:100:101:4::/64 via fd00:100:101:3::1 dev "$eth11" metric 101 onlink
      ip -6 route replace table "$table" fd00:100:201:4::/64 via fd00:100:201:3::1 dev "$eth12" metric 201 onlink
      ;;
    4)
      ip -6 route replace table "$table" fd00:100:101:3::/64 via fd00:100:101:4::1 dev "$eth11" metric 101 onlink
      ip -6 route replace table "$table" fd00:100:201:3::/64 via fd00:100:201:4::1 dev "$eth12" metric 201 onlink
      ;;
  esac
}

create_rxe() {
  log rdma "loading rdma_rxe module..."
  modprobe rdma_rxe

  log rdma "creating RXE devices..."

  rdma link add rxe_server1_11 type rxe netdev s1eth11 2>/dev/null || true
  rdma link add rxe_server1_12 type rxe netdev s1eth12 2>/dev/null || true

  rdma link add rxe_server2_11 type rxe netdev s2eth11 2>/dev/null || true
  rdma link add rxe_server2_12 type rxe netdev s2eth12 2>/dev/null || true

  rdma link add rxe_server3_11 type rxe netdev s3eth11 2>/dev/null || true
  rdma link add rxe_server3_12 type rxe netdev s3eth12 2>/dev/null || true

  rdma link add rxe_server4_11 type rxe netdev s4eth11 2>/dev/null || true
  rdma link add rxe_server4_12 type rxe netdev s4eth12 2>/dev/null || true

  rdma link show
}

print_summary() {
  echo
  echo "============================================================"
  echo "Host-side interfaces"
  echo "============================================================"
  ip -br link show \
    s1eth1 s1eth2 s1eth11 s1eth12 \
    s2eth1 s2eth2 s2eth11 s2eth12 \
    s3eth1 s3eth2 s3eth11 s3eth12 \
    s4eth1 s4eth2 s4eth11 s4eth12 2>/dev/null || true

  echo
  echo "============================================================"
  echo "Frontend IPv4"
  echo "============================================================"
  for i in bond1.1001 bond2.1001 bond3.1001 bond4.1001 bond1.201 bond2.202 bond3.201 bond4.202; do
    ip -br addr show dev "$i" 2>/dev/null || true
  done

  echo
  echo "============================================================"
  echo "Backend IPv6"
  echo "============================================================"
  for i in s1eth11 s1eth12 s2eth11 s2eth12 s3eth11 s3eth12 s4eth11 s4eth12; do
    ip -br -6 addr show dev "$i" 2>/dev/null || true
  done

  echo
  echo "============================================================"
  echo "IPv6 route checks"
  echo "============================================================"
  ip vrf exec vrf-s1 ip -6 route get fd00:100:101:2::2 2>/dev/null || true
  ip vrf exec vrf-s2 ip -6 route get fd00:100:101:1::2 2>/dev/null || true
  ip vrf exec vrf-s3 ip -6 route get fd00:100:101:4::4 2>/dev/null || true
  ip vrf exec vrf-s4 ip -6 route get fd00:100:101:3::3 2>/dev/null || true

  echo
  echo "============================================================"
  echo "RDMA"
  echo "============================================================"
  rdma link show 2>/dev/null || true

  echo
  echo "============================================================"
  echo "Test commands"
  echo "============================================================"
  echo "Frontend ping:"
  echo "  sping s1 s2"
  echo "  sping s1 s2 count 20"
  echo
  echo "Frontend iperf UDP:"
  echo "  siperf s1 s2 rate 100M time 30"
  echo
  echo "Backend IPv6 rail1:"
  echo "  ip vrf exec vrf-s1 ping6 -I s1eth11 -c 3 fd00:100:101:1::1"
  echo "  ip vrf exec vrf-s1 ping6 -I s1eth11 -c 3 fd00:100:101:2::2"
  echo
  echo "Backend IPv6 rail2:"
  echo "  ip vrf exec vrf-s1 ping6 -I s1eth12 -c 3 fd00:100:201:1::1"
  echo "  ip vrf exec vrf-s1 ping6 -I s1eth12 -c 3 fd00:100:201:2::2"
  echo
  echo "RDMA example:"
  echo "  docker exec -it server1 ib_send_bw -d rxe_server1_11 -F --ipv6 --ipv6-addr -x 1 -R"
  echo "  docker exec -it server2 ib_send_bw -d rxe_server2_11 -F --ipv6 --ipv6-addr -x 1 -R fd00:100:101:1::2"
}

main() {
  need_root
  need_cmds

  cleanup_rdma
  cleanup_host_links
  cleanup_vrfs
  cleanup_srl_links

  # Frontend server-to-leaf links
  plug_host_to_srl "server1:eth1"  s1eth1  "$LEAF1" e1-1
  plug_host_to_srl "server1:eth2"  s1eth2  "$LEAF2" e1-1

  plug_host_to_srl "server2:eth1"  s2eth1  "$LEAF1" e1-2
  plug_host_to_srl "server2:eth2"  s2eth2  "$LEAF2" e1-2

  plug_host_to_srl "server3:eth1"  s3eth1  "$LEAF3" e1-1
  plug_host_to_srl "server3:eth2"  s3eth2  "$LEAF4" e1-1

  plug_host_to_srl "server4:eth1"  s4eth1  "$LEAF3" e1-2
  plug_host_to_srl "server4:eth2"  s4eth2  "$LEAF4" e1-2

  # Backend server-to-rail links
  plug_host_to_srl "server1:eth11" s1eth11 "$RAIL1" e1-1
  plug_host_to_srl "server1:eth12" s1eth12 "$RAIL2" e1-1

  plug_host_to_srl "server2:eth11" s2eth11 "$RAIL1" e1-2
  plug_host_to_srl "server2:eth12" s2eth12 "$RAIL2" e1-2

  plug_host_to_srl "server3:eth11" s3eth11 "$RAIL1" e1-3
  plug_host_to_srl "server3:eth12" s3eth12 "$RAIL2" e1-3

  plug_host_to_srl "server4:eth11" s4eth11 "$RAIL1" e1-4
  plug_host_to_srl "server4:eth12" s4eth12 "$RAIL2" e1-4

  config_server 1
  config_server 2
  config_server 3
  config_server 4

  create_rxe

  print_summary
}

main "$@"
