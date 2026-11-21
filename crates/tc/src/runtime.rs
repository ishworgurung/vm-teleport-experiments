//! Running a guest, pausing it into a [`Capsule`], and resuming one.
//!
//! Two ways to pause, matching the two [`Mode`]s:
//!
//! - **Step.** The guest exports `step()`. Between two calls no Wasm frame is
//!   live, so linear memory plus the exported mutable globals is the entire
//!   state.
//! - **Async.** The guest is paused *inside* a call, at its import
//!   `ckpt.checkpoint()`. The module has been through Binaryen's Asyncify pass,
//!   which adds four exports (`asyncify_start_unwind`, `_stop_unwind`,
//!   `_start_rewind`, `_stop_rewind`) and makes every function on a path to the
//!   import able to save its locals and its position into a buffer in linear
//!   memory and return early. The host drives it:
//!
//!   1. the guest calls `ckpt.checkpoint()`; the host calls
//!      `asyncify_start_unwind(buf)` and returns;
//!   2. each frame stores its locals into `buf` and returns, until the entry
//!      export returns to the host, which calls `asyncify_stop_unwind()`;
//!   3. the call stack now lives in linear memory, so step mode's snapshot
//!      captures it;
//!   4. on resume the host restores memory and globals, calls
//!      `asyncify_start_rewind(buf)` and calls the entry export again; each frame
//!      reloads its locals and jumps back to the call it was in, until the guest
//!      re-enters `ckpt.checkpoint()`, where the host calls
//!      `asyncify_stop_rewind()` and returns. The guest carries on as if the
//!      call had simply returned.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use wasmtime::error::Context;
use wasmtime::{Caller, Engine, Extern, Instance, Linker, Module, Mutability, Store, Val, ValType};
use wasmtime::{Result, bail, format_err};
use wasmtime_wasi::p1::WasiP1Ctx;
use wasmtime_wasi::p2::pipe::MemoryOutputPipe;
use wasmtime_wasi::{FsPerms, HostMonotonicClock, I32Exit, WasiCtxBuilder};

use crate::capsule::{Capsule, GlobalValue, Hop, Manifest, Mode, Preopen, WASM_PAGE, WasiState, sha256_hex};
use crate::cpu;

/// The guest's view of the monotonic clock: it starts at `start_ns` (0 on a
/// fresh run, the capsule's value on resume) and advances with this host's
/// clock. Without it a resumed guest would see time jump back to zero.
#[derive(Debug)]
struct ResumableClock {
    start_ns: u64,
    since: Instant,
    last: Arc<AtomicU64>,
}

impl HostMonotonicClock for ResumableClock {
    fn resolution(&self) -> u64 {
        1
    }
    fn now(&self) -> u64 {
        let now = self.start_ns + u64::try_from(self.since.elapsed().as_nanos()).unwrap_or(u64::MAX);
        self.last.store(now, Ordering::Relaxed);
        now
    }
}

/// What to run and with which WASI environment.
#[derive(Debug, Clone)]
pub(crate) struct Launch {
    pub module_path: PathBuf,
    pub args: Vec<String>,
    /// (host path, guest path), in the order they become fds 3, 4, ...
    pub dirs: Vec<(PathBuf, String)>,
    /// Collect the guest's stdout here instead of passing it through (tests).
    pub capture: Option<MemoryOutputPipe>,
}

struct HostState {
    wasi: WasiP1Ctx,
    /// Unwind at the next `ckpt.checkpoint()` that runs normally.
    unwind_at_next: bool,
    asyncify_buffer: Option<u32>,
    asyncify_buffer_size: u32,
    unwound: bool,
    rewound: bool,
    /// Open TCP connections, by the handle the guest holds. This table is NOT
    /// part of the capsule: a handle in the guest's memory outlives the
    /// connection it named. That is what the external-state experiment shows.
    net: HashMap<i32, TcpStream>,
    next_net: i32,
}

/// Asyncify's runtime states, as `asyncify_get_state` reports them.
const ASYNCIFY_NORMAL: i32 = 0;
const ASYNCIFY_REWINDING: i32 = 2;

/// Handles that `net.connect` returns start here, so one is never mistaken
/// for a WASI file descriptor.
const FIRST_NET_HANDLE: i32 = 100;
/// What the net imports return for an unknown handle: -EBADF.
const NET_EBADF: i32 = -9;
/// What they return when the guest passes a range outside its memory: -EFAULT.
const NET_EFAULT: i32 = -14;
/// What they return for a bad argument (not UTF-8, not `ip:port`, a negative
/// length): -EINVAL.
const NET_EINVAL: i32 = -22;
/// The errno for a failure that the OS gave no code for: EIO.
const EIO: i32 = 5;

pub(crate) struct Guest {
    store: Store<HostState>,
    instance: Instance,
    module_sha256: String,
    clock_ns: Arc<AtomicU64>,
    launch: Launch,
}

