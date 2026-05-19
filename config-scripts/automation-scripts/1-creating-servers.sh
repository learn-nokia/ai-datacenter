for s in server1 server2 server3 server4; do
  docker rm -f "$s" 2>/dev/null || true
  docker run -dit \
    --name "$s" \
    --privileged \
    --network host \
    -v /dev/infiniband:/dev/infiniband \
    ghcr.io/mfzhsn/network-multitool-roce:0.2 \
    sleep infinity
done

docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | egrep 'server|NAMES'
