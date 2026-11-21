#!/usr/bin/env bash
# Phase 4: the CRIU negative controls. Dump the native counter on one host,
# copy the image, restore it on another, and record exactly what happens.
#
#   scripts/criu/one.sh SRC DST [--tunables T] [--criu-dump-args A] [--criu-restore-args A]
#
# e.g. scripts/criu/one.sh h1 h2                         x86-64 -> arm64
#      scripts/criu/one.sh h1 h4                         Intel -> AMD (EPYC-Genoa)
#      H4_CPU=Opteron_G4: see `make criu`, which reboots h4 with that model
# STEP="3/11" and TITLE="..." (set by scripts/criu/all.sh) name the case in the output.
#
# CRIU needs root, the same executable and libraries at the same paths, and a
# free PID on the target. The VMs boot the same Debian image, so the x86-64
# ones meet that; what differs between them is only the CPU.
#
# The commands that run inside the VMs print tagged lines, which this script
# turns into the labelled lines of scripts/lib/say.sh:
#   X a fact (dump-ok, restore-failed 1, ...)   L a line the counter printed
#   E a line of CRIU's own error text           K a line of the kernel log
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/say.sh
src=${1:?SRC} dst=${2:?DST}; shift 2
tunables="" restore_args="" dump_args=""
while (( $# )); do
    case $1 in
    --tunables) tunables=$2; shift 2 ;;
    --criu-restore-args) restore_args=$2; shift 2 ;;
    --criu-dump-args) dump_args=$2; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
    esac
done
step=${STEP:-1/1}
title=${TITLE:-"$src to $dst"}
hostsh() { "vms/$1.sh" ssh "${@:2}"; }
# fact OUTPUT KEY: the text after "X KEY" on the first such line.
fact() { sed -n "s/^X $2 *//p" <<< "$1" | head -1; }
has() { grep -q "^X $2" <<< "$1"; }
# render OUTPUT: show the counter, CRIU and kernel lines with their labels.
render() {
    local line
    while IFS= read -r line; do
        case $line in
        "L "*) say_line prog "${line#L }" ;;
        "E "*|"K "*) say_line raw "${line#? }" ;;
        *) ;;
        esac
    done <<< "$1"
}

for h in "$src" "$dst"; do
    mkdir -p "vms/shared/$h/criu"
    hostsh "$h" 'sudo pkill -x criu-counter; sudo rm -rf /var/tmp/img /var/tmp/criu-counter*' || true
done
cp build/criu-counter "vms/shared/$src/criu/"

say_step "${step%/*}" "${step#*/}" "$title"
if [[ -n $tunables ]]; then
    say_do "on $src ($(vm_desc "$src" | cut -d: -f2- | sed 's/^ //')), start the counter with GLIBC_TUNABLES=$tunables (tells glibc not to use the AVX2 and AVX instructions)"
else
    say_do "on $src ($(vm_desc "$src" | cut -d: -f2- | sed 's/^ //')), start the counter"
fi
out=$(hostsh "$src" "sudo install -m 755 /mnt/shared/criu/criu-counter /var/tmp/criu-counter
    pid=\$(sudo env ${tunables:+GLIBC_TUNABLES=$tunables} sh -c 'setsid /var/tmp/criu-counter > /var/tmp/criu-counter.log 2>&1 < /dev/null & echo \$!')
    sleep 2
    echo \"X started \$pid\"
    tail -1 /var/tmp/criu-counter.log | sed 's/^/L /'
    sudo mkdir -p /var/tmp/img
    if sudo criu dump -t \$pid -D /var/tmp/img -o dump.log -v2 $dump_args; then echo 'X dump-ok'; else echo \"X dump-failed \$?\"; fi
    sudo tar -C /var/tmp -cf /mnt/shared/criu/image.tar img criu-counter criu-counter.log")
say_got "the counter runs as process $(fact "$out" started). Its last line:"
render "$out"
has "$out" dump-ok || { say_result "UNEXPECTED" "criu dump failed on $src"; exit 1; }
say_do "dump it: criu dump ${dump_args:-(no options)}"
say_got "the dump worked, and CRIU stopped the process"
cp "vms/shared/$src/criu/image.tar" "vms/shared/$dst/criu/"
say_next "copy the dump image from $src to $dst ($(du -h "vms/shared/$src/criu/image.tar" | cut -f1))"

say_do "on $dst ($(vm_desc "$dst" | cut -d: -f2- | sed 's/^ //')), restore it: criu restore ${restore_args:-(no options)}, and watch for 2 seconds"
out=$(hostsh "$dst" "sudo tar --warning=no-timestamp -C /var/tmp -xf /mnt/shared/criu/image.tar
    sudo dmesg -C
    if sudo criu restore -D /var/tmp/img -d -o restore.log -v2 $restore_args; then
        echo 'X restore-ok'
    else
        echo \"X restore-failed \$?\"
        sudo grep -E 'Error|error|mismatch|fail' /var/tmp/img/restore.log | head -8 | sed 's/^/E /'
    fi
    sleep 2
    tail -3 /var/tmp/criu-counter.log | sed 's/^/L /'
    echo \"X process \$(pgrep -a -x criu-counter || echo none)\"
    sudo dmesg | grep -E 'criu-counter|traps' | sed 's/^/K /' || true
    sudo pkill -x criu-counter || true")
proc=$(fact "$out" process)
n_last=$(sed -n 's/^L criu-counter n=\([0-9]*\) .*/\1/p' <<< "$out" | tail -1)
if has "$out" restore-failed; then
    say_got "the restore failed. CRIU's error lines, then the counter log that came with the dump image (it shows what was printed on $src before the dump, not a new run):"
    first=$(sed -n 's/^E Error ([^)]*): //p' <<< "$out" | head -1)
    verdict="The restore failed: $first. The process was not moved."
elif [[ $proc == none ]] && grep -q '^K .*invalid opcode' <<< "$out"; then
    say_got "the restore worked, but the process is not running. The counter log ends at n=$n_last, and the kernel log says why:"
    verdict="The restore worked, but the kernel killed the process at once: it ran an instruction that this CPU does not have (invalid opcode)."
elif [[ $proc != none ]]; then
    say_got "the restore worked, and the process is running. The counter log after the restore (the last 3 lines):"
    verdict="The counter carried on after the move: its log reaches n=$n_last, and it is the same process (process ${proc%% *})."
else
    say_got "the restore worked, but the process is not running, and the kernel log has no explanation"
    verdict="UNEXPECTED: the restore worked but the process is gone, with no trap in the kernel log."
fi
render "$out"
printf '\n'
say_line so "$verdict"