/// The result of one run of the guest.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Outcome {
    /// Stopped at a checkpoint; the capsule is ready to save.
    Paused,
    /// The guest returned (or called `proc_exit`) without being paused.
    Finished(i32),
}

fn engine() -> Result<Engine> {
    Engine::new(&config(cfg!(target_arch = "riscv64")))
}

/// The engine settings shared by `tc` and `tc precompile`: they must agree, or
/// wasmtime refuses to load a precompiled module. NaN payloads are
/// canonicalised so float results are bit-identical on every ISA (x86 and Arm
/// disagree on NaN bits). On riscv64, SIMD is off: wasmtime 51 compiles it only
/// for CPUs with the vector extension, which the RV64 host here does not have,
/// and none of the guests uses it.
fn config(riscv64: bool) -> wasmtime::Config {
    let mut config = wasmtime::Config::new();
    config.cranelift_nan_canonicalization(true);
    if riscv64 {
        config.wasm_simd(false);
        config.wasm_relaxed_simd(false);
    }
    config
}

/// Loads `module_path`, preferring a precompiled `<sha256>.<arch>.cwasm` beside
/// it. The cache file is named by the hash of the `.wasm` it came from, so the
/// module hash a capsule checks is still the hash of the bytes compiled.
fn load_module(engine: &Engine, module_path: &std::path::Path) -> Result<(Module, String)> {
    let wasm = std::fs::read(module_path).with_context(|| format!("reading {}", module_path.display()))?;
    let sha = sha256_hex(&wasm);
    let cwasm = module_path.with_file_name(format!("{sha}.{}.cwasm", std::env::consts::ARCH));
    let module = if cwasm.exists() {
        // SAFETY: `deserialize_file` trusts the file to be wasmtime's own
        // output. It is produced by `tc precompile` from the module whose hash
        // names it, and wasmtime still rejects one built for another target,
        // version or configuration.
        unsafe { Module::deserialize_file(engine, &cwasm) }.with_context(|| format!("loading {}", cwasm.display()))?
    } else {
        Module::new(engine, &wasm)?
    };
    Ok((module, sha))
}

/// Compiles a module ahead of time for another target, for hosts where JIT
/// compiling under emulation would take too long.
pub(crate) fn precompile(module_path: &std::path::Path, target: &str) -> Result<PathBuf> {
    let mut config = config(target.starts_with("riscv64"));
    config.target(target)?;
    let engine = Engine::new(&config)?;
    let wasm = std::fs::read(module_path)?;
    let arch = target.split('-').next().unwrap_or(target);
    let arch = if arch.starts_with("riscv64") { "riscv64" } else { arch };
    let out = module_path.with_file_name(format!("{}.{arch}.cwasm", sha256_hex(&wasm)));
    std::fs::write(&out, engine.precompile_module(&wasm)?)?;
    Ok(out)
}

impl Guest {
    fn instantiate(launch: Launch, start_ns: u64) -> Result<Guest> {
        let engine = engine()?;
        let (module, module_sha256) = load_module(&engine, &launch.module_path)?;
        let clock_ns = Arc::new(AtomicU64::new(start_ns));

        let mut wasi = WasiCtxBuilder::new();
        match &launch.capture {
            Some(pipe) => wasi.stdout(pipe.clone()),
            None => wasi.inherit_stdout(),
        };
        wasi.inherit_stderr().args(&launch.args);
        wasi.monotonic_clock(ResumableClock { start_ns, since: Instant::now(), last: clock_ns.clone() });
        for (host, guest) in &launch.dirs {
            wasi.preopened_dir(host, guest, FsPerms::ReadOnly)
                .with_context(|| format!("preopening {}", host.display()))?;
        }
        let state = HostState {
            wasi: wasi.build_p1(),
            unwind_at_next: false,
            asyncify_buffer: None,
            asyncify_buffer_size: 0,
            unwound: false,
            rewound: false,
            net: HashMap::new(),
            next_net: FIRST_NET_HANDLE,
        };
        let mut store = Store::new(&engine, state);
        let mut linker: Linker<HostState> = Linker::new(&engine);
        wasmtime_wasi::p1::add_to_linker_sync(&mut linker, |s: &mut HostState| &mut s.wasi)?;
        linker.func_wrap("ckpt", "checkpoint", checkpoint)?;
        linker.func_wrap("net", "connect", net_connect)?;
        linker.func_wrap("net", "send", net_send)?;
        linker.func_wrap("net", "recv", net_recv)?;
        let instance = linker.instantiate(&mut store, &module)?;
        Ok(Guest { store, instance, module_sha256, clock_ns, launch })
    }

