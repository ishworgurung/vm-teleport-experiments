"""A small stateful server for the external-state experiment.

It keeps two kinds of state, so the experiment can tell them apart:

  session      keyed by a token that the client holds. Any connection that
               presents the token reaches the same session. This is the
               shape of a login session, a cursor id or a job id.
  transaction  bound to ONE TCP connection. It lives as long as that
               connection and is rolled back when the connection closes.
               This is the shape of a database transaction or an RPC stream.

Endpoints (all POST, HTTP/1.1 keep-alive, bodies are `key=value` text):

  /login      create a session, reply `token=<hex>`
  /next       header X-Token; add 1 to that session, reply `n=<count>`
  /begin      open a transaction on this connection, reply `txn=<id>`
  /txn-step   add 1 to this connection's transaction, or 409 if it has none

It serves plain HTTP on --http and HTTPS (TLS, a self-signed certificate on
--https) with the same handler. Every event is logged with the connection
number, so the demo can show what the SERVER saw. Only the standard library.
"""

import argparse
import contextlib
import itertools
import secrets
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SESSIONS: dict[str, int] = {}
LOCK = threading.Lock()
CONN_IDS = itertools.count(1)


HTTP_OK = 200
HTTP_NOT_FOUND = 404
HTTP_CONFLICT = 409


def log(msg: str) -> None:
    """Print one event line, flushed so a reader of the log sees it at once."""
    print(msg, flush=True)


class Handler(BaseHTTPRequestHandler):
    """Serve one connection. Its transaction lives on this object and ends with the connection."""

    # HTTP/1.1 keeps the connection open between requests: required, because
    # the transaction is bound to the connection.
    protocol_version = "HTTP/1.1"

    def setup(self) -> None:
        """Run when a connection opens: number it and note that it has no transaction yet."""
        super().setup()
        self.conn_id = next(CONN_IDS)
        self.txn_id: str | None = None
        self.txn_steps = 0
        log(f"connection {self.conn_id} opened, from {self.client_address[0]}")

    def finish(self) -> None:
        """Run when the connection ends (closed, reset or timed out): roll back its transaction."""
        if self.txn_id is not None:
            log(
                f"connection {self.conn_id} closed: transaction {self.txn_id} "
                f"rolled back after {self.txn_steps} steps",
            )
        else:
            log(f"connection {self.conn_id} closed")
        with contextlib.suppress(OSError):
            super().finish()

    def reply(self, code: int, body: str) -> None:
        """Send one reply with a `Content-Length`, so the connection stays open."""
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self) -> None:
        """Handle one request, by its path."""
        n = int(self.headers.get("Content-Length", "0"))
        if n:
            self.rfile.read(n)
        tag = f"connection {self.conn_id}, {self.path}"
        if self.path == "/login":
            token = secrets.token_hex(4)
            with LOCK:
                SESSIONS[token] = 0
            log(f"{tag}: new session {token}")
            self.reply(HTTP_OK, f"token={token} conn={self.conn_id}")
        elif self.path == "/next":
            token = self.headers.get("X-Token", "")
            with LOCK:
                if token not in SESSIONS:
                    log(f"{tag}: unknown token {token!r}")
                    self.reply(HTTP_NOT_FOUND, "unknown token")
                    return
                SESSIONS[token] += 1
                count = SESSIONS[token]
            log(f"{tag}: session {token} counter is now {count}")
            self.reply(HTTP_OK, f"n={count} conn={self.conn_id}")
        elif self.path == "/begin":
            self.txn_id = secrets.token_hex(2)
            self.txn_steps = 0
            log(f"{tag}: transaction {self.txn_id} opened")
            self.reply(HTTP_OK, f"txn={self.txn_id} conn={self.conn_id}")
        elif self.path == "/txn-step":
            if self.txn_id is None:
                log(f"{tag}: refused, this connection has no transaction")
                self.reply(HTTP_CONFLICT, f"no transaction on connection {self.conn_id}")
                return
            self.txn_steps += 1
            log(f"{tag}: transaction {self.txn_id} is at step {self.txn_steps}")
            self.reply(HTTP_OK, f"txn={self.txn_id} steps={self.txn_steps} conn={self.conn_id}")
        else:
            self.reply(HTTP_NOT_FOUND, "no such endpoint")

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002 - the base class's name
        """Drop the handler's own access log: the lines above replace it."""


def main() -> None:
    """Start the plain and the TLS server, and serve until interrupted."""
    ap = argparse.ArgumentParser()
    ap.add_argument("--http", type=int, default=8080)
    ap.add_argument("--https", type=int, default=8443)
    ap.add_argument("--cert", default="build/net/cert.pem")
    ap.add_argument("--key", default="build/net/key.pem")
    # The address to listen on. Loopback by default; the VIP test (scripts/net/criu-vip.sh)
    # listens on the private link between the VMs.
    ap.add_argument("--bind", default="127.0.0.1")
    a = ap.parse_args()

    # Port 8443 wraps each accepted socket in TLS; 8080 does not.
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(a.cert, a.key)
    plain = ThreadingHTTPServer((a.bind, a.http), Handler)
    tls = ThreadingHTTPServer((a.bind, a.https), Handler)
    tls.socket = ctx.wrap_socket(tls.socket, server_side=True)
    for s in (plain, tls):
        s.daemon_threads = True
    log(f"listening: http {a.bind}:{a.http}, https {a.bind}:{a.https}")
    threading.Thread(target=plain.serve_forever, daemon=True).start()
    try:
        tls.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
