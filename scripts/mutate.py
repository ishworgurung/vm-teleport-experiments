#!/usr/bin/env python3
"""Mutation sweep for the host's checks .

Each mutant deletes or disables one check in src/. `cargo test` must then
fail; a mutant that survives means no test depends on that check. The source
is restored after every mutant, also on Ctrl-C.

Run it with `make mutate` from the repository root.
"""

import pathlib
import subprocess
import sys

# The crate whose checks are mutated. `cargo test` runs from its directory.
CRATE = pathlib.Path(__file__).resolve().parents[1] / "crates" / "tc"

# (file, exact text to replace, replacement, what the mutant disables)
MUTANTS = [
    (
        "src/capsule.rs",
        "if manifest.version != FORMAT_VERSION {",
        "if false {",
        "format version check",
    ),
    (
        "src/capsule.rs",
        "if manifest.wasmtime_version != WASMTIME_VERSION {",
        "if false {",
        "wasmtime version check",
    ),
    (
        "src/capsule.rs",
        'check_hash("memory.bin", &memory, &manifest.memory_sha256)?;',
        "",
        "memory.bin hash",
    ),
    (
        "src/capsule.rs",
        'check_hash("globals.json", &globals_bytes, &manifest.globals_sha256)?;',
        "",
        "globals.json hash",
    ),
    (
        "src/capsule.rs",
        'check_hash("wasi.json", &wasi_bytes, &manifest.wasi_sha256)?;',
        "",
        "wasi.json hash",
    ),
    ("src/capsule.rs", "if memory.len() % WASM_PAGE != 0 ||", "if false &&", "memory page count"),
    (
        "src/capsule.rs",
        "if manifest.mode == Mode::Async && manifest.asyncify_buffer.is_none() {",
        "if false {",
        "async capsule has a buffer",
    ),
    (
        "src/capsule.rs",
        "if self.manifest.module_sha256 != module_sha256 {",
        "if false {",
        "module_sha256 check",
    ),
    ("src/runtime.rs", "if launch.args != wasi.args {", "if false {", "args check"),
    ("src/runtime.rs", "if guest_paths != want {", "if false {", "preopens check"),
    (
        "src/runtime.rs",
        "if g.store.data().asyncify_buffer != capsule.manifest.asyncify_buffer {",
        "if false {",
        "asyncify buffer address",
    ),
    (
        "src/runtime.rs",
        "if capsule.memory.len() < have {",
        "if false {",
        "memory not smaller than the module",
    ),
    ("src/runtime.rs", "if names != want {", "if false {", "every mutable global restored"),
    (
        "src/runtime.rs",
        '(t, v) => bail!("global {name} is {t} but the capsule holds {v:?}"),',
        "_ => continue,",
        "global type",
    ),
    ("src/runtime.rs", "global.set(&mut g.store, val)?;", "let _ = val;", "globals written back"),
    (
        "src/runtime.rs",
        "memory.data_mut(&mut g.store).copy_from_slice(&capsule.memory);",
        "",
        "memory written back",
    ),
    (
        "src/runtime.rs",
        'if self.instance.get_global(&mut self.store, "__stack_pointer").is_none() {',
        "if false {",
        "__stack_pointer exported",
    ),
    (
        "src/runtime.rs",
        "if rewinding && !self.store.data().rewound {",
        "if false {",
        "rewind reached the checkpoint",
    ),
    (
        "src/runtime.rs",
        'bail!("the module exports no ckpt_buffer: was it built for async mode?");',
        "return Ok(Outcome::Finished(0));",
        "async needs ckpt_buffer",
    ),
    (
        "src/runtime.rs",
        (
            ".ok_or_else(|| format_err!("
            '"ckpt.checkpoint() called but the module is not Asyncify\'d"))?;'
        ),
        '.expect("asyncify_get_state");',
        "checkpoint needs Asyncify",
    ),
    (
        "src/runtime.rs",
        "monotonic_ns: self.clock_ns.load(Ordering::Relaxed),",
        "monotonic_ns: 0,",
        "clock saved in the capsule",
    ),
    (
        "src/runtime.rs",
        "let mut g = Guest::instantiate(launch, wasi.monotonic_ns)?;",
        "let mut g = Guest::instantiate(launch, 0)?;",
        "clock restored from the capsule",
    ),
    (
        "src/runtime.rs",
        "let now = self.start_ns + u64::try_from",
        "let now = u64::try_from",
        "clock offset applied",
    ),
    # Phase 6: the host imports that give a Wasm guest a network connection.
    (
        "src/runtime.rs",
        "const NET_EBADF: i32 = -9;",
        "const NET_EBADF: i32 = 0;",
        "unknown handle is EBADF",
    ),
    (
        "src/runtime.rs",
        "const FIRST_NET_HANDLE: i32 = 100;",
        "const FIRST_NET_HANDLE: i32 = 1;",
        "net handles start above the WASI fds",
    ),
    (
        "src/runtime.rs",
        "        None => NET_EBADF,\n",
        "        None => len,\n",
        "net.send refuses an unknown handle",
    ),
    (
        "src/runtime.rs",
        "        Err(e) => neg_errno(&e),\n    }\n}\n\n/// Import `net.send(",
        "        Err(_) => 0,\n    }\n}\n\n/// Import `net.send(",
        "net.connect reports a failed connect",
    ),
]


def cargo_test() -> bool:
    """Run the crate's tests. True if they all pass."""
    result = subprocess.run(
        ["cargo", "test", "--release", "-q"],
        cwd=CRATE,
        capture_output=True,
        text=True,
        check=False,
    )
    return result.returncode == 0


def main() -> int:
    """Run every mutant. Return 0 if each one is killed by a test."""
    if not cargo_test():
        print("the unmutated tests fail; fix them first")
        return 2
    survivors: list[str] = []
    for rel, old, new, what in MUTANTS:
        path = CRATE / rel
        src = path.read_text()
        if src.count(old) != 1:
            print(f"MUTANT NOT APPLIED ({src.count(old)} matches): {what}")
            survivors.append(what)
            continue
        try:
            path.write_text(src.replace(old, new))
            passed = cargo_test()
        finally:
            path.write_text(src)
        print(f"{'SURVIVED' if passed else 'killed  '}  {what}")
        if passed:
            survivors.append(what)
    print(f"\n{len(MUTANTS) - len(survivors)}/{len(MUTANTS)} mutants killed")
    return 1 if survivors else 0


if __name__ == "__main__":
    sys.exit(main())
