#!/usr/bin/env bash
# Teleport a running Wasm guest across hosts: checkpoint on one, copy the
# capsule, restore on the next.
#
#   scripts/teleport.sh wasm-step  h1 h2 h3 h4   Phase 1: counter between step() calls
#   scripts/teleport.sh wasm-async h1 h2 h3 h4   Phase 2: mid-loop, stack via Asyncify
#   scripts/teleport.sh wasm-py    h1 h2 h3 h4   Phase 3: CPython on WASI, mid-script
#   scripts/teleport.sh wasm-net   h1 h4         Phase 6: network state (needs scripts/net/server.py on this machine)
#
# Each host sees only its own share, vms/shared/<host> = /mnt/shared. The copy
# between shares, done here on the host machine, is the "network" a capsule
# crosses. The same .wasm goes to every host; only `tc` is built per ISA.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
# shellcheck source=scripts/lib/say.sh
source "$ROOT/scripts/lib/say.sh"

payload=${1:?usage: teleport.sh wasm-step|wasm-async|wasm-py HOST...}
shift
(( $# >= 2 )) || { echo "need at least two hosts" >&2; exit 2; }

hostsh() { "$ROOT/vms/$1.sh" ssh "${@:2}"; }

tc_for() {
    case $(hostsh "$1" uname -m) in
    x86_64) echo target/release/tc ;;
    aarch64) echo target/aarch64-unknown-linux-musl/release/tc ;;
    riscv64) echo target/riscv64gc-unknown-linux-gnu/release/tc ;;
    *) echo "unknown arch on $1" >&2; exit 1 ;;
    esac
}

