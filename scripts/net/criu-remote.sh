#!/usr/bin/env bash
# Runs INSIDE a VM, as root, for scripts/net/criu-net.sh. Subcommands:
#   server           run scripts/net/server.py inside this VM (loopback), log to /var/tmp/srv.log
#   server-stop      stop that server
#   clean            stop any client and delete the working directory
#   start            run scripts/net/client.py in the background and show its log
#   dump [ARGS]      criu dump it with ARGS, pack the image for the other host
#   restore [ARGS]   unpack the image, criu restore it with ARGS, show what the
#                    client printed after the dump
# For the VIP test (scripts/net/criu-vip.sh), which sets VIP, SRC_IP and BIND:
#   l2 N             give the private-link NIC the address 192.168.50.N
#   vip-add, vip-del add or remove the floating address $VIP on that NIC
#   garp             announce $VIP from this host's MAC (gratuitous ARP)
#   neigh            show which MAC this host has for $VIP
#   neigh-flush      forget the MAC this host has for $VIP
set -u
# Set by scripts/net/criu-vip.sh for the floating-IP run; empty otherwise.
VIP=${VIP:-}
D=/var/tmp/cnet
S=/mnt/shared/criu-net
# The NIC on the private link, found by its MAC (52:54:00:50:00:0N), not by a
# name that the guest chooses.
l2dev() { ip -br link | awk '$3 ~ /^52:54:00:50:00:0/ { print $1 }'; }
case $1 in
l2)
    ip addr replace "192.168.50.$2/24" dev "$(l2dev)"
    ip link set "$(l2dev)" up ;;
vip-add) ip addr add "$VIP/24" dev "$(l2dev)" ;;
vip-del) ip addr del "$VIP/24" dev "$(l2dev)" ;;
garp) python3 -I "$S/garp.py" "$(l2dev)" "$VIP" ;;
neigh-flush) ip neigh flush to "$VIP" dev "$(l2dev)" ;;
neigh) echo "$(hostname): $VIP is at $(ip neigh show "$VIP" dev "$(l2dev)" | cut -d' ' -f3-)" ;;
server)
    # Anchored patterns: an unanchored `pgrep -f` would also match this shell.
    for p in $(pgrep -f '^python3 -I /mnt/shared/criu-net/server.py'); do kill "$p"; done
    setsid python3 -I "$S/server.py" --cert "$S/cert.pem" --key "$S/key.pem" --bind "${BIND:-127.0.0.1}" \
        > /var/tmp/srv.log 2>&1 < /dev/null &
    sleep 1
    cat /var/tmp/srv.log ;;
server-stop)
    for p in $(pgrep -f '^python3 -I /mnt/shared/criu-net/server.py'); do kill "$p"; done ;;
clean)
    for p in $(pgrep -f '^python3 -u /var/tmp/cnet/client.py'); do kill "$p"; done
    rm -rf "$D" ;;
start)
    mkdir -p "$D"
    install -m 644 "$S/client.py" "$S/cert.pem" "$D/"
    cd "$D" || exit 1
    # setsid: its own session, so CRIU needs no terminal. stdin, stdout and
    # stderr are files, which CRIU can dump.
    setsid python3 -u "$D/client.py" "${SERVER:-10.0.2.2}" 8443 "$D/cert.pem" ${SRC_IP:+"$SRC_IP"} > "$D/client.log" 2>&1 < /dev/null &
    echo $! > "$D/pid"
    # Wait for step 2, so the dump that follows lands in the 3 s the client
    # then sleeps: the connection is idle, with no request in flight.
    until grep -q '^step 2:' "$D/client.log"; do sleep 0.2; done
    echo "X pid $(cat "$D/pid")"
    sed 's/^/P /' "$D/client.log" ;;
dump)
    shift
    mkdir -p "$D/img"
    if criu dump -t "$(cat "$D/pid")" -D "$D/img" -o dump.log -v2 "$@"; then
        echo "X dump-ok"
    else
        echo "X dump-failed $?"
        grep -E 'Error|error' "$D/img/dump.log" | head -4 | sed 's/^/E /'
        sleep 2
        echo "X still-running"
        tail -1 "$D/client.log" | sed 's/^/P /'
    fi
    wc -l < "$D/client.log" > "$D/lines"
    # A failed dump leaves the client running and nothing to restore.
    [[ -s "$D/img/core-$(cat "$D/pid").img" ]] || exit 3
    tar -C /var/tmp -cf "$S/image.tar" cnet ;;
restore)
    shift
    rm -rf "$D"
    tar --warning=no-timestamp -C /var/tmp -xf "$S/image.tar"
    if [[ -n ${PROBE:-} ]]; then
        # Sample the restored socket's kernel counters while the client runs.
        # segs_in and data_segs_in count what the guest kernel received.
        ( at=0
          for t in 1 3 6; do
              sleep "$t"
              at=$((at + t))
              echo "T $at"
              ss -tin dport = :8443 | tail -n +2 | tr -s '\t ' ' ' | cut -c1-200 | sed 's/^/Q /'
          done > "$D/probe.txt" ) &
    fi
    if criu restore -D "$D/img" -d -o restore.log -v2 "$@"; then
        echo "X restore-ok"
    else
        echo "X restore-failed $?"
        grep -E 'Error|error' "$D/img/restore.log" | head -4 | sed 's/^/E /'
    fi
    sleep 10
    # What the client printed after the dump.
    tail -n +$(($(cat "$D/lines") + 1)) "$D/client.log" | sed 's/^/P /'
    [[ -f "$D/probe.txt" ]] && cat "$D/probe.txt"
    echo "X process $(pgrep -a -f '^python3 -u /var/tmp/cnet/client.py' || echo none)" ;;
*)
    echo "usage: remote.sh l2|vip-add|vip-del|garp|neigh|neigh-flush|server|server-stop|clean|start|dump|restore" >&2
    exit 2 ;;
esac
