#!/usr/bin/env bash
# Phase 6, CRIU side: dump the native HTTPS client and restore it, on the same
# host and on another host of the same ISA, with each of CRIU's TCP options.
#
#   scripts/net/criu-net.sh SRC DST "DUMP-ARGS" "RESTORE-ARGS"
#
# e.g. scripts/net/criu-net.sh h1 h1 "--tcp-established" "--tcp-established"
#
# WHERE=host (default): the stateful server (scripts/net/server.py) runs on this
# machine, and the VM reaches it at 10.0.2.2 through QEMU's user-mode network.
# WHERE=vm: the server runs inside SRC, on 127.0.0.1, so the connection never
# leaves the guest kernel (only for SRC = DST).
# STEP="3/6" and TITLE="..." (set by scripts/net/criu-all.sh) name this case in the
# output. PROBE=1 samples the restored socket's kernel counters.
#
# The commands that run inside the VM (scripts/net/criu-remote.sh) print tagged lines:
#   X  a fact (dump-ok, restore-failed 1, pid 123, ...)   P  a line the client printed
#   E  a line of CRIU's own error text                      Q  a line of `ss` output
#   T  a time (seconds) for the `ss` lines that follow
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/say.sh
source scripts/net/common.sh
net_cert
src=${1:?SRC} dst=${2:?DST} dump_args=${3-} restore_args=${4-}
where=${WHERE:-host}
step=${STEP:-1/1}
title=${TITLE:-"$src to $dst, dump options '${dump_args}', restore options '${restore_args}'"}
hostsh() { "vms/$1.sh" ssh "${@:2}"; }
if [[ $where == vm ]]; then addr=127.0.0.1; else addr=10.0.2.2; fi
remote() { hostsh "$1" "sudo env SERVER=$addr PROBE=${PROBE:-} bash /mnt/shared/criu-net/remote.sh ${*:2}"; }
# Stop the in-VM server however the script ends.
trap '[[ $where == vm ]] && remote "$src" server-stop > /dev/null 2>&1 || true' EXIT
# The server's log, wherever it runs.
slog() { if [[ $where == vm ]]; then hostsh "$src" 'sudo cat /var/tmp/srv.log'; else cat "$NET_STATE/server.log"; fi; }

for h in "$src" "$dst"; do
    mkdir -p "vms/shared/$h/criu-net"
    cp scripts/net/client.py scripts/net/server.py "$NET_STATE/key.pem" "$NET_STATE/cert.pem" scripts/net/criu-remote.sh "vms/shared/$h/criu-net/"
    mv "vms/shared/$h/criu-net/criu-remote.sh" "vms/shared/$h/criu-net/remote.sh"
    remote "$h" clean
done

[[ $where == vm ]] && remote "$src" server > /dev/null
mark=$(slog | wc -l)
say_step "${step%/*}" "${step#*/}" "$title"
if [[ $where == vm ]]; then
    say_do "start the test server inside $src, then the client on $src; the client logs in, opens a transaction and takes 2 steps"
else
    say_do "start the client on $src; it logs in to the test server on this machine, opens a transaction and takes 2 steps"
fi
out=$(remote "$src" start); render "$out"

say_do "dump the client: criu dump ${dump_args:-with no TCP option}"
out=$(remote "$src" dump "$dump_args") || true
verdict=()
if has "$out" dump-failed; then
    say_got "the dump failed, so CRIU left the client running. CRIU's error lines, then the client's last line:"
    render "$out"
    verdict=("CRIU refused to dump a client with an open connection. Nothing was moved.")
else
    say_got "the dump worked, and CRIU stopped the client"
    if [[ $src != "$dst" ]]; then
        cp "vms/shared/$src/criu-net/image.tar" "vms/shared/$dst/criu-net/"
        say_next "copy the dump image from $src to $dst"
    fi
    say_do "restore the client on $dst: criu restore ${restore_args:-with no TCP option}, then watch it for 10 seconds"
    out=$(remote "$dst" restore "$restore_args")
    remote "$dst" clean
    sleep 1
    if has "$out" restore-failed; then
        say_got "the restore failed. CRIU's error lines:"
        verdict=("The restore failed, so the client was not moved.")
    else
        proc=$(fact "$out" process)
    if [[ $proc == none ]]; then who="but no client process was found"; else who="the client is running again as process ${proc%% *}"; fi
    say_got "the restore worked, $who. What it printed after the dump:"
        client_verdict "$out"
    fi
    render "$out"
fi
say_got "the test server recorded this during the case (a closing line at the end comes from this script stopping the client afterwards):"
slog | tail -n +$((mark + 1)) | squeeze | say_quote srv
printf '\n'
for v in "${verdict[@]}"; do say_line so "$v"; done
