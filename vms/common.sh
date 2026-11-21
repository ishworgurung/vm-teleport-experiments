#!/usr/bin/env bash
# NAME, ARCH, PORT, CPU, ACCEL and PACKAGES are set by the h*.sh script that sources this file.
# shellcheck disable=SC2154
# Shared launcher for the QEMU hosts. Sourced by h1.sh .. h4.sh, which
# set the per-host variables and call `vm_main "$@"`.
#
# Per host:  NAME  ARCH (amd64|arm64|riscv64)  PORT (ssh hostfwd; h1 is SSH_PORT_BASE+1, default 2221)
#            CPU (-cpu model)  ACCEL (kvm|tcg)  PACKAGES (cloud-init)
#
# Each VM boots a copy-on-write overlay of the verified Debian image, gets a
# NoCloud seed (user `teleport`, an SSH key that it generates) and mounts
# vms/shared/<name> at /mnt/shared over 9p. Files the guest writes there
# appear on the host, which is how teleport.sh moves capsules between hosts.
set -euo pipefail

VMS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUN=$VMS/run
QEMU_IMG=${QEMU_IMG:-qemu-img}
MEM=${MEM:-2G}
# UEFI firmware for the Arm and RISC-V VMs (QEMU's "virt" machines have none
# built in). The defaults are where the edk2 packages put it on Arch Linux and
# Fedora. On another distribution, point these at your own copy.
ARM_FW_CODE=${ARM_FW_CODE:-/usr/share/edk2/aarch64/QEMU_EFI.fd}
ARM_FW_VARS=${ARM_FW_VARS:-/usr/share/edk2/aarch64/QEMU_VARS.fd}
RISCV_FW_CODE=${RISCV_FW_CODE:-/usr/share/edk2/riscv64/RISCV_VIRT_CODE.fd}
RISCV_FW_VARS=${RISCV_FW_VARS:-/usr/share/edk2/riscv64/RISCV_VIRT_VARS.fd}
SMP=${SMP:-2}

die() { echo "$NAME: $*" >&2; exit 1; }

ensure_key() {
    mkdir -p "$RUN"
    [[ -f $RUN/id_teleport ]] || ssh-keygen -q -t ed25519 -N '' -C vm-teleport-experiments -f "$RUN/id_teleport"
}

make_seed() {
    local dir=$RUN/$NAME-seed
    rm -rf "$dir"; mkdir -p "$dir"
    printf 'instance-id: %s\nlocal-hostname: %s\n' "$NAME" "$NAME" > "$dir/meta-data"
    {
        echo '#cloud-config'
        echo "hostname: $NAME"
        echo 'users:'
        echo '  - name: teleport'
        echo '    sudo: ALL=(ALL) NOPASSWD:ALL'
        echo '    shell: /bin/bash'
        echo '    ssh_authorized_keys:'
        echo "      - $(cat "$RUN/id_teleport.pub")"
        # Some networks (and the self-hosted CI runner) block plain HTTP. Debian's
        # cloud image points apt at http://, so switch it to https before
        # cloud-init installs the packages. bootcmd runs on every boot, early.
        echo 'bootcmd:'
        echo '  - [sh, -c, "sed -i s,http://,https://,g /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null || true"]'
        if [[ -n ${PACKAGES:-} ]]; then
            echo 'package_update: true'
            echo 'packages:'
            for p in $PACKAGES; do echo "  - $p"; done
        fi
        # nofail: a missing 9p module must not drop the boot into emergency mode.
        echo 'mounts:'
        echo '  - [shared, /mnt/shared, 9p, "trans=virtio,version=9p2000.L,msize=262144,nofail", "0", "0"]'
        echo 'runcmd:'
        echo '  - [sh, -c, "mkdir -p /mnt/shared && (mountpoint -q /mnt/shared || mount /mnt/shared)"]'
        echo '  - [touch, /var/lib/teleport-ready]'
    } > "$dir/user-data"
    genisoimage -quiet -output "$RUN/$NAME-seed.iso" -volid cidata -joliet -rock \
        "$dir/user-data" "$dir/meta-data"
}

make_disk() {
    local img=$VMS/images/debian-13-generic-$ARCH.qcow2
    [[ -f $img ]] || die "missing $img: run vms/fetch-images.sh"
    if [[ ! -f $RUN/$NAME.qcow2 ]]; then
        "$QEMU_IMG" create -q -f qcow2 -F qcow2 -b "$img" "$RUN/$NAME.qcow2" 12G
    fi
}