    /// A fresh instance, with the module's own initialisation run.
    pub(crate) fn fresh(launch: Launch) -> Result<Guest> {
        let mut g = Guest::instantiate(launch, 0)?;
        // A WASI "reactor" (a library-style module) exports `_initialize` to
        // run its constructors; a "command" runs them inside `_start`.
        if let Ok(init) = g.instance.get_typed_func::<(), ()>(&mut g.store, "_initialize") {
            init.call(&mut g.store, ())?;
        }
        g.find_asyncify_buffer()?;
        Ok(g)
    }

    /// An instance whose state is replaced by the capsule's. No guest
    /// initialisation runs: the capsule's memory already holds its result.
    pub(crate) fn restore(launch: Launch, capsule: &Capsule) -> Result<Guest> {
        let wasi = &capsule.wasi;
        if launch.args != wasi.args {
            // argv lives in linear memory too once the guest has read it, so
            // passing different args would give the guest two stories.
            bail!("args {:?} differ from the capsule's {:?}", launch.args, wasi.args);
        }
        let guest_paths: Vec<&str> = launch.dirs.iter().map(|(_, g)| g.as_str()).collect();
        let want: Vec<&str> = wasi.preopens.iter().map(|p| p.guest.as_str()).collect();
        if guest_paths != want {
            // wasi-libc caches preopen fd numbers in linear memory; a different
            // list or order would point those fds at the wrong directories.
            bail!("preopens {guest_paths:?} differ from the capsule's {want:?}");
        }
        let mut g = Guest::instantiate(launch, wasi.monotonic_ns)?;
        capsule.check_module(&g.module_sha256)?;
        g.find_asyncify_buffer()?;
        if g.store.data().asyncify_buffer != capsule.manifest.asyncify_buffer {
            bail!(
                "asyncify buffer at {:?}, the capsule's at {:?}",
                g.store.data().asyncify_buffer,
                capsule.manifest.asyncify_buffer
            );
        }

        let memory = g.memory()?;
        let have = memory.data_size(&g.store);
        if capsule.memory.len() < have {
            bail!("capsule memory ({} B) is smaller than the module's initial memory ({have} B)", capsule.memory.len());
        }
        memory.grow(&mut g.store, ((capsule.memory.len() - have) / WASM_PAGE) as u64)?;
        memory.data_mut(&mut g.store).copy_from_slice(&capsule.memory);

        // Every exported mutable global must come back, or part of the state
        // would silently keep its initial value.
        let exported = g.mutable_globals();
        let names: Vec<&str> = capsule.globals.iter().map(|(n, _)| n.as_str()).collect();
        let want: Vec<&str> = exported.iter().map(|(n, _)| n.as_str()).collect();
        if names != want {
            bail!("capsule globals {names:?} do not match the module's mutable globals {want:?}");
        }
        for (name, value) in &capsule.globals {
            let global = g.instance.get_global(&mut g.store, name).expect("listed above");
            let val = match (global.ty(&g.store).content(), value) {
                (ValType::I32, GlobalValue::I32(b)) => Val::I32(b.cast_signed()),
                (ValType::I64, GlobalValue::I64(b)) => Val::I64(b.cast_signed()),
                (ValType::F32, GlobalValue::F32(b)) => Val::F32(*b),
                (ValType::F64, GlobalValue::F64(b)) => Val::F64(*b),
                (t, v) => bail!("global {name} is {t} but the capsule holds {v:?}"),
            };
            global.set(&mut g.store, val)?;
        }
        Ok(g)
    }

    pub(crate) fn module_sha256(&self) -> &str {
        &self.module_sha256
    }

    fn memory(&mut self) -> Result<wasmtime::Memory> {
        self.instance.get_memory(&mut self.store, "memory").ok_or_else(|| format_err!("guest exports no `memory`"))
    }

    fn mutable_globals(&mut self) -> Vec<(String, wasmtime::Global)> {
        let mut out: Vec<(String, wasmtime::Global)> = self
            .instance
            .exports(&mut self.store)
            .filter_map(|e| {
                let name = e.name().to_string();
                match e.into_extern() {
                    Extern::Global(g) => Some((name, g)),
                    _ => None,
                }
            })
            .collect();
        out.retain(|(_, g)| g.ty(&self.store).mutability() == Mutability::Var);
        out.sort_by(|a, b| a.0.cmp(&b.0));
        out
    }

    /// An Asyncify'd guest exports `ckpt_buffer()` and `ckpt_buffer_size()`:
    /// a static array in its own linear memory for Asyncify's saved frames.
    fn find_asyncify_buffer(&mut self) -> Result<()> {
        let Ok(ptr) = self.instance.get_typed_func::<(), i32>(&mut self.store, "ckpt_buffer") else {
            return Ok(());
        };
        let size = self.instance.get_typed_func::<(), i32>(&mut self.store, "ckpt_buffer_size")?;
        let ptr = ptr.call(&mut self.store, ())?.cast_unsigned();
        let size = size.call(&mut self.store, ())?.cast_unsigned();
        let data = self.store.data_mut();
        data.asyncify_buffer = Some(ptr);
        data.asyncify_buffer_size = size;
        Ok(())
    }

