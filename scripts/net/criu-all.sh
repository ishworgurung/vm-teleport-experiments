#!/usr/bin/env bash
# Phase 6, CRIU side: every scenario, one after another. Needs the VMs up.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/say.sh
source scripts/net/common.sh
net_server_start
tmp=$(mktemp -d)
trap 'net_server_stop; rm -rf "$tmp"' EXIT

say_head "Move a program that has an open HTTPS connection, with CRIU" \
    "Can CRIU keep the connection, the transaction and the login session when it moves a client to the same host or to another host?" \
    "A Python client logs in to a test server, opens a transaction on its connection and takes steps. CRIU dumps it, then restores it, under each of its TCP options. 'Same ISA' means both hosts are x86-64."
total=6
n=0
declare -a titles summaries
run() { # TITLE WHERE SRC DST DUMP-ARGS RESTORE-ARGS
    n=$((n + 1))
    titles[n]=$1
    STEP="$n/$total" TITLE="$1" WHERE=$2 scripts/net/criu-net.sh "$3" "$4" "$5" "$6" | tee "$tmp/$n"
    summaries[n]=$(summarize "$tmp/$n")
}
run "same host, no TCP option, server on this machine" host h1 h1 "" ""
run "same host, --tcp-close, server on this machine" host h1 h1 "--tcp-close" "--tcp-close"
run "same host, --tcp-established, server on this machine" host h1 h1 "--tcp-established" "--tcp-established"
run "same host, --tcp-established, server inside the VM" vm h1 h1 "--tcp-established" "--tcp-established"
run "other host (h1 to h4), --tcp-established, server on this machine" host h1 h4 "--tcp-established" "--tcp-established"
run "other host (h1 to h4), --tcp-close, server on this machine" host h1 h4 "--tcp-close" "--tcp-close"

lines=()
for i in $(seq "$total"); do lines+=("$i. ${titles[i]}: ${summaries[i]}"); done
say_result "DONE ($total cases run)" "${lines[@]}"
