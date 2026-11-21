#!/usr/bin/env bash
# h1: x86_64, Intel Icelake-Server model on KVM (an Intel cloud VM). KVM drops the AVX-512, HLE and RTM bits this host CPU lacks; vms/run/h1.qemu.log keeps the warnings.
export NAME=h1 ARCH=amd64 PORT=$(( ${SSH_PORT_BASE:-2220} + 1 )) CPU=${H1_CPU:-Icelake-Server} ACCEL=${H1_ACCEL:-kvm} PACKAGES="criu"
export L2MAC=52:54:00:50:00:01   # used only when started with L2=1
# shellcheck source=vms/common.sh
source "$(dirname "$0")/common.sh"
vm_main "$@"
