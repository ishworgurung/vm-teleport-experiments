# Phase 4: CRIU negative controls

Run here with `make criu` ([scripts/criu/all.sh](../scripts/criu/all.sh)); the raw output of
every case is in [criu/](criu/). CRIU (Checkpoint/Restore In Userspace: a
Linux tool that saves a running process to image files and recreates it from
them) 4.1.1, Debian 13, kernel 6.12.113. The source is always h1
(`-cpu Icelake-Server` on KVM), and the process is
[guests/criu-counter/counter.c](../guests/criu-counter/counter.c), dynamically
linked against glibc 2.41.

| Move | Target `-cpu` | Options | `criu restore` | Then | Why |
|---|---|---|---|---|---|
| h1 → h2 | `neoverse-n1` (aarch64, TCG) | default | exit 1: `Core march mismatch 1` | — | The image holds x86-64 registers and machine code |
| h1 → h4 | `EPYC-Genoa` (KVM) | default | exit 0 | counter carries on, same PID | Intel to AMD is fine when every instruction glibc chose exists on the target |
| h1 → h4 | `EPYC-Genoa` | `--cpu-cap=all` on dump and restore | exit 1: `CPU instruction capabilities do not match run time` | — | The strict check refuses a move that works |
| h1 → h4 | `Opteron_G4` (AVX, no AVX2) | default | exit 0 | counter carries on | Under KVM, AVX2 instructions still run although CPUID hides them (probe below) |
| h1 → h4 | `Denverton` (no AVX) | default | exit 0 | dies at once: `trap invalid opcode ... in libc.so.6[164c40,...]` | glibc chose `__strchrnul_avx2` on h1; its first instruction, `vmovd`, needs AVX state the target never enables |
| h1 → h4 | `Denverton` | `--cpu-cap=none` | exit 0 | same trap | No check at all |
| h1 → h4 | `Denverton` | `--cpu-cap=all` on dump and restore | exit 1: `CPU xfeatures has unsupported bits (0x204)` | — | 0x204 = YMM (bit 2) + PKRU (bit 9) state, which h1 has and the target lacks |
| h1 → h4 | `Denverton` | source started with `GLIBC_TUNABLES=glibc.cpu.hwcaps=-AVX2,-AVX` | exit 0 | counter carries on | glibc bound SSE2 string routines at start-up |
| h1 → h4 | `Denverton` | the Wasm counters, `teleport.sh wasm-step` and `wasm-async` | — | both finish (2000; `sum_sq` as expected) | wasmtime compiles the module on the target, for the target's CPU |

## What the CPU actually allows (isa-probe)

[isa-probe.c](../guests/criu-counter/isa-probe.c) prints CPUID's AVX and AVX2
bits and XCR0, then executes one AVX and one AVX2 instruction:

| Host | CPUID AVX / AVX2 | XCR0 | `vxorps ymm` (AVX) | `vpaddd ymm` (AVX2) |
|---|---|---|---|---|
| h1 `Icelake-Server` | 1 / 1 | `0x207` | ran | ran |
| h4 `Opteron_G4` | 1 / **0** | `0x7` | ran | **ran** |
| h4 `Denverton` | 0 / 0 | `0x3` (no YMM) | SIGILL | SIGILL |

## Mapping the trap to a function

The kernel names the faulting library and offset: `libc.so.6[164c40,...]`.
h1's `libc.so.6` (Debian `2.41-12+deb13u4`, build ID
`5e5b51f4c39af9ac589408c1dc432ba390a273cc`), with its debug symbols from
`https://debuginfod.debian.net/buildid/<id>/debuginfo`:

```text
$ addr2line -f -e libc.debug 0x164c40
__strchrnul_avx2
./string/../sysdeps/x86_64/multiarch/strchr-avx2.S:55
$ objdump -d --start-address=0x164c40 --stop-address=0x164c50 libc.so.6
  164c40:       c5 f9 6e c6             vmovd  %esi,%xmm0
  164c44:       89 f8                   mov    %edi,%eax
  164c46:       25 ff 0f 00 00          and    $0xfff,%eax
  164c4b:       c4 e2 7d 78 c0          vpbroadcastb %xmm0,%ymm0
```

## The glibc tunable, measured

`ld.so --list-diagnostics` on h1, with and without the tunable. These are the
lines that change:

```text
                     (none)              glibc.cpu.hwcaps=-AVX2,-AVX
dl_platform          "haswell"           "x86_64"
features[0x0].active[0x2]  0x7ed83203    0x6ed83203    (CPUID 1 ECX bit 28: AVX)
features[0x1].active[0x1]  0x18c0329     0x18c0309     (CPUID 7 EBX bit 5: AVX2)
```

The older spelling `glibc.cpu.hwcaps=-AVX2_Usable` changed nothing on this
glibc.

## Not run

The original plan's case for this experiment, an AVX-512 source restored on a CPU
without AVX-512, could not be set up. The CPU of the machine used for these runs
has no AVX-512, so KVM drops it (the warning is in `vms/run/h1.qemu.log` after
`make up`). QEMU 11.1.2's TCG does not emulate it
either: `TCG doesn't support requested feature: CPUID[eax=07h,ecx=00h].EBX.avx512f`.
The Denverton case shows the same mechanism, a missing XSAVE state component,
using AVX instead.