    pub(crate) fn step(&mut self, n: u64) -> Result<i64> {
        let step = self.instance.get_typed_func::<(), i64>(&mut self.store, "step")?;
        let mut last = 0;
        for _ in 0..n {
            last = step.call(&mut self.store, ())?;
        }
        Ok(last)
    }

    /// Calls `entry`. With `pause` set, the first `ckpt.checkpoint()` reached
    /// in normal execution unwinds the guest and this returns [`Outcome::Paused`].
    /// Without it, checkpoints return straight away and the guest runs to the end.
    pub(crate) fn run_async(&mut self, entry: &str, rewinding: bool, pause: bool) -> Result<Outcome> {
        let Some(buf) = self.store.data().asyncify_buffer else {
            bail!("the module exports no ckpt_buffer: was it built for async mode?");
        };
        if self.instance.get_global(&mut self.store, "__stack_pointer").is_none() {
            // Unwinding leaves the shadow-stack pointer where the deepest
            // frame put it, and rewinding skips the code that would set it
            // again, so it must be saved and restored. It can only be read
            // if exported (wasm-ld --export=__stack_pointer).
            bail!("the module does not export __stack_pointer, so its call stack cannot be restored");
        }
        self.store.data_mut().unwind_at_next = pause;
        if rewinding {
            let rewind = self.instance.get_typed_func::<i32, ()>(&mut self.store, "asyncify_start_rewind")?;
            rewind.call(&mut self.store, buf.cast_signed())?;
        }
        let func =
            self.instance.get_func(&mut self.store, entry).ok_or_else(|| format_err!("guest exports no `{entry}`"))?;
        // Arguments do not matter on a rewind (Asyncify restores the entry's
        // locals, parameters included) and these experiments' entries take none.
        let params: Vec<Val> =
            func.ty(&self.store).params().map(|t| Val::default_for_ty(&t).expect("numeric")).collect();
        let mut results: Vec<Val> =
            func.ty(&self.store).results().map(|t| Val::default_for_ty(&t).expect("numeric")).collect();
        let call = func.call(&mut self.store, &params, &mut results);

        if rewinding && !self.store.data().rewound {
            call?;
            bail!("the rewind never reached ckpt.checkpoint(): the capsule and module disagree");
        }
        if self.store.data().unwound {
            call?;
            let stop = self.instance.get_typed_func::<(), ()>(&mut self.store, "asyncify_stop_unwind")?;
            stop.call(&mut self.store, ())?;
            return Ok(Outcome::Paused);
        }
        match call {
            Ok(()) => Ok(Outcome::Finished(0)),
            Err(e) => match e.downcast_ref::<I32Exit>() {
                Some(exit) => Ok(Outcome::Finished(exit.0)),
                None => Err(e),
            },
        }
    }

    /// Snapshots the paused guest. `prior` is the manifest it was restored
    /// from, so the hop log grows rather than restarting.
    pub(crate) fn snapshot(
        &mut self,
        mode: Mode,
        entry: &str,
        prior: Option<&Manifest>,
        counter_hint: Option<i64>,
    ) -> Result<Capsule> {
        let memory = self.memory()?.data(&self.store).to_vec();
        let mut globals = Vec::new();
        for (name, g) in self.mutable_globals() {
            let v = match g.get(&mut self.store) {
                Val::I32(x) => GlobalValue::I32(x.cast_unsigned()),
                Val::I64(x) => GlobalValue::I64(x.cast_unsigned()),
                Val::F32(x) => GlobalValue::F32(x),
                Val::F64(x) => GlobalValue::F64(x),
                other => bail!("global {name} has a type a capsule cannot hold: {other:?}"),
            };
            globals.push((name, v));
        }
        // Asked only after memory is copied: calling into the guest moves
        // its stack pointer and could write below it.
        let counter_hint = match counter_hint {
            Some(c) => Some(c),
            None => match self.instance.get_typed_func::<(), i64>(&mut self.store, "ckpt_hint") {
                Ok(f) => Some(f.call(&mut self.store, ())?),
                Err(_) => None,
            },
        };
        let mut hops = prior.map_or_default(|m| m.hops.clone());
        let hop =
            Hop { host: cpu::hostname(), arch: std::env::consts::ARCH.into(), cpu_model: cpu::model(), counter_hint };
        hops.push(hop.clone());
        let manifest = Manifest {
            version: crate::capsule::FORMAT_VERSION,
            mode,
            entry: entry.into(),
            module_sha256: self.module_sha256.clone(),
            wasmtime_version: crate::capsule::WASMTIME_VERSION.into(),
            source_host: hop.host,
            source_arch: hop.arch,
            cpu_model: hop.cpu_model,
            counter_hint,
            created_at: SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs()),
            memory_sha256: String::new(),
            memory_pages: 0,
            globals_sha256: String::new(),
            wasi_sha256: String::new(),
            asyncify_buffer: self.store.data().asyncify_buffer,
            hops,
        };
        let wasi = WasiState {
            args: self.launch.args.clone(),
            env: vec![],
            preopens: self
                .launch
                .dirs
                .iter()
                .map(|(h, g)| Preopen { guest: g.clone(), host: h.display().to_string() })
                .collect(),
            monotonic_ns: self.clock_ns.load(Ordering::Relaxed),
        };
        Ok(Capsule { manifest, memory, globals, wasi })
    }
}

