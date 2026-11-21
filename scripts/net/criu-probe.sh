#!/usr/bin/env bash
# Phase 6: run 3 of scripts/criu/all.sh (--tcp-established, server on this machine)
# again, and print the guest kernel's counters for the restored socket.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/say.sh
source scripts/net/common.sh
net_server_start
tmp=$(mktemp)
trap 'net_server_stop; rm -f "$tmp"' EXIT
say_head "Look inside the restored TCP socket, in the case where its replies never arrive" \
    "After CRIU restores a client with --tcp-established, does the guest kernel's TCP socket still look healthy while the client's requests time out?" \
    "The same case as run 3 of 'make criu-net'. While the restored client runs, the guest samples the socket with 'ss -tin' after 1, 4 and 10 seconds. ss prints the kernel's own counters for the connection, for example how many bytes it has acknowledged and how many data segments it has received."
STEP="1/1" TITLE="same host, --tcp-established, server on this machine (with the probe)" \
    WHERE=host PROBE=1 scripts/net/criu-net.sh h1 h1 "--tcp-established" "--tcp-established" | tee "$tmp"
say_result "DONE (1 case run)" "$(summarize "$tmp")" \
    "Read the 'ss' lines above: the socket state, bytes_acked, bytes_received and data_segs_in are the kernel's counters."