# Copy tc and the modules into each host's share. Precompiled .cwasm files
# are named by the module's sha256, so a stale one can never be picked up.
deploy() {
    local h=$1 share=vms/shared/$1 arch
    arch=$(hostsh "$h" uname -m)
    mkdir -p "$share/bin" "$share/build" "$share/capsules" "$share/py"
    install -m 755 "$(tc_for "$h")" "$share/bin/tc"
    rsync -a build/*.wasm "$share/build/"
    rm -f "$share/build/"*.cwasm
    cp build/*."$arch".cwasm "$share/build/" 2>/dev/null || true
    if [[ $payload == wasm-py ]]; then
        # The stdlib minus its own test suite (about two thirds of it).
        rsync -a --delete --exclude test/ --exclude idlelib/ --exclude tkinter/ \
            build/py/lib/ "$share/py/lib/"
        rsync -a --delete guests/py-counter/app/ "$share/py/app/"
    fi
}

# Pull one field out of the tool's own output, or stop: a missing line means
# the run did not do what this script expects, and it must not guess.
tcline() { # OUTPUT KIND   (KIND is a word that follows "tc: ")
    local l; l=$(grep -m1 -E "^tc: $2" <<< "$1") || return 1
    printf '%s' "$l"
}
need() { echo "teleport.sh: expected a line '$2' from tc, got none. Full output:" >&2; echo "$1" >&2; exit 1; }
# The patterns for the lines tc prints, kept in variables because bash reads a
# regular expression on the right of =~ most reliably from one.
re_ckpt='counter=([^ ]+) capsule=sha256:([0-9a-f]+) .*memory=([0-9]+KiB)'
re_ckpt2='counter=([^ ]+) capsule=sha256:([0-9a-f]+) '
re_rest='from capsule=sha256:([0-9a-f]+) written on ([^ ]+) \(([^)]+)\) counter=([^ ]+)'
re_ran='counter=([0-9]+)'
# tc prints counter=- for a program that has no counter (the Python script).
counter_text() { if [[ $1 == - ]]; then echo 'no progress counter (this program has none)'; else echo "progress counter $1"; fi; }
re_exit='exit ([0-9]+)'
# id8 turns "sha256:fb6d25e95b56" into the first 8 characters.
id8() { local x=${1#sha256:}; echo "${x:0:8}"; }

case $payload in
wasm-step)
    start=(--module /mnt/shared/build/step-counter.wasm --mode step --steps 1000)
    more=(--steps 1000) ;;
wasm-async)
    start=(--module /mnt/shared/build/async-counter.wasm --mode async)
    more=() ;;
wasm-py)
    start=(--module /mnt/shared/build/python.wasm --mode async
           --arg python.wasm --arg -u --arg /app/counter.py
           --dir /mnt/shared/py/lib::/lib --dir /mnt/shared/py/app::/app)
    more=(--dir /mnt/shared/py/lib::/lib --dir /mnt/shared/py/app::/app) ;;
wasm-net)
    # 10.0.2.2 is this machine as the VM's user-mode network sees it.
    start=(--module /mnt/shared/build/net-counter.wasm --mode async
           --arg net-counter.wasm --arg 10.0.2.2:8080)
    more=() ;;
*) echo "unknown payload $payload" >&2; exit 2 ;;
esac
module=${start[1]}

if [[ -z ${NO_HEAD-} ]]; then
    case $payload in
    wasm-step) say_head "Move a counter that is paused between function calls" \
        "Does the counter keep counting when its program moves to a host with another CPU type?" \
        "Each host runs the same WebAssembly program. Each host runs it for 1000 steps, saves its state as a capsule (a directory of files), and the capsule is copied to the next host." ;;
    wasm-async) say_head "Move a loop that is paused in the middle of its run" \
        "Does the loop carry on from the exact point where it was paused, with its variables intact, on a host with another CPU type?" \
        "The program calls checkpoint() every 250 iterations. A paused program is saved as a capsule, copied to the next host, and loaded there." ;;
    wasm-py) say_head "Move a Python script that is paused in the middle of its run" \
        "Does a Python script, running inside WebAssembly, carry on after a move with its variables intact and without restarting the interpreter?" \
        "The script calls checkpoint() after the 10th and the 20th line. A paused program is saved as a capsule, copied to the next host, and loaded there." ;;
    wasm-net) say_head "Move a program that has an open network connection" \
        "What happens to a connection, a transaction and a login session when a WebAssembly program moves to another host?" \
        "The program talks to a test server on this machine. It is paused after two steps, moved from h1 to h4, and resumed." ;;
    *) ;;
    esac
fi

hosts=("$@")
for h in "${hosts[@]}"; do deploy "$h"; rm -rf "vms/shared/$h/capsules/$payload"; done

n=${#hosts[@]}
for i in "${!hosts[@]}"; do
    h=${hosts[$i]}
    cap=/mnt/shared/capsules/$payload/cap-$i
    say_step $((i + 1)) "$n" "$(vm_desc "$h")"
    if (( i == 0 )); then
        say_do "start the program and run it until it asks to be paused, then save its state as a capsule"
        run=(/mnt/shared/bin/tc start "${start[@]}" --out "$cap")
    else
        prev=/mnt/shared/capsules/$payload/cap-$((i - 1))
        say_do "load the capsule that ${hosts[$((i - 1))]} saved, check its hashes, and continue the program from where it stopped"
        out=(); (( i < n - 1 )) && out=(--out "$cap")
        run=(/mnt/shared/bin/tc resume --module "$module" --capsule "$prev" "${more[@]}" "${out[@]}")
    fi
    # The output is captured so that the "got" lines can be written first.
    # On a failure the whole output is shown before the script stops.
    if ! res=$(hostsh "$h" "${run[@]}" 2>&1); then
        echo "$res" >&2; echo "teleport.sh: tc failed on $h" >&2; exit 1
    fi
    if (( i == 0 )); then
        c=$(tcline "$res" "checkpoint") || need "$res" "checkpoint"
        [[ $c =~ $re_ckpt ]] || need "$res" "checkpoint"
        say_got "saved capsule $(id8 "${BASH_REMATCH[2]}"): program memory ${BASH_REMATCH[3]}, $(counter_text "${BASH_REMATCH[1]}")"
    else
        r=$(tcline "$res" "restored") || need "$res" "restored"
        [[ $r =~ $re_rest ]] || need "$res" "restored"
        say_got "capsule $(id8 "${BASH_REMATCH[1]}") loaded and verified (written on ${BASH_REMATCH[2]}, ${BASH_REMATCH[3]}); $(counter_text "${BASH_REMATCH[4]}") at that point"
        if c=$(tcline "$res" "checkpoint"); then
            [[ $c =~ $re_ckpt2 ]] || need "$res" "checkpoint"
            say_got "paused again, saved capsule $(id8 "${BASH_REMATCH[2]}"), $(counter_text "${BASH_REMATCH[1]}")"
        elif d=$(tcline "$res" "ran to"); then
            [[ $d =~ $re_ran ]] || need "$res" "ran to"
            say_got "ran to the end, progress counter ${BASH_REMATCH[1]}"
        elif d=$(tcline "$res" "guest finished"); then
            [[ $d =~ $re_exit ]] || need "$res" "guest finished"
            say_got "the program finished by itself, exit code ${BASH_REMATCH[1]}"
        else
            need "$res" "checkpoint, ran to, or guest finished"
        fi
    fi
    if (( i < n - 1 )); then
        next=${hosts[$((i + 1))]}
        mkdir -p "vms/shared/$next/capsules/$payload"
        cp -r "vms/shared/$h/capsules/$payload/cap-$i" "vms/shared/$next/capsules/$payload/"
        say_next "copy the capsule from $h to $next ($(du -sh "vms/shared/$h/capsules/$payload/cap-$i" | cut -f1))"
    fi
    # What the program itself printed, then the tool's own lines.
    grep -v '^tc: ' <<< "$res" | sed -E 's/^ +//; s/^\[guest\] //' | say_quote prog || true
    grep '^tc: ' <<< "$res" | say_quote raw
done
