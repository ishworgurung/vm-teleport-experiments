#!/usr/bin/env bash
# h5: x86_64, a small helper VM that only runs scripts/net/server.py on the private
# link of the VIP test (scripts/net/criu-vip.sh). It is not one of the four demo hosts: no
# capsule runs on it, and `make up` does not start it.
export NAME=h5 ARCH=amd64 PORT=$(( ${SSH_PORT_BASE:-2220} + 5 )) CPU=${H5_CPU:-Icelake-Server} ACCEL=${H5_ACCEL:-kvm} MEM=512M SMP=1
export L2MAC=52:54:00:50:00:05
# shellcheck source=vms/common.sh
source "$(dirname "$0")/common.sh"
vm_main "$@"
