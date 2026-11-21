#!/usr/bin/env bash
# h3: riscv64, QEMU's generic rv64 model on TCG emulation (a RISC-V board). No criu: Debian does not build it for riscv64.
export NAME=h3 ARCH=riscv64 PORT=$(( ${SSH_PORT_BASE:-2220} + 3 )) CPU=${H3_CPU:-rv64} ACCEL=${H3_ACCEL:-tcg} PACKAGES=""
# shellcheck source=vms/common.sh
source "$(dirname "$0")/common.sh"
vm_main "$@"
