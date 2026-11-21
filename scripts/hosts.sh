#!/usr/bin/env bash
# Show what each running VM is: its architecture, the CPU that QEMU presents,
# and its kernel. The SSH port is the one the VM listens on, on this machine.
#
#   scripts/hosts.sh [HOST...]       (default: h1 h2 h3 h4)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/say.sh
source scripts/lib/say.sh

hosts=("$@")
(( ${#hosts[@]} )) || hosts=(h1 h2 h3 h4)

say_head "Show the four hosts" \
    "Which architecture, CPU model and kernel does each VM have?" \
    "The CPU line is what the guest kernel reads from /proc/cpuinfo. x86-64 reports a model name. Arm reports an implementer and a part number. RISC-V reports an ISA string."
n=0
for h in "${hosts[@]}"; do
    n=$((n + 1))
    say_step "$n" "${#hosts[@]}" "$(vm_desc "$h")"
    say_do "ask $h for its architecture, CPU and kernel"
    out=$("vms/$h.sh" ssh "uname -m; grep -m3 -E '^(model name|CPU part|CPU implementer|isa)' /proc/cpuinfo | tr -s '\\t ' ' '; uname -r")
    say_quote raw <<< "$out"
done
say_result "DONE (${#hosts[@]} hosts shown)"
