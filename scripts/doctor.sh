#!/usr/bin/env bash
# Check that this machine can run the experiments, before a long build fails
# halfway. It only looks: it installs nothing and changes nothing.
#
#   scripts/doctor.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/say.sh
source scripts/lib/say.sh
ARM_FW_CODE=${ARM_FW_CODE:-/usr/share/edk2/aarch64/QEMU_EFI.fd}
RISCV_FW_CODE=${RISCV_FW_CODE:-/usr/share/edk2/riscv64/RISCV_VIRT_CODE.fd}

missing=0
# have WHAT HOW-TO-GET-IT COMMAND...: report one required command.
have() {
    local what=$1 hint=$2; shift 2
    if "$@" > /dev/null 2>&1; then say_line ok "$what"; else say_line MISS "$what: $hint"; missing=$((missing + 1)); fi
}
# want_file WHAT HINT FILE: report one required file.
want_file() {
    if [[ -f $3 ]]; then say_line ok "$1 ($3)"; else say_line MISS "$1: $2"; missing=$((missing + 1)); fi
}

say_head "Check this machine" \
    "Does this machine have what the experiments need?" \
    "Only the host needs these. The VMs download their own packages. Lines that say MISS are required."

say_step 1 4 "the Linux host"
say_do "check the kernel and the virtualisation device"
if [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]]; then
    say_line ok "Linux on x86-64 ($(uname -m))"
else
    say_line MISS "these scripts download x86-64 Linux tools: use an x86-64 Linux machine"; missing=$((missing + 1))
fi
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    say_line ok "/dev/kvm is readable and writable: h1, h4 and h5 run on the real CPU"
else
    say_line warn "no access to /dev/kvm: set H1_ACCEL=tcg H4_ACCEL=tcg H5_ACCEL=tcg to emulate them (much slower)"
fi

say_step 2 4 "the Rust toolchain"
say_do "check cargo and the three extra targets that the builds need"
have "cargo" "install Rust from https://rustup.rs" cargo --version
installed=$(rustup target list --installed 2> /dev/null || true)
for target in wasm32-wasip1 aarch64-unknown-linux-musl riscv64gc-unknown-linux-gnu; do
    if grep -qx "$target" <<< "$installed"; then say_line ok "rust target $target"
    else say_line MISS "rust target $target: run rustup target add $target"; missing=$((missing + 1)); fi
done
want=$(sed -n 's/^channel = "\(.*\)"/\1/p' rust-toolchain.toml)
if [[ $(rustc --version 2> /dev/null | cut -d' ' -f2) == "$want" ]]; then say_line ok "rustc $want (rust-toolchain.toml)"
else say_line MISS "rustc $want: rustup reads rust-toolchain.toml and installs it, so run cargo inside this repository"; missing=$((missing + 1)); fi
have "zig" "install zig from https://ziglang.org (the cross C compiler for the Arm and RISC-V builds)" zig version

say_step 3 4 "QEMU and the tools that make the VMs"
say_do "check the three system emulators, qemu-img, an ISO maker, ssh and the download tools"
for q in qemu-system-x86_64 qemu-system-aarch64 qemu-system-riscv64 qemu-img; do
    have "$q" "install QEMU" "$q" --version
done
have "genisoimage" "install genisoimage (the cloud-init seed is an ISO)" command -v genisoimage
have "ssh and ssh-keygen" "install an OpenSSH client" command -v ssh-keygen
for t in curl git rsync openssl tar xz make python3; do have "$t" "install $t" command -v "$t"; done
want_file "UEFI firmware for the Arm VM" "install edk2 for aarch64, or set ARM_FW_CODE" "$ARM_FW_CODE"
want_file "UEFI firmware for the RISC-V VM" "install edk2 for riscv64, or set RISCV_FW_CODE" "$RISCV_FW_CODE"

say_step 4 4 "the checks and linters (only for \`make lint\`)"
say_do "look for the linters"
for t in shellcheck node npx; do
    if command -v "$t" > /dev/null; then say_line ok "$t"; else say_line warn "$t not found: make lint-sh or lint-md will fail"; fi
done
if command -v uvx > /dev/null || command -v ruff > /dev/null; then say_line ok "ruff and pyright (through uv, or installed)"
else say_line warn "neither uvx nor ruff found: make lint-py will fail"; fi

if (( missing )); then
    say_result "FAIL" "$missing required item(s) missing. Install them, then run make doctor again."
    exit 1
fi
say_result "PASS" "everything required is present"