/// Reads `len` bytes at `ptr` from the guest's linear memory.
fn guest_bytes(caller: &mut Caller<'_, HostState>, ptr: i32, len: i32) -> Option<Vec<u8>> {
    let memory = caller.get_export("memory").and_then(Extern::into_memory)?;
    let mut buf = vec![0u8; usize::try_from(len).ok()?];
    memory.read(&mut *caller, usize::try_from(ptr).ok()?, &mut buf).ok()?;
    Some(buf)
}

/// A failed socket call as the guest sees it: -errno, or -EIO without one.
fn neg_errno(e: &std::io::Error) -> i32 {
    -e.raw_os_error().unwrap_or(EIO)
}

/// Import `net.connect(addr_ptr, addr_len) -> handle`. The address is text,
/// `ip:port`. Returns a handle (at least 100) or -errno. The connection is
/// opened by `tc` on this host: only the handle number goes into the guest.
fn net_connect(mut caller: Caller<'_, HostState>, ptr: i32, len: i32) -> i32 {
    let Some(bytes) = guest_bytes(&mut caller, ptr, len) else { return NET_EFAULT };
    let Ok(addr) = String::from_utf8(bytes) else { return NET_EINVAL };
    let Ok(sock) = addr.parse() else { return NET_EINVAL };
    let timeout = std::time::Duration::from_secs(5);
    match TcpStream::connect_timeout(&sock, timeout) {
        Ok(stream) => {
            // A dead peer must fail a call, not hang the demo.
            let _ = stream.set_read_timeout(Some(timeout));
            let _ = stream.set_write_timeout(Some(timeout));
            let data = caller.data_mut();
            let handle = data.next_net;
            data.next_net += 1;
            data.net.insert(handle, stream);
            handle
        }
        Err(e) => neg_errno(&e),
    }
}

/// Import `net.send(handle, ptr, len) -> bytes sent or -errno`.
fn net_send(mut caller: Caller<'_, HostState>, handle: i32, ptr: i32, len: i32) -> i32 {
    let Some(bytes) = guest_bytes(&mut caller, ptr, len) else { return NET_EFAULT };
    match caller.data_mut().net.get_mut(&handle) {
        None => NET_EBADF,
        Some(stream) => match stream.write_all(&bytes) {
            Ok(()) => len,
            Err(e) => neg_errno(&e),
        },
    }
}

/// Import `net.recv(handle, ptr, cap) -> bytes received, 0 at end of stream,
/// or -errno`. One read, as `read(2)` does: the guest loops for a full reply.
fn net_recv(mut caller: Caller<'_, HostState>, handle: i32, ptr: i32, cap: i32) -> i32 {
    let Ok(cap_usize) = usize::try_from(cap) else { return NET_EINVAL };
    let mut buf = vec![0u8; cap_usize];
    let n = match caller.data_mut().net.get_mut(&handle) {
        None => return NET_EBADF,
        Some(stream) => match stream.read(&mut buf) {
            Ok(n) => n,
            Err(e) => return neg_errno(&e),
        },
    };
    let Some(memory) = caller.get_export("memory").and_then(Extern::into_memory) else { return NET_EFAULT };
    let Ok(at) = usize::try_from(ptr) else { return NET_EINVAL };
    match memory.write(&mut caller, at, &buf[..n]) {
        Ok(()) => i32::try_from(n).unwrap_or(i32::MAX),
        Err(_) => NET_EFAULT,
    }
}

