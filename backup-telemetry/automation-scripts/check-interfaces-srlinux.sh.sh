NS="eda-system"
NODE="leaf1"
CONTAINER="leaf1"

POD=$(kubectl -n "$NS" get pod --no-headers | awk -v n="cx-eda--${NODE}-sim" '$1 ~ n {print $1; exit}')

CID=$(kubectl -n "$NS" get pod "$POD" \
  -o jsonpath="{.status.containerStatuses[?(@.name=='$CONTAINER')].containerID}" \
  | sed 's#containerd://##')

SHORTCID=${CID:0:12}

PID=$(grep -Rsl "$CID\|$SHORTCID" /proc/*/cgroup 2>/dev/null \
  | awk -F/ '{print $3}' | head -1)

echo "POD=$POD"
echo "PID=$PID"
nsenter -t "$PID" -m -n ip netns exec srbase ip -br link | egrep 'e1-|eth0|mgmt'