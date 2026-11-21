#!/usr/bin/env bash
# Phase 6: what the floating-IP runs rely on, checked in the running VMs.
#   1. the private link: each VM's second NIC, and a ping from h1 to h4 and h5
#   2. the tools the images lack: arping, and a working name lookup
# Needs `make up-vip` first. Nothing here changes a VM except the link's
# addresses, which criu-vip.sh sets in the same way (remote.sh l2).
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/say.sh
say_head "Check the private link and the tools that the floating-IP runs need" \
    "Can h1, h4 and h5 reach each other on their private link, and is arping in the VM image?" \
    "arping is the usual tool for announcing an address on a link. This repository sends the announcement with scripts/net/garp.py instead."
for h in h1 h4 h5; do
    mkdir -p "vms/shared/$h/criu-net"
    cp scripts/net/criu-remote.sh "vms/shared/$h/criu-net/remote.sh"
done
for n in 1 4 5; do
    "vms/h$n.sh" ssh "sudo bash /mnt/shared/criu-net/remote.sh l2 $n"
done
say_step 1 2 "the private link"
say_do "show each VM's address on the link"
for h in h1 h4 h5; do
    say_line raw "$h: $("vms/$h.sh" ssh "ip -br addr | grep '192\\.168\\.50\\.'" | tr -s ' ')"
done
say_do "ping h4 and h5 from h1, 2 packets each"
fail=0
for ip in 192.168.50.4 192.168.50.5; do
    res=$(vms/h1.sh ssh "ping -c2 -W2 $ip" | grep -E 'packets transmitted|^rtt')
    say_quote raw <<< "$res"
    grep -q ' 0% packet loss' <<< "$res" || fail=1
done
say_step 2 2 "the tools in the VM image"
say_do "look for arping, as root so that /usr/sbin is searched"
if vms/h1.sh ssh 'sudo bash -c "command -v arping"' > /dev/null; then arping=present; else arping=absent; fi
say_got "arping is $arping"
say_do "look up a host name from inside the VM"
if vms/h1.sh ssh 'getent hosts deb.debian.org' > /dev/null; then dns=works; else dns=fails; fi
say_got "the name lookup $dns"
if (( fail )); then say_result "FAIL" "a ping lost packets"; exit 1; fi
say_result "PASS" \
    "link:    all three VMs have an address on the link, and h1 reaches h4 and h5 with no packet loss" \
    "arping:  $arping in the image" \
    "lookup:  the name lookup $dns, so the image could probably install arping; the experiments do not need it"