/// The `ckpt.checkpoint()` import. See the module docs for the protocol.
fn checkpoint(mut caller: Caller<'_, HostState>) -> Result<()> {
    let state_fn = caller
        .get_export("asyncify_get_state")
        .and_then(Extern::into_func)
        .ok_or_else(|| format_err!("ckpt.checkpoint() called but the module is not Asyncify'd"))?;
    let mut state = [Val::I32(0)];
    state_fn.call(&mut caller, &[], &mut state)?;
    match state[0].unwrap_i32() {
        ASYNCIFY_REWINDING => {
            let stop = caller.get_export("asyncify_stop_rewind").and_then(Extern::into_func).expect("Asyncify export");
            stop.call(&mut caller, &[], &mut [])?;
            caller.data_mut().rewound = true;
            Ok(())
        }
        ASYNCIFY_NORMAL if caller.data().unwind_at_next => {
            let buf = caller.data().asyncify_buffer.expect("checked before the call");
            let size = caller.data().asyncify_buffer_size;
            // Asyncify's data header: two i32s, the next free byte and the end.
            let memory = caller.get_export("memory").and_then(Extern::into_memory).expect("memory export");
            let header = [(buf + 8).to_le_bytes(), (buf + size).to_le_bytes()].concat();
            memory.write(&mut caller, buf as usize, &header)?;
            let start =
                caller.get_export("asyncify_start_unwind").and_then(Extern::into_func).expect("Asyncify export");
            start.call(&mut caller, &[Val::I32(buf.cast_signed())], &mut [])?;
            let data = caller.data_mut();
            data.unwound = true;
            data.unwind_at_next = false;
            Ok(())
        }
        ASYNCIFY_NORMAL => Ok(()),
        s => bail!("ckpt.checkpoint() reached in Asyncify state {s}"),
    }
}

#[cfg(test)]
mod tests {
    //! These run the real guests from `build/` (`make guests` first).
    //! Each refusal test starts from a valid capsule and breaks exactly the
    //! one thing its check guards, so that check alone decides the outcome.
    use super::*;

    fn wasm(name: &str) -> PathBuf {
        let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../build").join(name);
        assert!(p.exists(), "{} missing: run `make guests` at the repository root", p.display());
        p
    }

    fn launch(module: PathBuf) -> (Launch, MemoryOutputPipe) {
        let pipe = MemoryOutputPipe::new(1 << 20);
        let args = vec!["guest".to_string()];
        (Launch { module_path: module, args, dirs: vec![], capture: Some(pipe.clone()) }, pipe)
    }

    fn text(pipe: &MemoryOutputPipe) -> String {
        String::from_utf8(pipe.contents().to_vec()).expect("guest prints UTF-8")
    }

