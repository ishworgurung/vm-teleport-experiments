#!/usr/bin/env bash
# h2: aarch64, Arm Neoverse N1 model on TCG emulation (Graviton 2 or Ampere Altra class).
export NAME=h2 ARCH=arm64 PORT=$(( ${SSH_PORT_BASE:-2220} + 2 )) CPU=${H2_CPU:-neoverse-n1} ACCEL=${H2_ACCEL:-tcg} PACKAGES="criu"
# shellcheck source=vms/common.sh
source "$(dirname "$0")/common.sh"
vm_main "$@"
