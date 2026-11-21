//! The capsule: everything needed to resume a Wasm instance on another machine.
//!
//! A capsule is a directory of four files (see `docs/capsule-format.md`):
//! `manifest.json`, `memory.bin`, `globals.json` and `wasi.json`. None of them
//! holds anything tied to the CPU that wrote it: linear memory is a byte array
//! whose layout the Wasm spec fixes (little-endian on every host), and globals
//! are typed Wasm values. That is the whole reason the capsule can cross ISAs.
//!
//! Loading is fail-closed. [`Capsule::load`] refuses a capsule whose files are
//! missing, whose format version or wasmtime version differs, or whose memory or
//! side files do not match the hashes recorded in the manifest. The module check
//! (`module_sha256`) happens in [`Capsule::check_module`], against the bytes the
//! caller is about to instantiate.

use std::fmt::Write as _;
use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use wasmtime::error::Context;
use wasmtime::{Result, bail};

/// Bumped on any incompatible change to the files below.
pub(crate) const FORMAT_VERSION: u32 = 0;

/// The wasmtime version this host links. Cargo.toml pins it with `=`, and a
/// test checks Cargo.lock agrees, so this string cannot silently drift.
pub(crate) const WASMTIME_VERSION: &str = "51.0.0";

/// How the guest was paused.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Mode {
    /// Between two calls to an exported `step()`: no Wasm frames are live.
    Step,
    /// Inside a call, at `ckpt.checkpoint()`, with the call stack unwound into
    /// linear memory by Binaryen's Asyncify transform.
    Async,
}

/// One machine the instance ran on, appended at every checkpoint.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Hop {
    pub host: String,
    pub arch: String,
    pub cpu_model: String,
    pub counter_hint: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Manifest {
    pub version: u32,
    pub mode: Mode,
    /// Export called to run the guest: `step` in step mode, `_start` or a
    /// named function in async mode. Async resume calls it again to rewind.
    pub entry: String,
    pub module_sha256: String,
    pub wasmtime_version: String,
    pub source_host: String,
    pub source_arch: String,
    pub cpu_model: String,
    pub counter_hint: Option<i64>,
    /// Seconds since the Unix epoch, from the source machine's wall clock.
    pub created_at: u64,
    /// Integrity of the other three files, so a truncated or edited copy is
    /// refused rather than resumed with corrupt state.
    pub memory_sha256: String,
    pub memory_pages: u64,
    pub globals_sha256: String,
    pub wasi_sha256: String,
    /// Address of the Asyncify data buffer in linear memory (async mode only).
    pub asyncify_buffer: Option<u32>,
    pub hops: Vec<Hop>,
}

/// A Wasm global's value, stored as bits so floats round-trip exactly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", content = "bits", rename_all = "lowercase")]
pub(crate) enum GlobalValue {
    I32(u32),
    I64(u64),
    F32(u32),
    F64(u64),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Preopen {
    pub guest: String,
    /// Where it was on the source machine. Informational: each host passes
    /// its own path with `--dir`, but the guest paths must match in order.
    pub host: String,
}

/// The WASI state the guest can observe outside linear memory.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct WasiState {
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    /// In order: WASI preview 1 numbers preopens from fd 3 in the order they
    /// are added, and wasi-libc caches those numbers in linear memory.
    pub preopens: Vec<Preopen>,
    /// The guest's monotonic clock at the checkpoint. Resume starts the
    /// guest's clock here, so the guest never sees time run backwards.
    pub monotonic_ns: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Capsule {
    pub manifest: Manifest,
    pub memory: Vec<u8>,
    /// Exported mutable globals, by export name, sorted for stable output.
    pub globals: Vec<(String, GlobalValue)>,
    pub wasi: WasiState,
}

pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().fold(String::with_capacity(digest.len() * 2), |mut hex, byte| {
        write!(hex, "{byte:02x}").expect("writing to a String cannot fail");
        hex
    })
}

fn to_json<T: Serialize>(value: &T) -> Result<Vec<u8>> {
    let mut out = serde_json::to_vec_pretty(value)?;
    out.push(b'\n');
    Ok(out)
}

