//! Phase 2 guest: a counter that lives on the call stack, paused mid-loop.
//!
//! `main` counts to TOTAL in a local variable and calls the host import
//! `ckpt.checkpoint()` every EVERY iterations. After Binaryen's Asyncify pass
//! (see ../Makefile) that call can unwind the whole stack, `main`'s locals
//! included, into a buffer in linear memory, and a host on another ISA can
//! rewind it. Nothing here is re-initialised on resume: if the loop variable,
//! the heap-allocated history or the start time came back wrong, the output
//! would show it.

use std::time::Instant;

#[link(wasm_import_module = "ckpt")]
unsafe extern "C" {
    fn checkpoint();
}

/// Asyncify's buffer: its saved frames go here, so they are part of linear
/// memory and travel in the capsule. 64 KiB is far more than this stack needs.
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
    // Only the address is taken; the host owns the contents.
    to_abi((&raw mut BUF).addr())
}

#[unsafe(no_mangle)]
pub extern "C" fn ckpt_buffer_size() -> i32 {
    to_abi(BUF_SIZE)
}

/// The counter value at the last checkpoint, for the capsule's manifest.
#[unsafe(no_mangle)]
pub extern "C" fn ckpt_hint() -> i64 {
    // SAFETY: single-threaded guest; the host calls this between runs.
    unsafe { HINT }
}

const TOTAL: u64 = 4000;
const EVERY: u64 = 1000;

fn main() {
    let start = Instant::now();
    let mut history: Vec<u64> = Vec::new();
    let mut sum: u64 = 0;
    for i in 1..=TOTAL {
        sum = sum.wrapping_add(i * i);
        if i % 250 == 0 {
            println!("  [guest] i={i} sum_sq={sum} history={history:?} t={}ms", start.elapsed().as_millis());
        }
        if i % EVERY == 0 && i < TOTAL {
            history.push(i);
            // SAFETY: single-threaded guest.
            unsafe {
                HINT = i.cast_signed();
                checkpoint();
            }
        }
    }
    println!("  [guest] done: i={TOTAL} sum_sq={sum} (expected {}) history={history:?}", expected());
}

/// Sum of squares 1..=TOTAL, n(n+1)(2n+1)/6, to check nothing was lost or repeated.
fn expected() -> u64 {
    TOTAL * (TOTAL + 1) * (2 * TOTAL + 1) / 6
}
