#!/usr/bin/env bash
# h4: x86_64, AMD EPYC-Genoa model on KVM (an AMD cloud VM). Set H4_CPU=Opteron_G4 for the CRIU feature-mismatch control.
export NAME=h4 ARCH=amd64 PORT=$(( ${SSH_PORT_BASE:-2220} + 4 )) CPU=${H4_CPU:-EPYC-Genoa} ACCEL=${H4_ACCEL:-kvm} PACKAGES="criu"
export L2MAC=52:54:00:50:00:04   # used only when started with L2=1
# shellcheck source=vms/common.sh
source "$(dirname "$0")/common.sh"
vm_main "$@"