impl Capsule {
    /// Writes the four files. The manifest goes last and is the commit point:
    /// a directory without one is not a capsule.
    pub(crate) fn save(&mut self, dir: &Path) -> Result<String> {
        fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        let globals = to_json(&self.globals)?;
        let wasi = to_json(&self.wasi)?;
        self.manifest.memory_sha256 = sha256_hex(&self.memory);
        self.manifest.memory_pages = (self.memory.len() / WASM_PAGE) as u64;
        self.manifest.globals_sha256 = sha256_hex(&globals);
        self.manifest.wasi_sha256 = sha256_hex(&wasi);
        let manifest = to_json(&self.manifest)?;
        let _ = fs::remove_file(dir.join("manifest.json"));
        fs::write(dir.join("memory.bin"), &self.memory)?;
        fs::write(dir.join("globals.json"), &globals)?;
        fs::write(dir.join("wasi.json"), &wasi)?;
        fs::write(dir.join("manifest.json"), &manifest)?;
        Ok(sha256_hex(&manifest))
    }

    /// Reads and verifies a capsule. Returns it and the sha256 of its manifest
    /// (the capsule's identity: the manifest pins the other files' hashes).
    pub(crate) fn load(dir: &Path) -> Result<(Capsule, String)> {
        let read = |name: &str| fs::read(dir.join(name)).with_context(|| format!("capsule file {name} missing"));
        let manifest_bytes = read("manifest.json")?;
        let manifest: Manifest = serde_json::from_slice(&manifest_bytes).context("manifest.json does not parse")?;
        if manifest.version != FORMAT_VERSION {
            bail!("capsule format version {} is not the supported {FORMAT_VERSION}", manifest.version);
        }
        if manifest.wasmtime_version != WASMTIME_VERSION {
            bail!(
                "capsule written by wasmtime {} but this host is wasmtime {WASMTIME_VERSION}",
                manifest.wasmtime_version
            );
        }
        let memory = read("memory.bin")?;
        let globals_bytes = read("globals.json")?;
        let wasi_bytes = read("wasi.json")?;
        check_hash("memory.bin", &memory, &manifest.memory_sha256)?;
        check_hash("globals.json", &globals_bytes, &manifest.globals_sha256)?;
        check_hash("wasi.json", &wasi_bytes, &manifest.wasi_sha256)?;
        if memory.len() % WASM_PAGE != 0 || (memory.len() / WASM_PAGE) as u64 != manifest.memory_pages {
            bail!(
                "memory.bin is {} bytes, not the {} pages of 64 KiB the manifest records",
                memory.len(),
                manifest.memory_pages
            );
        }
        if manifest.mode == Mode::Async && manifest.asyncify_buffer.is_none() {
            bail!("async capsule has no asyncify_buffer");
        }
        let globals = serde_json::from_slice(&globals_bytes).context("globals.json does not parse")?;
        let wasi = serde_json::from_slice(&wasi_bytes).context("wasi.json does not parse")?;
        let capsule = Capsule { manifest, memory, globals, wasi };
        Ok((capsule, sha256_hex(&manifest_bytes)))
    }

    /// Refuses to resume into a module other than the one that was paused.
    /// Restoring memory into a different module would run its code against
    /// another program's data layout.
    pub(crate) fn check_module(&self, module_sha256: &str) -> Result<()> {
        if self.manifest.module_sha256 != module_sha256 {
            bail!(
                "module_sha256 mismatch: capsule is for {} but the module is {}",
                self.manifest.module_sha256,
                module_sha256
            );
        }
        Ok(())
    }
}

/// The Wasm page size, fixed by the spec.
pub(crate) const WASM_PAGE: usize = 64 * 1024;

