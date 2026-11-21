#!/usr/bin/env bash
# Fail the build if a module has a mutable global the host cannot see.
#
# The host saves only *exported* mutable globals (wasmtime cannot read the
# others), so a hidden one would silently restart at its initial value on the
# target. Run on the module *before* Asyncify: the two globals Asyncify adds
# (its state and data pointer) are rebuilt by asyncify_start_rewind.
set -euo pipefail
wasm_dis=${WASM_DIS:-$(dirname "$0")/../tools/binaryen/bin/wasm-dis}
dis=$("$wasm_dis" "$1")
mutable=$(grep -oP '^\s*\(global \$\K[^ ]+(?= \(mut )' <<<"$dis" || true)
exported=$(grep -oP '^\s*\(export "[^"]+" \(global \$\K[^)]+' <<<"$dis" || true)
bad=0
for g in $mutable; do
    if ! grep -qxF "$g" <<<"$exported"; then
        echo "$1: mutable global \$$g is not exported, the host could not save it" >&2
        bad=1
    fi
done
[[ $bad == 0 ]] && echo "$1: all mutable globals exported: ${mutable//$'\n'/ }"
exit "$bad"
