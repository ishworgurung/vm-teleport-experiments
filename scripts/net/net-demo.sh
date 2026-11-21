#!/usr/bin/env bash
# Phase 6, Wasm side: teleport the net-counter guest h1 -> h4 while a stateful
# server runs on this machine, then show what the SERVER saw.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/say.sh
source scripts/net/common.sh
net_server_start
tmp=$(mktemp)
trap 'net_server_stop; rm -f "$tmp"' EXIT
scripts/teleport.sh wasm-net h1 h4 | tee "$tmp"
sleep 1
say_section "The test server's own log (build/net/server.log):"
grep -v listening build/net/server.log | say_quote srv
# The guest prints one summary line. Anything else means the run did not do
# what this script expects, and it must not claim a finding.
want="summary: the old connection handle no longer works; the token reaches the session; the transaction is gone"
if ! grep -q "^  prog  $want\$" "$tmp"; then
    say_result "UNEXPECTED" "The guest's summary line was not: $want"
    exit 1
fi
say_result "FINDING" \
    "connection:  LOST. After the move the old connection handle failed with error number 9, so the program had to open a new connection." \
    "session:     KEPT. The program held its token in memory. It presented the token on the new connection, and the server returned the same session." \
    "transaction: LOST. The server rolled the transaction back when the old connection closed, and the new connection has none."
