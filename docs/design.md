# Design notes

How the experiments are set up, what each one is expected to show, and where this work sits among related projects. The results themselves are in [results.md](results.md), and the capsule format is in [capsule-format.md](capsule-format.md).

The question behind it: **can a running program stop on one CPU and carry on, mid-loop, on a CPU of another kind?** The experiments answer it with a Wasm guest and a host runtime that saves the guest's state into a *capsule*. They run CRIU on the same moves as a control, to show why the Wasm route works and the native one does not.

## Hosts

| Host | QEMU target | `-cpu` model | Accel (on an x86 laptop) | Represents |
|---|---|---|---|---|
| **h1** | `qemu-system-x86_64` | `Icelake-Server` (Intel, AVX-512) | KVM | Intel cloud VM |
| **h2** | `qemu-system-aarch64` | `neoverse-n1` | TCG (emulated) | Graviton / Ampere |
| **h3** | `qemu-system-riscv64` | `rv64` | TCG | RISC-V board |
| h4 | `qemu-system-x86_64` | `EPYC-Genoa` (AMD, Zen 4) | KVM | AMD cloud VM, for the Intel→AMD test. Now the fourth hop of every demo, and rebooted through three CPU models by experiment 4 |
| h5 (experiment 6 only) | `qemu-system-x86_64` | `Icelake-Server` | KVM | A small VM that runs the test server on a private link between h1, h4 and h5. Not a hop; `make up` does not start it |

On Apple Silicon, flip it: h2 runs on HVF, and the x86/RISC-V hosts run on TCG.

If KVM refuses a `-cpu` model the physical CPU lacks, use TCG for that host or pick a model the host CPU supports.

## Experiments and what each shows

| Payload | h1→h2 (x86→arm) | h2→h3 (arm→riscv) | h1→h4 (Intel→AMD) | Lesson |
|---|---|---|---|---|
| **Wasm counter, step-function** (experiment 1) | ✅ | ✅ | ✅ | Linear memory is ISA-neutral |
| **Wasm counter, mid-call via Asyncify** (experiment 2) | ✅ | ✅ | ✅ | The call stack can be made portable too |
| **CPython-on-Wasm counter** (experiment 3) | ✅ | ✅ | ✅ | The interpreter is just bytes |
| CRIU native C counter (experiment 4) | ❌ expected | ❌ expected | ⚠️ ❌ with AVX-512 glibc paths, ✅ with CPU features masked / `GLIBC_TUNABLES` | Native state is tied to the ISA and CPU features |
| Go wasip1 + preemption hook (not built) | not done | not done | not done | Go's resumable functions |
| **Wasm client with an open network connection** (experiment 6) | not run | not run | connection lost, session re-attached, transaction rolled back | The socket belongs to the host process, not to the capsule |
| **CRIU client with an open HTTPS connection** (experiment 6) | not run | not run | open connection kept only with `--tcp-established` and a floating IP on a network that carries it; see [results.md](results.md#8-external-state-what-if-the-program-is-talking-to-a-server) | Kernel TCP state can move, but its address and its path must move too |

Measured outcomes for experiment 4 (from [results/criu.md](../results/criu.md)): h1→h2 fails (`Core march mismatch 1`); h1→h4 works on `EPYC-Genoa`; it dies at once with an invalid-opcode trap on `Denverton` (no AVX) unless glibc was told to skip AVX; the AVX-512 case could not be set up.

The ❌ cells are the point: same counter, same teleport script, different layer.

## Gotchas

| Gotcha | Impact / mitigation |
|---|---|
| TCG is slow (boot ~1 min; Wasm under emulation 10×+ slower) | Fine for a counter; keep loops small |
| `.cwasm` is tied to the wasmtime version + target | Pin the wasmtime version; store the module hash in the manifest |
| riscv64 tooling is the roughest (wasmtime support, firmware) | Budget extra time; fallback runtime: WAMR |
| KVM rejects `-cpu` models the physical CPU lacks | Use TCG for that host, or a supported model |
| Asyncify inflates code size and slows calls | Restrict with `asyncify-imports` |
| NaN canonicalization | Irrelevant for an integer counter; add a float test later (Cranelift NaN canonicalization) |
| Clock jumps across hops | Store the monotonic offset in `wasi.json`; adjust on restore |
| CRIU needs root/caps and matching kernels | Run as root in the VMs; same Debian kernel on h1/h4 |

## Ideas that are not built

- A float/NaN determinism test across hops.
- Dirty-page tracking: send only pages changed since the last capsule; content-addressed 16 MiB chunks like Portal.
- Wire `scripts/teleport.sh` behind a small control plane that picks the next host.

## Prior art (checked November 2026)

Nobody sells mid-run, cross-ISA **Wasm** checkpoint/restore as a product. The only marketed cross-arch mid-run product is Clusy Portal (Python-level, not Wasm). The pieces exist:

| Who | What | Mid-run? | Cross-ISA? | Status | Relevance here |
|---|---|---|---|---|---|
| **Cloudflare Python Workers** | Runs top-level imports at deploy, snapshots Pyodide's Wasm linear memory, ships the snapshot with the code | ❌ init only (no call stack) | Portable by construction; not advertised as a feature | Production | Shows experiment 1 (memory-only snapshot) is production-proven |
| **Wasmer journaling** | Pauses threads; records Wasm memory, stack memory, call stack, open sockets, open files, terminal text into a journal. Requires Asyncify (`wasm-opt`). Triggers: idle, interval, Ctrl-C, explicit | ✅ | Wasm-level; not marketed as cross-ISA | Shipping in the open-source runtime | **Try before writing a custom Asyncify host for experiment 2.** If its snapshots restore on another ISA, experiments 1 and 2 are mostly done |
| **Weave** (github.com/dphilla/weave) | Moves a running module (code, linear memory, globals, tables, host-service state, live call stack down to the exact instruction) between runtime adapters (e.g. wasmtime → Node/V8). Snapshot = memory bytes + a few control globals + host-service blobs | ✅ | ✅ in principle | Open-source project | Reference design for the capsule format and the shadow-stack approach |
| **Wharf / MVVM** (arXiv 2410.15894) | WAMR-based "vessels" that virtualize OS state via WASI; heterogeneous live migration across ISAs and OSes | ✅ | ✅ x86 ↔ ARM | Research | Restore design for compiled (AOT) frames |
| **Wanco** (Kyoto Univ., POPL 2025 SRC) | Wasm AOT compiler instrumented for checkpoint/restore with a platform-neutral snapshot format; reports smaller snapshots and faster C/R than CRIU | ✅ | ✅ | Research prototype | Alternative to Asyncify: instrument at AOT compile time |
| **Live migration of compiled Wasm modules** (Univ. of Padova, J. Systems Architecture 2025) | Injects checkpoint/restore into function bytecode; two strategies, one with small overhead | ✅ | ✅ | Research | Bytecode-injection approach; benchmark ideas |
| Self-hosted Wasm runtime for runtime-neutral C/R (ACM 2025, doi 10.1145/3774898.3778040) | C/R and live migration across heterogeneous Wasm runtimes | ✅ | ✅ | Research | Runtime-neutral angle |
| **Clusy Portal** | Python-level capture (not Wasm); x86 ↔ ARM, GPU ↔ CPU | ✅ at safe points | ✅ | Commercial | Comparison point for experiment 3 |

**Wasmer journaling** was the first thing worth trying before writing a host. The Asyncify host in `crates/tc` was written first and worked, so the Wasmer spike ran afterwards, on one machine only. It produced no mid-run snapshot within its time box, and was not adopted. See [results/wasmer-spike.md](../results/wasmer-spike.md).