qemu_cmd() {
    local shared=$VMS/shared/$NAME
    mkdir -p "$shared"
    local common=(
        -name "$NAME" -m "$MEM" -smp "$SMP" -cpu "$CPU"
        -display none -serial "file:$RUN/$NAME.console.log"
        -daemonize -pidfile "$RUN/$NAME.pid"
        -drive "file=$RUN/$NAME.qcow2,if=virtio,format=qcow2"
        -drive "file=$RUN/$NAME-seed.iso,if=virtio,format=raw,readonly=on"
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:22"
        -device "virtio-net-pci,netdev=n0"
        -virtfs "local,path=$shared,mount_tag=shared,security_model=none,id=shared"
    )
    # L2=1 adds a second NIC on a private Ethernet segment shared by every VM
    # started with L2=1 (scripts/net/criu-vip.sh uses it). QEMU's "socket,mcast" netdev
    # sends each frame to a UDP multicast group, so all the VMs that join the
    # same group and port see each other's frames, like ports on a switch. It
    # needs no root, no tap device and no bridge. The MAC is set per host.
    if [[ ${L2:-} == 1 ]]; then
        common+=(-netdev "socket,id=n1,mcast=230.0.0.1:${L2_PORT:-45551}"
                 -device "virtio-net-pci,netdev=n1,mac=$L2MAC")
    fi
    case $ARCH in
    amd64)
        CMD=(qemu-system-x86_64 -machine q35 -accel "$ACCEL" "${common[@]}") ;;
    arm64)
        [[ -f $RUN/$NAME-vars.fd ]] || cp "$ARM_FW_VARS" "$RUN/$NAME-vars.fd"
        CMD=(qemu-system-aarch64 -machine virt -accel "$ACCEL" "${common[@]}"
             -drive "if=pflash,format=raw,readonly=on,file=$ARM_FW_CODE"
             -drive "if=pflash,format=raw,file=$RUN/$NAME-vars.fd") ;;
    riscv64)
        [[ -f $RUN/$NAME-vars.fd ]] || cp "$RISCV_FW_VARS" "$RUN/$NAME-vars.fd"
        CMD=(qemu-system-riscv64 -machine virt -accel "$ACCEL" "${common[@]}"
             -drive "if=pflash,format=raw,readonly=on,file=$RISCV_FW_CODE"
             -drive "if=pflash,format=raw,file=$RUN/$NAME-vars.fd") ;;
    *) die "unknown ARCH $ARCH" ;;
    esac
}

running() { [[ -f $RUN/$NAME.pid ]] && kill -0 "$(cat "$RUN/$NAME.pid")" 2>/dev/null; }

vm_ssh() {
    ssh -q -i "$RUN/id_teleport" -p "$PORT" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes \
        teleport@127.0.0.1 "$@"
}

vm_up() {
    if running; then echo "$NAME: already running"; return 0; fi
    ensure_key; make_disk; make_seed; qemu_cmd
    # QEMU's warnings (for example features KVM or TCG cannot provide for this
    # -cpu model) go to stderr; keep them, they are part of the evidence.
    # Written to a file, not through a pipe: the daemonized QEMU keeps its
    # stderr open, so a pipe reader would wait for it forever.
    "${CMD[@]}" 2> "$RUN/$NAME.qemu.log"
    cat "$RUN/$NAME.qemu.log" >&2
    echo "$NAME: started ($ARCH, -cpu $CPU, $ACCEL), ssh port $PORT"
}

vm_wait() {
    local deadline=$(( SECONDS + ${TIMEOUT:-1800} ))
    until vm_ssh test -f /var/lib/teleport-ready 2>/dev/null; do
        (( SECONDS < deadline )) || die "not ready after ${TIMEOUT:-1800}s (see $RUN/$NAME.console.log)"
        running || die "QEMU exited (see $RUN/$NAME.console.log)"
        sleep 10
    done
    echo "$NAME: ready"
}

vm_down() {
    running || { echo "$NAME: not running"; return 0; }
    vm_ssh sudo poweroff 2>/dev/null || true
    for _ in $(seq 60); do running || break; sleep 1; done
    running && kill "$(cat "$RUN/$NAME.pid")"
    rm -f "$RUN/$NAME.pid"
    echo "$NAME: stopped"
}

vm_main() {
    case ${1:-up} in
    up)    vm_up ;;
    wait)  vm_wait ;;
    down)  vm_down ;;
    ssh)   shift; vm_ssh "$@" ;;
    reset) vm_down; rm -f "$RUN/$NAME.qcow2" "$RUN/$NAME-vars.fd" ;;
    *) echo "usage: $0 up|wait|down|ssh CMD...|reset" >&2; exit 2 ;;
    esac
}