    /// The guest prints its elapsed time (`t=..ms`), which differs run to run.
    fn without_times(out: &str) -> String {
        out.lines()
            .map(|l| match l.find(" t=") {
                Some(i) => &l[..i],
                None => l,
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn step_capsule(steps: u64) -> Capsule {
        let (l, _) = launch(wasm("step-counter.wasm"));
        let mut g = Guest::fresh(l).unwrap();
        let last = g.step(steps).unwrap();
        g.snapshot(Mode::Step, "step", None, Some(last)).unwrap()
    }

    fn async_capsule() -> (Capsule, String) {
        let (l, pipe) = launch(wasm("async-counter.wasm"));
        let mut g = Guest::fresh(l).unwrap();
        assert_eq!(g.run_async("_start", false, true).unwrap(), Outcome::Paused);
        (g.snapshot(Mode::Async, "_start", None, None).unwrap(), text(&pipe))
    }

    fn restore_err(module: &str, capsule: &Capsule, edit: impl FnOnce(&mut Launch)) -> String {
        let (mut l, _) = launch(wasm(module));
        edit(&mut l);
        match Guest::restore(l, capsule) {
            Ok(_) => panic!("restore was accepted"),
            Err(e) => format!("{e:#}"),
        }
    }

    #[test]
    fn step_round_trip() {
        let c = step_capsule(1000);
        assert_eq!(c.manifest.counter_hint, Some(1000));
        let (l, _) = launch(wasm("step-counter.wasm"));
        let mut g = Guest::restore(l, &c).unwrap();
        assert_eq!(g.step(1000).unwrap(), 2000);
    }

    #[test]
    fn async_resume_matches_an_uninterrupted_run() {
        let (whole_l, whole) = launch(wasm("async-counter.wasm"));
        let mut g = Guest::fresh(whole_l).unwrap();
        assert_eq!(g.run_async("_start", false, false).unwrap(), Outcome::Finished(0));

        let (c1, part1) = async_capsule();
        assert_eq!(c1.manifest.counter_hint, Some(1000));
        let (l, p2) = launch(wasm("async-counter.wasm"));
        let mut g = Guest::restore(l, &c1).unwrap();
        assert_eq!(g.run_async("_start", true, true).unwrap(), Outcome::Paused);
        let c2 = g.snapshot(Mode::Async, "_start", Some(&c1.manifest), None).unwrap();
        assert_eq!(c2.manifest.counter_hint, Some(2000));
        assert_eq!(c2.manifest.hops.len(), 2);
        let (l, p3) = launch(wasm("async-counter.wasm"));
        let mut g = Guest::restore(l, &c2).unwrap();
        assert_eq!(g.run_async("_start", true, true).unwrap(), Outcome::Paused);
        let c3 = g.snapshot(Mode::Async, "_start", Some(&c2.manifest), None).unwrap();
        assert_eq!(c3.manifest.counter_hint, Some(3000));
        assert_eq!(c3.manifest.hops.len(), 3);
        let (l, p4) = launch(wasm("async-counter.wasm"));
        let mut g = Guest::restore(l, &c3).unwrap();
        assert_eq!(g.run_async("_start", true, false).unwrap(), Outcome::Finished(0));

        let resumed = format!("{part1}{}{}{}", text(&p2), text(&p3), text(&p4));
        assert!(resumed.contains("sum_sq=21341334000 (expected 21341334000)"), "{resumed}");
        assert_eq!(without_times(&resumed), without_times(&text(&whole)));
    }

    #[test]
    fn the_monotonic_clock_carries_on() {
        let (c, _) = async_capsule();
        assert!(c.wasi.monotonic_ns > 0, "the guest read its clock before pausing");
        // Restored and paused again before the guest reads the clock: the
        // capsule must hold exactly the time it was restored with.
        let (l, _) = launch(wasm("async-counter.wasm"));
        let mut g = Guest::restore(l, &c).unwrap();
        let same = g.snapshot(Mode::Async, "_start", Some(&c.manifest), None).unwrap();
        assert_eq!(same.wasi.monotonic_ns, c.wasi.monotonic_ns);
        g.run_async("_start", true, true).unwrap();
        let c2 = g.snapshot(Mode::Async, "_start", Some(&c.manifest), None).unwrap();
        assert!(c2.wasi.monotonic_ns > c.wasi.monotonic_ns, "{} <= {}", c2.wasi.monotonic_ns, c.wasi.monotonic_ns);
    }

    #[test]
    fn resumable_clock_starts_where_it_left_off() {
        let last = Arc::new(AtomicU64::new(0));
        let clock = ResumableClock { start_ns: 5_000_000_000, since: Instant::now(), last: last.clone() };
        let now = clock.now();
        assert!(now >= 5_000_000_000, "{now}");
        assert_eq!(last.load(Ordering::Relaxed), now);
    }

    /// Not a check of tc's code but of the claim in runtime.rs: without the
    /// saved __`stack_pointer`, the rewound frames and new calls collide.
    #[test]
    fn the_stack_pointer_must_travel() {
        let (mut c, _) = async_capsule();
        let (l, _) = launch(wasm("async-counter.wasm"));
        let fresh_sp = {
            let mut g = Guest::fresh(l).unwrap();
            match g.instance.get_global(&mut g.store, "__stack_pointer").unwrap().get(&mut g.store) {
                Val::I32(v) => v.cast_unsigned(),
                v => panic!("{v:?}"),
            }
        };
        let saved = c.globals.iter_mut().find(|(n, _)| n == "__stack_pointer").unwrap();
        assert_ne!(saved.1, GlobalValue::I32(fresh_sp), "paused inside a call, the stack pointer has moved");
        saved.1 = GlobalValue::I32(fresh_sp);
        let (l, pipe) = launch(wasm("async-counter.wasm"));
        let mut g = Guest::restore(l, &c).unwrap();
        let run = g.run_async("_start", true, false);
        let out = text(&pipe);
        eprintln!("without the saved stack pointer: {:?}\n{out}", run.as_ref().map_err(|e| format!("{e:#}")));
        assert!(
            run.is_err() || !out.contains("sum_sq=21341334000 (expected 21341334000) history=[1000, 2000, 3000]"),
            "resumed correctly without the stack pointer: {out}"
        );
    }

    #[test]
    fn refuses_another_module() {
        let c = step_capsule(10);
        assert!(restore_err("async-counter.wasm", &c, |_| {}).contains("module_sha256 mismatch"));
    }

    #[test]
    fn refuses_other_args() {
        let c = step_capsule(10);
        let err = restore_err("step-counter.wasm", &c, |l| l.args.push("extra".into()));
        assert!(err.contains("differ from the capsule's"), "{err}");
    }

    #[test]
    fn refuses_other_preopens() {
        let c = step_capsule(10);
        let err = restore_err("step-counter.wasm", &c, |l| l.dirs.push((std::env::temp_dir(), "/data".into())));
        assert!(err.contains("preopens"), "{err}");
    }

    #[test]
    fn refuses_a_moved_asyncify_buffer() {
        let (mut c, _) = async_capsule();
        c.manifest.asyncify_buffer = c.manifest.asyncify_buffer.map(|b| b + 16);
        assert!(restore_err("async-counter.wasm", &c, |_| {}).contains("asyncify buffer"));
    }

    #[test]
    fn refuses_memory_smaller_than_the_module() {
        let mut c = step_capsule(10);
        c.memory.truncate(WASM_PAGE);
        assert!(restore_err("step-counter.wasm", &c, |_| {}).contains("smaller than the module's initial memory"));
    }

    #[test]
    fn refuses_a_missing_global() {
        let mut c = step_capsule(10);
        c.globals.clear();
        assert!(restore_err("step-counter.wasm", &c, |_| {}).contains("do not match the module's mutable globals"));
    }

    #[test]
    fn refuses_a_global_of_another_type() {
        let mut c = step_capsule(10);
        c.globals[0].1 = GlobalValue::I64(1);
        assert!(restore_err("step-counter.wasm", &c, |_| {}).contains("but the capsule holds"));
    }

    #[test]
    fn async_needs_the_asyncify_exports() {
        let (l, _) = launch(wasm("step-counter.wasm"));
        let mut g = Guest::fresh(l).unwrap();
        let err = g.run_async("step", false, true).unwrap_err().to_string();
        assert!(err.contains("exports no ckpt_buffer"), "{err}");
    }

    #[test]
    fn async_needs_an_exported_stack_pointer() {
        let dir = std::env::temp_dir().join(format!("tc-nosp-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let module = dir.join("nosp.wat");
        std::fs::write(
            &module,
            r#"(module (memory (export "memory") 1)
                 (func (export "ckpt_buffer") (result i32) i32.const 1024)
                 (func (export "ckpt_buffer_size") (result i32) i32.const 1024)
                 (func (export "_start")))"#,
        )
        .unwrap();
        let (l, _) = launch(module);
        let mut g = Guest::fresh(l).unwrap();
        let err = g.run_async("_start", false, true).unwrap_err().to_string();
        assert!(err.contains("does not export __stack_pointer"), "{err}");
    }

    #[test]
    fn refuses_a_rewind_that_never_reaches_the_checkpoint() {
        let (mut c, _) = async_capsule();
        // An export that returns without calling ckpt.checkpoint().
        c.manifest.entry = "ckpt_buffer_size".into();
        let (l, _) = launch(wasm("async-counter.wasm"));
        let mut g = Guest::restore(l, &c).unwrap();
        let err = g.run_async(&c.manifest.entry, true, false).unwrap_err().to_string();
        assert!(err.contains("never reached ckpt.checkpoint()"), "{err}");
    }

    #[test]
    fn checkpoint_needs_asyncify() {
        let dir = std::env::temp_dir().join(format!("tc-noasync-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let module = dir.join("noasync.wat");
        std::fs::write(
            &module,
            r#"(module (import "ckpt" "checkpoint" (func $c)) (memory (export "memory") 1)
                 (func (export "_start") call $c))"#,
        )
        .unwrap();
        let (l, _) = launch(module);
        let mut g = Guest::fresh(l).unwrap();
        let f = g.instance.get_typed_func::<(), ()>(&mut g.store, "_start").unwrap();
        let err = format!("{:#}", f.call(&mut g.store, ()).unwrap_err());
        assert!(err.contains("not Asyncify'd"), "{err}");
    }

    /// Runs a one-function WAT module that imports the net functions and
    /// returns the i32 that `go` returns.
    fn run_net_wat(wat: &str) -> i32 {
        let dir = std::env::temp_dir().join(format!("tc-net-{}-{}", std::process::id(), wat.len()));
        std::fs::create_dir_all(&dir).unwrap();
        let module = dir.join("net.wat");
        std::fs::write(&module, wat).unwrap();
        let (l, _) = launch(module);
        let mut g = Guest::fresh(l).unwrap();
        let f = g.instance.get_typed_func::<(), i32>(&mut g.store, "go").unwrap();
        f.call(&mut g.store, ()).unwrap()
    }

    #[test]
    fn a_handle_that_was_never_opened_is_ebadf() {
        // The state after a restore: the guest holds handle 100, the new
        // host's table is empty.
        let wat = r#"(module
            (import "net" "send" (func $send (param i32 i32 i32) (result i32)))
            (memory (export "memory") 1)
            (func (export "go") (result i32) i32.const 100 i32.const 0 i32.const 0 call $send))"#;
        // -EBADF, written out: the test must not share the constant it checks.
        assert_eq!(run_net_wat(wat), -9);
    }

    #[test]
    fn connect_returns_a_handle_and_a_closed_port_returns_an_errno() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        let wat = |addr: &str| {
            format!(
                r#"(module
                (import "net" "connect" (func $connect (param i32 i32) (result i32)))
                (memory (export "memory") 1)
                (data (i32.const 0) "{addr}")
                (func (export "go") (result i32) i32.const 0 i32.const {} call $connect))"#,
                addr.len()
            )
        };
        // Handles start at 100, so one is never mistaken for a WASI fd.
        assert!(run_net_wat(&wat(&addr)) >= 100);
        // Nothing listens once the listener is gone: connection refused, -111.
        drop(listener);
        assert_eq!(run_net_wat(&wat(&addr)), -111);
    }
}
