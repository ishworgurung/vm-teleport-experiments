//! Phase 6 guest: state that lives OUTSIDE linear memory.
//!
//! The guest talks to the experiments' test server (scripts/net/server.py) through three
//! host imports, `net.connect`, `net.send` and `net.recv`. WASI preview 1 has
//! no outbound sockets, so this is the only way a guest here can reach a
//! network. It holds two kinds of external state:
//!
//! - a SESSION token. The server keeps the session, any connection that
//!   presents the token reaches it, and the token is a string in linear memory.
//! - a TRANSACTION on one connection. The server binds it to that TCP
//!   connection and rolls it back when the connection closes. The guest holds
//!   only a connection handle, an integer that names a socket in the host.
//!
//! It checkpoints after two steps of each. On the other side of the capsule it
//! tries to carry on with the old handle, then reconnects with the token.

use std::fmt::Write as _;

#[link(wasm_import_module = "ckpt")]
unsafe extern "C" {
    fn checkpoint();
}

#[link(wasm_import_module = "net")]
unsafe extern "C" {
    fn connect(addr: *const u8, len: usize) -> i32;
    fn send(handle: i32, buf: *const u8, len: usize) -> i32;
    fn recv(handle: i32, buf: *mut u8, cap: usize) -> i32;
}

/// Asyncify's buffer: the saved frames go here, so they travel in the capsule.
const BUF_SIZE: usize = 64 * 1024;
static mut BUF: [u8; BUF_SIZE] = [0; BUF_SIZE];
static mut HINT: i64 = 0;

/// A `wasm32` address or size as the `i32` that the Wasm ABI passes. The host
/// reads it back as unsigned (`tc` calls `cast_unsigned`), so an address above
/// 2 GiB still round-trips.
fn to_abi(value: usize) -> i32 {
    u32::try_from(value).expect("a wasm32 address fits in 32 bits").cast_signed()
}

#[unsafe(no_mangle)]
pub extern "C" fn ckpt_buffer() -> i32 {
    to_abi((&raw mut BUF).addr())
}

#[unsafe(no_mangle)]
pub extern "C" fn ckpt_buffer_size() -> i32 {
    to_abi(BUF_SIZE)
}

#[unsafe(no_mangle)]
pub extern "C" fn ckpt_hint() -> i64 {
    // SAFETY: single-threaded guest; the host calls this between runs.
    unsafe { HINT }
}

/// What a failed call returned: a negative errno, or 0 for "the peer closed".
type NetErr = i32;

fn open(addr: &str) -> Result<i32, NetErr> {
    // SAFETY: the pointer and length describe `addr`, which outlives the call.
    let h = unsafe { connect(addr.as_ptr(), addr.len()) };
    if h < 0 { Err(h) } else { Ok(h) }
}

/// One POST with an empty body on connection `h`. Returns (status, body).
fn post(h: i32, path: &str, token: Option<&str>) -> Result<(u16, String), NetErr> {
    let mut req = format!("POST {path} HTTP/1.1\r\nHost: server\r\nContent-Length: 0\r\n");
    if let Some(t) = token {
        write!(req, "X-Token: {t}\r\n").expect("writing to a String cannot fail");
    }
    req.push_str("\r\n");
    // SAFETY: pointer and length describe `req`, alive for the call.
    let sent = unsafe { send(h, req.as_ptr(), req.len()) };
    if sent < 0 {
        return Err(sent);
    }
    // Read until the headers are complete, then until Content-Length bytes of body.
    let mut data: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 1024];
    loop {
        if let Some(end) = data.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&data[..end]).to_string();
            let len: usize = head
                .lines()
                .find_map(|l| l.strip_prefix("Content-Length: ").or_else(|| l.strip_prefix("content-length: ")))
                .and_then(|v| v.trim().parse().ok())
                .unwrap_or(0);
            if data.len() >= end + 4 + len {
                let status = head.split_whitespace().nth(1).and_then(|s| s.parse().ok()).unwrap_or(0);
                let body = String::from_utf8_lossy(&data[end + 4..end + 4 + len]).to_string();
                return Ok((status, body));
            }
        }
        // SAFETY: `chunk` is a live buffer of the stated size.
        let n = unsafe { recv(h, chunk.as_mut_ptr(), chunk.len()) };
        let Some(len) = usize::try_from(n).ok().filter(|&len| len > 0) else {
            return Err(n);
        };
        data.extend_from_slice(&chunk[..len]);
    }
}

/// Pulls `key=value` out of a reply body such as `token=ab12 conn=3`.
fn field<'a>(body: &'a str, key: &str) -> &'a str {
    body.split_whitespace().find_map(|w| w.strip_prefix(key).and_then(|r| r.strip_prefix('='))).unwrap_or("?")
}

/// Calls `path` and prints what came back, or what went wrong.
fn show(label: &str, h: i32, path: &str, token: Option<&str>) -> Option<String> {
    match post(h, path, token) {
        Ok((200, body)) => {
            println!("{label:<52} handle {h}: the server replied 200 ({body})");
            Some(body)
        }
        Ok((code, body)) => {
            println!("{label:<52} handle {h}: the server refused, code {code} ({body})");
            None
        }
        Err(0) => {
            println!("{label:<52} handle {h}: FAILED, the server closed the connection");
            None
        }
        Err(e) => {
            println!("{label:<52} handle {h}: FAILED, error number {} (9 means this handle is not open)", -e);
            None
        }
    }
}

fn main() {
    // argv: program, server address, optionally "nopause" for the control run.
    let args: Vec<String> = std::env::args().collect();
    let addr = args.get(1).map_or("127.0.0.1:8080", String::as_str);
    let pause = args.get(2).map(String::as_str) != Some("nopause");

    let h = open(addr).expect("connect");
    println!("connected to {addr}, connection handle {h}");
    let login = show("log in (creates a session on the server)", h, "/login", None).expect("login");
    let token = field(&login, "token").to_string();
    show("open a transaction (tied to this connection)", h, "/begin", None).expect("begin");
    for _ in 0..2 {
        show("session step", h, "/next", Some(&token));
        show("transaction step", h, "/txn-step", None);
    }
    println!("the program holds token {token} in its memory and handle {h} in a variable");
    // SAFETY: single-threaded guest.
    unsafe { HINT = 2 };
    if pause {
        // SAFETY: the host import; see crates/tc/src/runtime.rs.
        unsafe { checkpoint() };
        println!("--- the program was paused here, and carries on (possibly on another host) ---");
    }

    // 1. Carry on exactly as before: same handle, same transaction.
    let same = show("transaction step, on the old handle", h, "/txn-step", None);
    // 2. Same handle, session step: this needs only the connection to exist.
    show("session step, on the old handle", h, "/next", Some(&token));
    // 3. Reconnect, and present the token we kept in memory.
    let h2 = open(addr).expect("reconnect");
    println!("opened a new connection, handle {h2}");
    let next = show("session step, on the new connection, with the token", h2, "/next", Some(&token));
    // 4. The transaction was bound to the old connection.
    let txn = show("transaction step, on the new connection", h2, "/txn-step", None);

    println!(
        "summary: the old connection handle {}; the token {} the session; the transaction {}",
        if same.is_some() { "still works" } else { "no longer works" },
        if next.is_some() { "reaches" } else { "does not reach" },
        if txn.is_some() { "carried on" } else { "is gone" },
    );
}
