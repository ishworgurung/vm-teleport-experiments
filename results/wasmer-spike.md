# Wasmer journaling spike: not adopted

The [design notes](../docs/design.md) suggest a time-boxed try of Wasmer's journaling
before writing a custom Asyncify host for experiment 2. In fact the host was written
first: it took less time than expected and worked first time (experiment 2 output in
[results.md](../docs/results.md)).
The spike below was run afterwards, so that the record is complete.

**Run here, on the x86_64 machine only, with Wasmer 7.5.0** (`tools/fetch-tools.sh`).

Guest: [guests/wasmer-spike](../guests/wasmer-spike/src/main.rs), a 30-step
loop that sleeps 100 ms per step. It went through `wasm-opt --asyncify` with
default settings (every import may unwind), because Wasmer's journal needs
Asyncify to capture the call stack.

| Attempt | Command (abridged) | Result |
|---|---|---|
| periodic | `wasmer run --journal-writable j.log --snapshot-period 1000 --stop-after-snapshot` | ran all 30 steps, no stop; `j.log` 2048 bytes |
| idle | `--snapshot-on idle --stop-after-snapshot` | same: 30 steps, 2048 bytes |
| timer | `--snapshot-on timer --stop-after-snapshot` | same |
| `interval` | `--snapshot-on interval` | `error: invalid value 'interval' for '--snapshot-on <SNAPSHOT_ON>': invalid or unknown trigger (interval)` |
| resume | `wasmer run --journal j.log` | started again from `spike i=1 sum=1` |

So within the time box no mid-run snapshot was produced on one machine, and
nothing could yet be carried to h2 or h3 (Wasmer does publish
`wasmer-linux-aarch64` and `wasmer-linux-riscv64` builds for 7.5.0, so a
cross-ISA test would be possible if the snapshot worked).

I have not found out *why*. Likely candidates, none verified: the journal may
need a guest built with Wasmer's own toolchain (wasix), or the snapshot may
happen only at points this guest never reaches. This is a record of one short
attempt, not a verdict on Wasmer journaling.

**Route taken:** the Asyncify host in this repository (`crates/tc/src/runtime.rs`). Its
capsule (memory bytes plus the exported mutable globals) matches the shape
that the [design notes](../docs/design.md) attribute to Weave. I did not read Weave's code.
