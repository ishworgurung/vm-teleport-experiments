//! Phase 1 guest: a counter in linear memory, advanced one `step()` at a time.
//!
//! Built as a WASI "reactor" (a cdylib: no `main`, exports called by the
//! host). Between two `step()` calls no Wasm frame is live, so the host's
//! snapshot of linear memory and the exported globals is the whole state.

use std::sync::atomic::{AtomicU64, Ordering};

// A static, so it lives at a fixed address in linear memory. (Without threads,
// wasm32 compiles these atomics to plain loads and stores.)
static COUNTER: AtomicU64 = AtomicU64::new(0);

#[unsafe(no_mangle)]
pub extern "C" fn init() {
    COUNTER.store(0, Ordering::Relaxed);
}

#[unsafe(no_mangle)]
pub extern "C" fn step() -> u64 {
    COUNTER.fetch_add(1, Ordering::Relaxed) + 1
}
