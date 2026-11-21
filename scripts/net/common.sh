# shellcheck shell=bash
# Shared by scripts/net/criu-net.sh and scripts/net/criu-vip.sh. Source it after scripts/lib/say.sh.
#
# The commands that run inside the VM (scripts/net/criu-remote.sh) print tagged lines:
#   X  a fact (dump-ok, restore-failed 1, pid 123, ...)   P  a line the client printed
#   E  a line of CRIU's own error text                      Q  a line of `ss` output
#   T  a time (seconds) for the `ss` lines that follow

# Server log, with each run of step lines on one connection cut to its first
# and last line (the full log is in build/net/server.log).
squeeze() {
    awk '
    function flush() { if (n > 2) print "... " n - 2 " more step lines on " cur; if (n > 1) print last; n = 0 }
    /\/next|\/txn-step/ { match($0, /connection [0-9]+/); c = substr($0, RSTART, RLENGTH)
        if (c != cur) { flush(); cur = c }
        if (n == 0) print $0
        last = $0; n++; next }
    { flush(); cur = ""; print }
    END { flush() }'
}

# render TAGGED-OUTPUT: show the client, CRIU and `ss` lines with their labels.
# The X and T lines are read by the caller, not shown.
render() {
    local line
    while IFS= read -r line; do
        case $line in
        "P "*) say_line prog "${line#P }" ;;
        "E "*) say_line raw "${line#E }" ;;
        "T "*) say_line ss "--- ${line#T } s after the restore command started" ;;
        "Q "*) say_line ss "${line#Q }" ;;
        *) ;;
        esac
    done <<< "$1"
}
# fact TAGGED-OUTPUT KEY: the text after "X KEY" on the first such line, or nothing.
fact() { sed -n "s/^X $2 *//p" <<< "$1" | head -1; }
# has TAGGED-OUTPUT KEY: whether an "X KEY" line exists.
has() { grep -q "^X $2" <<< "$1"; }


# client_verdict TAGGED-OUTPUT: read what the restored client printed and set
# the array `verdict` to plain sentences about the connection, the session and
# the transaction.
client_verdict() {
    local after err
    after=$(sed -n 's/^P //p' <<< "$1")
    if grep -q 'the old connection failed' <<< "$after"; then
        err=$(sed -n 's/.*the old connection failed: \([A-Za-z]*\).*/\1/p' <<< "$after" | head -1)
        verdict=("connection:  LOST. The first request on the old connection failed with $err.")
        if grep -q 'opened a new connection' <<< "$after"; then
            verdict+=("session:     KEPT. The client logged in again with its token and the server returned the same session.")
        else
            verdict+=("session:     NOT RECOVERED. No new connection was opened within 10 seconds.")
        fi
        if grep -q 'transaction on the new connection: refused' <<< "$after"; then
            verdict+=("transaction: LOST. The transaction was tied to the old connection.")
        fi
    elif grep -q '^step [0-9]*:.*transaction step' <<< "$after"; then
        verdict=("connection:  KEPT. The client carried on with the same connection and the same TLS session.")
        verdict+=("transaction: KEPT. Its steps carried on without a gap.")
    else
        verdict=("The client printed nothing in 10 seconds, so the outcome is unknown.")
    fi
}

# summarize FILE: one line for the result block, from the "so" lines of a case:
# "connection LOST, session KEPT, transaction LOST". When the case has no such
# lines (a refused dump, a failed restore), the first sentence of its first "so" line.
summarize() {
    local l
    l=$(sed -n 's/^  so *\(connection\|session\|transaction\): *\([A-Z][A-Z ]*[A-Z]\)\..*/\1 \2/p' "$1" | paste -sd, | sed 's/,/, /g')
    [[ -n $l ]] || l=$(grep -m1 '^  so ' "$1" | sed 's/^  so *//; s/\. .*//')
    printf '%s' "$l"
}

# Where the test server keeps its certificate, key, pid and log. Everything
# here is generated, and `make clean` removes it.
NET_STATE=build/net

# net_cert: make the self-signed certificate that the test server presents, if
# it does not exist yet. The subject alternative names are the three addresses
# a client uses for the server: the host as QEMU's user-mode network shows it
# (10.0.2.2), loopback inside a VM, and h5 on the private link.
net_cert() {
    mkdir -p "$NET_STATE"
    [[ -f $NET_STATE/cert.pem ]] || openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
        -keyout "$NET_STATE/key.pem" -out "$NET_STATE/cert.pem" -subj /CN=10.0.2.2 \
        -addext "subjectAltName=IP:10.0.2.2,IP:127.0.0.1,IP:192.168.50.5" 2>/dev/null
}

# net_server_stop: stop a server left over from an earlier run, through its pid
# file. (`pkill -f` would also match the calling shell.)
net_server_stop() {
    [[ -f $NET_STATE/server.pid ]] || return 0
    kill "$(cat "$NET_STATE/server.pid")" 2>/dev/null || true
    rm -f "$NET_STATE/server.pid"
}

# net_server_start: run the test server on this machine, in the background.
net_server_start() {
    net_cert
    net_server_stop
    sleep 0.5
    python3 -I scripts/net/server.py --cert "$NET_STATE/cert.pem" --key "$NET_STATE/key.pem" \
        > "$NET_STATE/server.log" 2>&1 &
    echo $! > "$NET_STATE/server.pid"
    sleep 1
}
