#!/usr/bin/env bash
# Download the Debian 13 (trixie) "generic" cloud images for the three ISAs.
#
# "generic" rather than "genericcloud": the cloud kernel flavour drops drivers
# (9p among them) that the shared directory needs, and riscv64 has no
# genericcloud image at all. Firmware comes from the distro packages
# (edk2-aarch64, edk2-riscv64), not from here; vms/common.sh checks for it.
#
# Each image is checked against Debian's SHA512SUMS before it is used.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p images
base=https://cloud.debian.org/images/cloud/trixie/latest
curl -fsSL "$base/SHA512SUMS" -o images/SHA512SUMS
for arch in amd64 arm64 riscv64; do
    f=debian-13-generic-$arch.qcow2
    if [[ ! -f images/$f ]]; then
        echo "fetching $f"
        curl -fL --retry 3 "$base/$f" -o "images/$f.part"
        mv "images/$f.part" "images/$f"
    fi
done
(cd images && grep -E 'debian-13-generic-(amd64|arm64|riscv64)\.qcow2$' SHA512SUMS | sha512sum -c -)
