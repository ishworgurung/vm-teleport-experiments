//! `tc`: the Wasm host of these experiments. Runs a guest, pauses it into a capsule, and
//! resumes a capsule, on whichever ISA this binary was built for.
//!
//! ```text
//! tc start   --module M --mode step|async [--steps N] [--entry F]
//!            [--arg A]... [--dir HOST::GUEST]... --out CAPSULE
//! tc resume  --module M --capsule CAPSULE [--steps N] [--dir HOST::GUEST]...
//!            [--out CAPSULE]
//! tc precompile --module M --target TRIPLE
//! tc inspect --capsule CAPSULE
//! ```
//!
//! Step mode calls `step()` N times and pauses between calls. Async mode calls
//! the entry export and pauses at the guest's next `ckpt.checkpoint()`. On
//! resume, `--out` asks for another pause; without it the guest runs to the end.

mod capsule;
mod cpu;
mod runtime;

use std::path::{Path, PathBuf};

use wasmtime::error::Context;
use wasmtime::{Result, bail};

use capsule::{Capsule, Mode};
use runtime::{Guest, Launch, Outcome};

#[derive(Debug, Default)]
struct Options {
    module: Option<PathBuf>,
    mode: Option<Mode>,
    steps: u64,
    entry: Option<String>,
    guest_args: Vec<String>,
    dirs: Vec<(PathBuf, String)>,
    out: Option<PathBuf>,
    capsule: Option<PathBuf>,
    target: Option<String>,
}

fn parse(mut it: impl Iterator<Item = String>) -> Result<Options> {
    let mut a = Options::default();
    while let Some(flag) = it.next() {
        let mut val = || it.next().with_context(|| format!("{flag} needs a value"));
        match flag.as_str() {
            "--module" => a.module = Some(val()?.into()),
            "--mode" => {
                a.mode = Some(match val()?.as_str() {
                    "step" => Mode::Step,
                    "async" => Mode::Async,
                    m => bail!("unknown mode {m}"),
                });
            }
            "--steps" => a.steps = val()?.parse::<u64>().context("--steps")?,
            "--entry" => a.entry = Some(val()?),
            "--arg" => a.guest_args.push(val()?),
            "--dir" => {
                let v = val()?;
                let (h, g) = v.split_once("::").with_context(|| format!("--dir {v}: want HOST::GUEST"))?;
                a.dirs.push((h.into(), g.into()));
            }
            "--out" => a.out = Some(val()?.into()),
            "--capsule" => a.capsule = Some(val()?.into()),
            "--target" => a.target = Some(val()?),
            f => bail!("unknown flag {f}"),
        }
    }
    Ok(a)
}

fn short(sha: &str) -> &str {
    &sha[..12.min(sha.len())]
}

/// The line teleport.sh shows for each hop.
fn report(verb: &str, capsule: &Capsule, id: &str) {
    let m = &capsule.manifest;
    let counter = m.counter_hint.map_or("-".into(), |c| c.to_string());
    println!(
        "tc: {verb} host={} arch={} cpu=\"{}\" counter={counter} capsule=sha256:{} module=sha256:{} memory={}KiB",
        m.source_host,
        m.source_arch,
        m.cpu_model,
        short(id),
        short(&m.module_sha256),
        capsule.memory.len() / 1024,
    );
}

fn save(
    guest: &mut Guest,
    mode: Mode,
    entry: &str,
    prior: Option<&capsule::Manifest>,
    hint: Option<i64>,
    out: &Path,
) -> Result<()> {
    let mut c = guest.snapshot(mode, entry, prior, hint)?;
    let id = c.save(out)?;
    report("checkpoint", &c, &id);
    Ok(())
}

fn main() -> Result<()> {
    let mut argv = std::env::args().skip(1);
    let cmd = argv.next().unwrap_or_default();
    let a = parse(argv)?;
    match cmd.as_str() {
        "start" => {
            let module = a.module.context("--module is required")?;
            let mode = a.mode.context("--mode is required")?;
            let out = a.out.context("--out is required")?;
            let mut guest_args = a.guest_args;
            if guest_args.is_empty() {
                guest_args.push(module.file_name().map_or_default(|f| f.to_string_lossy().into_owned()));
            }
            let mut g = Guest::fresh(Launch { module_path: module, args: guest_args, dirs: a.dirs, capture: None })?;
            match mode {
                Mode::Step => {
                    let last = g.step(a.steps)?;
                    save(&mut g, mode, "step", None, Some(last), &out)?;
                }
                Mode::Async => {
                    let entry = a.entry.unwrap_or_else(|| "_start".into());
                    match g.run_async(&entry, false, true)? {
                        Outcome::Paused => save(&mut g, mode, &entry, None, None, &out)?,
                        Outcome::Finished(code) => println!("tc: guest finished (exit {code}) before any checkpoint"),
                    }
                }
            }
        }
        "resume" => {
            let dir = a.capsule.context("--capsule is required")?;
            let module = a.module.context("--module is required")?;
            let (c, id) = Capsule::load(&dir)?;
            // Each host has its own paths; default to the source's.
            let dirs = if a.dirs.is_empty() {
                c.wasi.preopens.iter().map(|p| (PathBuf::from(&p.host), p.guest.clone())).collect()
            } else {
                a.dirs
            };
            let launch = Launch { module_path: module, args: c.wasi.args.clone(), dirs, capture: None };
            let mut g = Guest::restore(launch, &c)?;
            println!(
                "tc: restored on {} ({}, \"{}\") from capsule=sha256:{} written on {} ({}) counter={} module=sha256:{} verified",
                cpu::hostname(),
                std::env::consts::ARCH,
                cpu::model(),
                short(&id),
                c.manifest.source_host,
                c.manifest.source_arch,
                c.manifest.counter_hint.map_or("-".into(), |v| v.to_string()),
                short(g.module_sha256()),
            );
            match c.manifest.mode {
                Mode::Step => {
                    let last = g.step(a.steps)?;
                    match &a.out {
                        Some(out) => save(&mut g, Mode::Step, "step", Some(&c.manifest), Some(last), out)?,
                        None => println!("tc: ran to counter={last}, done"),
                    }
                }
                Mode::Async => {
                    let entry = c.manifest.entry.clone();
                    match (g.run_async(&entry, true, a.out.is_some())?, &a.out) {
                        (Outcome::Paused, Some(out)) => {
                            save(&mut g, Mode::Async, &entry, Some(&c.manifest), None, out)?;
                        }
                        (Outcome::Finished(code), _) => println!("tc: guest finished (exit {code})"),
                        (Outcome::Paused, None) => unreachable!("pauses only when --out is given"),
                    }
                }
            }
        }
        "precompile" => {
            let module = a.module.context("--module is required")?;
            let target = a.target.context("--target is required")?;
            println!("{}", runtime::precompile(&module, &target)?.display());
        }
        "inspect" => {
            let (c, id) = Capsule::load(&a.capsule.context("--capsule is required")?)?;
            println!("capsule sha256:{id} (verified)");
            println!("{}", serde_json::to_string_pretty(&c.manifest)?);
        }
        _ => bail!("usage: tc start|resume|precompile|inspect ... (see the source header)"),
    }
    Ok(())
}