fn check_hash(name: &str, bytes: &[u8], want: &str) -> Result<()> {
    let got = sha256_hex(bytes);
    if got != want {
        bail!("{name} sha256 is {got}, the manifest says {want}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Capsule {
        Capsule {
            manifest: Manifest {
                version: FORMAT_VERSION,
                mode: Mode::Step,
                entry: "step".into(),
                module_sha256: "ab".repeat(32),
                wasmtime_version: WASMTIME_VERSION.into(),
                source_host: "h1".into(),
                source_arch: "x86_64".into(),
                cpu_model: "test".into(),
                counter_hint: Some(7),
                created_at: 0,
                memory_sha256: String::new(),
                memory_pages: 0,
                globals_sha256: String::new(),
                wasi_sha256: String::new(),
                asyncify_buffer: None,
                hops: vec![],
            },
            memory: vec![7; WASM_PAGE],
            globals: vec![("__stack_pointer".into(), GlobalValue::I32(1024))],
            wasi: WasiState { args: vec!["g".into()], env: vec![], preopens: vec![], monotonic_ns: 5 },
        }
    }

    fn tempdir(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("tc-capsule-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        d
    }

    #[test]
    fn round_trip() {
        let d = tempdir("rt");
        let mut c = sample();
        let id = c.save(&d).unwrap();
        let (back, id2) = Capsule::load(&d).unwrap();
        assert_eq!(back, c);
        assert_eq!(id, id2);
    }

    #[test]
    fn each_file_is_required() {
        for name in ["manifest.json", "memory.bin", "globals.json", "wasi.json"] {
            let d = tempdir(&format!("missing-{name}"));
            sample().save(&d).unwrap();
            fs::remove_file(d.join(name)).unwrap();
            let err = Capsule::load(&d).unwrap_err().to_string();
            assert!(err.contains(name), "{name}: {err}");
        }
    }

    #[test]
    fn each_file_is_hash_checked() {
        for name in ["memory.bin", "globals.json", "wasi.json"] {
            let d = tempdir(&format!("tamper-{name}"));
            sample().save(&d).unwrap();
            let mut bytes = fs::read(d.join(name)).unwrap();
            bytes[1] ^= 1;
            fs::write(d.join(name), bytes).unwrap();
            let err = Capsule::load(&d).unwrap_err().to_string();
            assert!(err.contains(&format!("{name} sha256")), "{name}: {err}");
        }
    }

    #[test]
    fn page_count_is_checked() {
        let d = tempdir("pages");
        let mut c = sample();
        c.save(&d).unwrap();
        // Rewrite the manifest with a wrong page count but a consistent hash.
        let mut m = c.manifest.clone();
        m.memory_pages = 2;
        fs::write(d.join("manifest.json"), to_json(&m).unwrap()).unwrap();
        let err = Capsule::load(&d).unwrap_err().to_string();
        assert!(err.contains("pages"), "{err}");
    }

    #[test]
    fn versions_are_checked() {
        let d = tempdir("ver");
        let mut c = sample();
        c.save(&d).unwrap();
        let mut m = c.manifest.clone();
        m.version = 99;
        fs::write(d.join("manifest.json"), to_json(&m).unwrap()).unwrap();
        assert!(Capsule::load(&d).unwrap_err().to_string().contains("format version"));
        let mut m = c.manifest.clone();
        m.wasmtime_version = "49.0.0".into();
        fs::write(d.join("manifest.json"), to_json(&m).unwrap()).unwrap();
        assert!(Capsule::load(&d).unwrap_err().to_string().contains("wasmtime 49.0.0"));
    }

    #[test]
    fn async_needs_a_buffer() {
        let d = tempdir("async");
        let mut c = sample();
        c.manifest.mode = Mode::Async;
        c.save(&d).unwrap();
        assert!(Capsule::load(&d).unwrap_err().to_string().contains("asyncify_buffer"));
    }

    #[test]
    fn module_hash_is_checked() {
        let c = sample();
        assert!(c.check_module(&"ab".repeat(32)).is_ok());
        assert!(c.check_module(&"cd".repeat(32)).unwrap_err().to_string().contains("mismatch"));
    }

    #[test]
    fn wasmtime_pin_matches_cargo_lock() {
        let lock = include_str!("../../../Cargo.lock");
        let want = format!("name = \"wasmtime\"\nversion = \"{WASMTIME_VERSION}\"");
        assert!(lock.contains(&want), "Cargo.lock does not pin wasmtime {WASMTIME_VERSION}");
    }
}
