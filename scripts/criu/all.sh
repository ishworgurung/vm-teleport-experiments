#!/usr/bin/env bash
# Phase 4, every case in order, output to results/criu/. Reboots h4 through
# three CPU models and leaves it on its default (EPYC-Genoa). Needs h1, h2
# and h4 up (`make up up-h4`).
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/say.sh
make -s -C guests/criu-counter
out=results/criu
mkdir -p "$out"
total=11
n=0
declare -a titles summaries
# probe HOST FILE: what the CPU of HOST lets a program do (isa-probe).
probe() {
    n=$((n + 1)); titles[n]="what the CPU of $1 allows"
    cp build/isa-probe "vms/shared/$1/criu/"
    {
        say_step "$n" "$total" "$1: what its CPU allows. $(vm_desc "$1" | cut -d: -f2- | sed 's/^ //')"
        say_do "run isa-probe on $1: it reads the CPU's feature bits, then runs one AVX and one AVX2 instruction (vector instructions that glibc uses when they exist)"
        "vms/$1.sh" ssh /mnt/shared/criu/isa-probe | say_quote prog
    } | tee "$out/$2"
    summaries[n]=""
}
# case TITLE FILE ARGS...: one CRIU move, and its one-line verdict.
case_() {
    n=$((n + 1)); titles[n]=$1
    local file=$2; shift 2
    STEP="$n/$total" TITLE="$1" scripts/criu/one.sh "${@:2}" | tee "$out/$file" || true
    summaries[n]=$(grep -m1 '^  so ' "$out/$file" | sed 's/^  so *//; s/\. .*//; s/\.$//' || true)
}
h4_as() { vms/h4.sh down >/dev/null; H4_CPU=$1 vms/h4.sh up 2>/dev/null; vms/h4.sh wait; mkdir -p vms/shared/h4/criu; }

say_head "Move a native program with CRIU between hosts" \
    "Can CRIU move a running native program to a host with another CPU, and when does it fail?" \
    "A counter written in C runs on h1. CRIU (a Linux tool that saves a running process to files and recreates it) dumps it, and the dump is restored on another host: an Arm host (h2), and an x86-64 host (h4) that is rebooted with three CPU models in turn: EPYC-Genoa, Opteron_G4 and Denverton."
mkdir -p vms/shared/h1/criu
probe h1 isa-probe-h1.txt
case_ "h1 to h2: x86-64 to Arm, no options" h1-h2.txt "h1 to h2 (x86-64 to Arm), no options" h1 h2

h4_as EPYC-Genoa
case_ "h1 to h4 (EPYC-Genoa), no options" h1-h4-genoa.txt "h1 to h4 (CPU model EPYC-Genoa), no options" h1 h4
case_ "h1 to h4 (EPYC-Genoa), --cpu-cap=all" h1-h4-genoa-cpucap-check.txt "h1 to h4 (EPYC-Genoa), strict CPU check (--cpu-cap=all)" h1 h4 --criu-dump-args --cpu-cap=all --criu-restore-args --cpu-cap=all

h4_as Opteron_G4
probe h4 isa-probe-h4-opteron.txt
case_ "h1 to h4 (Opteron_G4), no options" h1-h4-opteron-default.txt "h1 to h4 (CPU model Opteron_G4: AVX, no AVX2), no options" h1 h4

h4_as Denverton
probe h4 isa-probe-h4-denverton.txt
case_ "h1 to h4 (Denverton), no options" h1-h4-denverton-default.txt "h1 to h4 (CPU model Denverton: no AVX), no options" h1 h4
case_ "h1 to h4 (Denverton), --cpu-cap=none" h1-h4-denverton-cpucap-none.txt "h1 to h4 (Denverton), CPU check switched off (--cpu-cap=none)" h1 h4 --criu-restore-args --cpu-cap=none
case_ "h1 to h4 (Denverton), --cpu-cap=all" h1-h4-denverton-cpucap-check.txt "h1 to h4 (Denverton), strict CPU check (--cpu-cap=all)" h1 h4 --criu-dump-args --cpu-cap=all --criu-restore-args --cpu-cap=all
case_ "h1 to h4 (Denverton), glibc told to avoid AVX" h1-h4-denverton-masked.txt "h1 to h4 (Denverton), source started with glibc told to avoid AVX2 and AVX" h1 h4 --tunables glibc.cpu.hwcaps=-AVX2,-AVX

say_section "Control: the same move with the WebAssembly counters, on the same Denverton h4 (no CRIU)"
NO_HEAD=1 scripts/teleport.sh wasm-step h1 h4 | tee "$out/wasm-step-h1-h4-denverton.txt"
NO_HEAD=1 scripts/teleport.sh wasm-async h1 h4 | tee "$out/wasm-async-h1-h4-denverton.txt"

h4_as EPYC-Genoa
lines=()
for i in $(seq "$total"); do
    [[ -n ${summaries[i]} ]] && lines+=("$i. ${titles[i]}: ${summaries[i]}")
done
lines+=("Control: both WebAssembly counters ran to the end on the Denverton h4 without an error. This script does not check their values; see the two transcripts above.")
say_result "DONE ($total steps run)" "${lines[@]}"
echo "(per-case transcripts are in $out/)"
