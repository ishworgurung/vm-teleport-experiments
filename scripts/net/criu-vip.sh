#!/usr/bin/env bash
# Phase 6, CRIU side, with a floating IP (VIP): move a client with an open TLS
# connection from h1 to h4 and keep the connection, with no reconnection.
#
#   make up-vip                        (once: boots h1, h4 and h5 with a private link)
#   scripts/net/criu-vip.sh all | MODE
#
# MODE is one of:
#   move     the client binds the VIP; after the dump the VIP moves h1 -> h4 and
#            h4 announces it (gratuitous ARP); then the client is restored
#   nomove   control: the client binds h1's own address, which stays on h1
#   nogarp   control: as move, but h4 does not announce the VIP
# `all` runs the three modes and prints one result.
#
# The three VMs share a private Ethernet segment (192.168.50.0/24, see
# vms/common.sh). h5 runs the server, so that the server is a different
# machine from both hosts of the move. The VMs' other NIC (QEMU user-mode
# network) is not used.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/say.sh
source scripts/net/common.sh
net_cert
mode=${1:?usage: scripts/net/criu-vip.sh all|move|nomove|nogarp}
VIP=192.168.50.100 SERVER=192.168.50.5

if [[ $mode == all ]]; then
    say_head "Keep an open network connection across hosts with a floating IP" \
        "Can CRIU move a client from h1 to h4 and keep its TCP connection, if the client's address moves with it?" \
        "h1, h4 and h5 share a private network link. The client's address is a floating IP (an address that an operator can move from one host to another). h5 runs the server. After the dump, the floating IP moves from h1 to h4, and h4 announces it (a gratuitous ARP: a message that tells every machine on the link which network card now owns the address)."
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    modes=(move nomove nogarp); declare -a summaries
    for i in 0 1 2; do
        STEP="$((i + 1))/3" scripts/net/criu-vip.sh "${modes[i]}" | tee "$tmp/$i"
        summaries[i]=$(summarize "$tmp/$i")
    done
    say_result "DONE (3 cases run)" \
        "1. move:   ${summaries[0]}" \
        "2. nomove: ${summaries[1]}" \
        "3. nogarp: ${summaries[2]}"
    exit 0
fi

case $mode in
move) title="the floating IP moves with the client, and h4 announces it" ;;
nomove) title="control: the client uses h1's own address, so nothing moves with it" ;;
nogarp) title="control: the floating IP moves, but h4 does not announce it" ;;
*) echo "unknown mode $mode" >&2; exit 2 ;;
esac
if [[ $mode == nomove ]]; then SRC_IP=192.168.50.1; else SRC_IP=$VIP; fi
step=${STEP:-1/1}

hostsh() { "vms/$1.sh" ssh "${@:2}"; }
remote() {
    hostsh "$1" "sudo env VIP=$VIP SRC_IP=$SRC_IP BIND=$SERVER SERVER=$SERVER bash /mnt/shared/criu-net/remote.sh ${*:2}"
}
slog() { hostsh h5 'sudo cat /var/tmp/srv.log'; }
# Which host owns a network card, from the last byte of its MAC address.
card_owner() { case ${1##*:} in 01) echo h1 ;; 04) echo h4 ;; 05) echo h5 ;; *) echo "an unknown card" ;; esac; }
# h5's table entry for the floating IP: show it, and say which host it points to.
arp_of_h5() { # WHEN
    local line mac
    line=$(remote h5 neigh); say_line raw "$line"
    mac=$(sed -n 's/.* is at \([0-9a-f:]*\).*/\1/p' <<< "$line")
    say_got "$1, h5 sends frames for $VIP to the network card of $(card_owner "$mac")"
}
trap 'remote h5 server-stop >/dev/null 2>&1 || true; remote h1 vip-del >/dev/null 2>&1 || true; remote h4 vip-del >/dev/null 2>&1 || true' EXIT

for h in h1 h4 h5; do
    mkdir -p "vms/shared/$h/criu-net"
    cp scripts/net/client.py scripts/net/server.py "$NET_STATE/key.pem" "$NET_STATE/cert.pem" scripts/net/garp.py "vms/shared/$h/criu-net/"
    cp scripts/net/criu-remote.sh "vms/shared/$h/criu-net/remote.sh"
done
for n in 1 4 5; do remote "h$n" l2 "$n"; done
# A VIP left by an earlier run would make `vip-add` fail below.
for h in h1 h4; do remote "$h" vip-del 2>/dev/null || true; remote "$h" clean; done
# An earlier run leaves h5's table entry for the VIP behind, which would hide
# the effect of the announcement in this run.
remote h5 neigh-flush

say_step "${step%/*}" "${step#*/}" "mode $mode: $title"
say_do "start the test server on h5, on the private link (192.168.50.5)"
remote h5 server > /dev/null
mark=$(slog | wc -l)
if [[ $mode != nomove ]]; then
    say_do "give h1 the floating IP $VIP"
    remote h1 vip-add
    say_line raw "$(hostsh h1 "ip -br addr show | grep 192.168.50" | tr -s ' ')"
fi
say_do "start the client on h1, bound to $SRC_IP; it logs in, opens a transaction and takes 2 steps"
out=$(remote h1 start); render "$out"
[[ $mode == nomove ]] || arp_of_h5 "before the move"

say_do "dump the client on h1: criu dump --tcp-established"
out=$(remote h1 dump --tcp-established) || true
render "$out"
has "$out" dump-ok || { say_result "UNEXPECTED" "the dump failed"; exit 1; }
say_got "the dump worked, and CRIU stopped the client"
cp "vms/shared/h1/criu-net/image.tar" "vms/shared/h4/criu-net/"
say_next "copy the dump image from h1 to h4"

if [[ $mode != nomove ]]; then
    say_do "move the floating IP: h1 gives it up, h4 takes it"
    remote h1 vip-del
    remote h4 vip-add
    if [[ $mode == move ]]; then
        say_do "h4 announces the floating IP to everyone on the link"
        say_line raw "$(remote h4 garp)"
    else
        say_got "h4 does not announce the floating IP"
    fi
    arp_of_h5 "after the move"
fi

say_do "restore the client on h4: criu restore --tcp-established, then watch it for 10 seconds"
verdict=()
out=$(remote h4 restore --tcp-established)
remote h4 clean
sleep 1
if has "$out" restore-failed; then
    say_got "the restore failed. CRIU's error lines:"
    reason=$(sed -n 's/^E .*Error (soccr.*): //p' <<< "$out" | head -1)
    verdict=("The restore failed: ${reason:-see the CRIU lines above}. The client was not moved.")
else
    proc=$(fact "$out" process)
    if [[ $proc == none ]]; then who="but no client process was found"; else who="the client is running again on h4 as process ${proc%% *}"; fi
    say_got "the restore worked, $who. What it printed after the dump:"
    client_verdict "$out"
fi
render "$out"
say_got "the test server recorded this during the case (a closing line at the end comes from this script stopping the client afterwards):"
slog | tail -n +$((mark + 1)) | say_quote srv
printf '\n'
for v in "${verdict[@]}"; do say_line so "$v"; done
