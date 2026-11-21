# Capsule format, version 0

A capsule is everything [`tc`](../crates/tc/src/main.rs) needs to resume a paused
Wasm instance on another machine, of any ISA (instruction set architecture:
the machine language a CPU runs, such as x86-64, AArch64 or RISC-V). It is a
directory of four files. The code that writes and checks them is
[crates/tc/src/capsule.rs](../crates/tc/src/capsule.rs); this page describes what it
does, and the examples are from a real capsule.

| File | Content |
|---|---|
| `manifest.json` | What was paused, where, and the sha256 of the other three files |
| `memory.bin` | The instance's whole linear memory, raw, a multiple of 64 KiB |
| `globals.json` | Every exported mutable global, by name, as a typed value |
| `wasi.json` | The WASI (WebAssembly System Interface: the guest's POSIX-like view of files, clocks and arguments) state the guest can see outside its memory |

None of the four holds anything specific to the CPU that wrote it. Linear
memory is a byte array whose byte order the Wasm spec fixes (little-endian),
globals are Wasm values, and machine code is never saved: each host compiles
the module for its own CPU.

## manifest.json

```json
{
  "version": 0,
  "mode": "async",
  "entry": "_start",
  "module_sha256": "cfa2985435f4dffd4ea68c977c7c0b4476089b1600419595abe78aad1437cc57",
  "wasmtime_version": "51.0.0",
  "source_host": "h2",
  "source_arch": "aarch64",
  "cpu_model": "Arm Neoverse-N1 (implementer 0x41, part 0xd0c)",
  "counter_hint": 2000,
  "created_at": 1795256623,
  "memory_sha256": "f7ea57278033092f890a8a940745022108cfee788b967373b4a75226b064b87e",
  "memory_pages": 18,
  "globals_sha256": "85e15c799d4fa3bf3665f9632ecc6a7e578f4176f0f134e7d3884091b5d36aaf",
  "wasi_sha256": "686dd98dbebba28d2e07b9e9de7a5de940cbbc5697ca33b12d43323a023a9426",
  "asyncify_buffer": 1061556,
  "hops": [
    {
      "host": "h1",
      "arch": "x86_64",
      "cpu_model": "Intel Xeon Processor (Icelake)",
      "counter_hint": 1000
    },
    {
      "host": "h2",
      "arch": "aarch64",
      "cpu_model": "Arm Neoverse-N1 (implementer 0x41, part 0xd0c)",
      "counter_hint": 2000
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `version` | Format version, `0`. Restore refuses any other |
| `mode` | `step`: paused between two calls to an exported `step()`, with no Wasm frame live. `async`: paused inside a call at `ckpt.checkpoint()`, with the call stack unwound into linear memory by Asyncify |
| `entry` | The export to call on resume. In async mode, calling it again starts the rewind |
| `module_sha256` | sha256 of the `.wasm` bytes. Restore refuses to resume into any other module |
| `wasmtime_version` | The host's pinned wasmtime. Restore refuses a different version |
| `source_host`, `source_arch`, `cpu_model` | Where it was paused; informational |
| `counter_hint` | The counter at the pause, if the guest reports one (`step()`'s return value, or an exported `ckpt_hint()`); informational |
| `created_at` | Seconds since the Unix epoch, from the source's wall clock; informational |
| `memory_sha256`, `memory_pages` | Integrity and size of `memory.bin` |
| `globals_sha256`, `wasi_sha256` | Integrity of the other two files |
| `asyncify_buffer` | Async mode: linear-memory address of the Asyncify data buffer. Required in async mode |
| `hops` | One entry per pause, in order; a resumed capsule extends its parent's list |

The capsule's identity, printed as `capsule=sha256:...`, is the sha256 of
`manifest.json`. The manifest pins the hashes of the other three files, so
that one hash covers the whole capsule.

PLAN §5 lists `{version, module_sha256, wasmtime_version, source_host,
source_arch, cpu_model, counter_hint, created_at}`. Everything after
`created_at` was added: the per-file hashes, so that a damaged copy is refused;
`mode`, `entry` and `asyncify_buffer` for experiment 2; and `hops` for the demo.

## globals.json

```json
[["__stack_pointer", {"type": "i32", "bits": 1048416}]]
```

A list of `[name, value]` pairs, sorted by name. `type` is `i32`, `i64`,
`f32` or `f64`, and `bits` holds the raw bits as an unsigned integer, so that
floats (NaN payloads included) round-trip exactly.

Only *exported* globals can be read through wasmtime's API. So the guests'
build refuses a module that has a mutable global it does not export
([guests/check-globals.sh](../guests/check-globals.sh)). Its linker flags
export `__stack_pointer`, the C/Rust shadow-stack pointer, which async mode
cannot work without ([results.md](results.md) shows what happens without it).

## wasi.json

```json
{"args": ["async-counter.wasm"], "env": [], "preopens": [], "monotonic_ns": 1603424}
```

| Field | Meaning |
|---|---|
| `args` | The guest's argv. Resume reuses them; a different list is refused |
| `env` | Always empty in these experiments: no environment variables are passed |
| `preopens` | `{guest, host}` pairs, in order. WASI preview 1 numbers them fd 3, 4, ... and wasi-libc caches those numbers in linear memory, so resume must open the same guest paths in the same order. Each host passes its own host paths (`--dir HOST::GUEST`) |
| `monotonic_ns` | The guest's monotonic clock at the pause. Resume starts the guest's clock from this value, so it never runs backwards |

## Checks on restore

All of them fail closed, and each has a test that fails if it is removed
(`make mutate`):

1. all four files present;
2. `version` is 0 and `wasmtime_version` matches this host;
3. the three file hashes match the manifest, and `memory.bin` is
   `memory_pages` × 64 KiB;
4. an async capsule has an `asyncify_buffer`;
5. `args` and the preopen guest paths match;
6. `module_sha256` matches the module being instantiated;
7. the module's Asyncify buffer is at the recorded address;
8. the capsule's memory is at least the module's initial memory;
9. the capsule's globals are exactly the module's exported mutable globals,
   with the same types;
10. on resume in async mode, the rewind reaches `ckpt.checkpoint()`.

## What a capsule does not carry

- **Open files other than the preopens**, sockets, and the file offsets of
  any open file. The guests hold none at a pause. CPython closes the
  script before running it: `pyrun_file` in CPython 3.15.2's
  `Python/pythonrun.c` parses the file, calls `fclose`, then `run_mod`.
- **Tables**, if a guest grows or rewrites them at run time. None of the
  guests does.
- **Wall-clock time**: the guest reads the target's real clock.
- **Compression or dirty-page tracking**: `memory.bin` is the whole memory
  (40 MiB for CPython), even pages that were never touched.
