"""The native client for the CRIU half of the external-state experiment.

It is the same story as guests/net-counter, as an ordinary Python process
speaking HTTPS to scripts/net/server.py: log in (a session, kept by the server under
a token this process holds), open a transaction on the connection, then every
second take one step of each. If a request fails it reconnects and presents
the token. CRIU dumps this process mid-run and restores it, and the lines it
prints afterwards show what survived.

  python3 -u client.py HOST PORT CAFILE [SOURCE-IP]

SOURCE-IP, when given, is the local address the socket binds before it
connects. The VIP test (scripts/net/criu-vip.sh) gives it a floating address, so that
the connection's source address can move to another host with the process.
"""

from __future__ import annotations

import http.client
import os
import ssl
import sys
import time

HTTP_OK = 200
# Seconds between steps. Long enough that a dump taken after `start` lands
# while the connection is idle, not in the middle of a request.
INTERVAL = 3
STEPS = 40
# A dead connection must fail a call, not hang the demo.
TIMEOUT_SECONDS = 5
# Command line: program, HOST, PORT, CAFILE and optionally SOURCE-IP.
ARGS_WITHOUT_SOURCE = 4


def say(msg: str) -> None:
    """Print one plain sentence per line.

    The experiment scripts print each line under the label "prog" and read the
    words "failed", "new connection" and "refused" from it, so keep those words.
    """
    print(msg, flush=True)


def field(body: str, key: str) -> str:
    """Return the value of `key=value` in a reply body such as `n=3 conn=1`."""
    for part in body.split():
        if part.startswith(key + "="):
            return part.split("=", 1)[1]
    return "?"


class Client:
    """One HTTPS connection to the test server, and the way to open another."""

    def __init__(self, host: str, port: int, cafile: str, source_ip: str | None) -> None:
        """Remember where to connect. Nothing is opened until `connect`."""
        self.host = host
        self.port = port
        # The self-signed server certificate is the only authority this client trusts.
        self.context = ssl.create_default_context(cafile=cafile)
        # Port 0 lets the kernel choose the source port.
        self.source = (source_ip, 0) if source_ip else None
        self.conn = self._open()

    def _open(self) -> http.client.HTTPSConnection:
        return http.client.HTTPSConnection(
            self.host,
            self.port,
            context=self.context,
            timeout=TIMEOUT_SECONDS,
            source_address=self.source,
        )

    def reconnect(self) -> None:
        """Close the connection and open a new one."""
        self.conn.close()
        self.conn = self._open()

    def post(self, path: str, token: str | None = None) -> tuple[int, str]:
        """POST an empty body to `path`, with the session token if there is one."""
        headers = {"X-Token": token} if token else {}
        self.conn.request("POST", path, body=b"", headers=headers)
        response = self.conn.getresponse()
        return response.status, response.read().decode()


def run(client: Client) -> None:
    """Log in, open a transaction, and take `STEPS` steps of each."""
    _, body = client.post("/login")
    token = field(body, "token")
    _, body = client.post("/begin")
    say(
        f"started (process {os.getpid()}): logged in, token {token}, "
        f"opened transaction {field(body, 'txn')} on connection {field(body, 'conn')}",
    )
    txn_alive = True
    for i in range(1, STEPS + 1):
        try:
            _, n = client.post("/next", token)
            line = f"step {i}: session counter {field(n, 'n')}"
            if txn_alive:
                code, t = client.post("/txn-step")
                if code == HTTP_OK:
                    line += f", transaction step {field(t, 'steps')}"
                else:
                    line += f", transaction refused ({code})"
                    txn_alive = False
            say(f"{line} (connection {field(n, 'conn')})")
        except (OSError, http.client.HTTPException) as err:
            say(f"step {i}: the old connection failed: {type(err).__name__}: {err}")
            client.reconnect()
            _, n = client.post("/next", token)
            say(
                f"step {i}: opened a new connection (connection {field(n, 'conn')}) "
                f"and presented the token: session counter {field(n, 'n')}",
            )
            # The transaction was bound to the old connection: ask once.
            code, t = client.post("/txn-step")
            outcome = "carried on" if code == HTTP_OK else f"refused ({code}: {t})"
            say(f"step {i}: transaction on the new connection: {outcome}")
            txn_alive = False
        time.sleep(INTERVAL)
    say(f"finished all {STEPS} steps")


def main() -> None:
    """Parse the command line and run."""
    host, port, cafile = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    source_ip = sys.argv[ARGS_WITHOUT_SOURCE] if len(sys.argv) > ARGS_WITHOUT_SOURCE else None
    run(Client(host, port, cafile, source_ip))


if __name__ == "__main__":
    main()
