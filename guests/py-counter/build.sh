#!/usr/bin/env bash
# Phase 3: build CPython for wasm32-wasip1 with the _ckpt module, Asyncify it,
# and stage the standard library for the hosts.
#
# Output: build/python.wasm (Asyncify'd) and build/py/lib/python3.15 (stdlib,
# installed with --prefix=/ so the guest finds it under the preopen /lib).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
TAG=v3.15.2
SRC=build/cpython

[[ -d $SRC ]] || git clone -q --depth 1 --branch "$TAG" https://github.com/python/cpython "$SRC"
cp guests/py-counter/_ckptmodule.c "$SRC/Modules/"
# The build runs python.wasm under the wasmtime CLI (sysconfig data, a final
# --version check). That CLI does not provide the ckpt.checkpoint import, so
# let it link a stub that traps if called; nothing in the build calls it.
grep -q unknown-imports-trap "$SRC/Platforms/WASI/wasmtime.toml" ||
    sed -i 's/^\[wasm\]$/[wasm]\nunknown-imports-trap = true/' "$SRC/Platforms/WASI/wasmtime.toml"

export WASI_SDK_PATH=$ROOT/tools/wasi-sdk
export PATH=$ROOT/tools/wasmtime:$PATH       # the build runs python.wasm under wasmtime
cd "$SRC"
# --prefix=/ puts the stdlib at /lib/python3.15 inside the guest.
# --export=__stack_pointer: the host must save and restore it (runtime.rs).
# The flags are for the WASI build only, so run the steps one by one: `build`
# would pass them to the native build Python's configure as well.
W="${PYTHON:-python3} Platforms/WASI"
rm -rf cross-build
$W configure-build-python --quiet
$W make-build-python --quiet
$W configure-host --quiet -- --prefix=/ "LDFLAGS=-Wl,--export=__stack_pointer"
# An out-of-tree build reads Setup.local from its own build directory, not
# the checkout. *static*: WASI has no dlopen.
printf '*static*\n_ckpt _ckptmodule.c\n' > cross-build/wasm32-wasip1/Modules/Setup.local
$W make-host --quiet
CROSS=cross-build/wasm32-wasip1
rm -rf "$ROOT/build/py" && mkdir -p "$ROOT/build/py"
make -C "$CROSS" -s install DESTDIR="$ROOT/build/py/root" >/dev/null 2>&1 || {
    echo "make install failed; rerun without -s for the log" >&2; exit 1; }
mv "$ROOT/build/py/root/lib" "$ROOT/build/py/lib"
rm -rf "$ROOT/build/py/root"
cd "$ROOT"

guests/check-globals.sh "$SRC/$CROSS/python.wasm"
tools/binaryen/bin/wasm-opt "$SRC/$CROSS/python.wasm" -O2 --asyncify \
    --pass-arg=asyncify-imports@ckpt.checkpoint -o build/python.wasm
ls -l "$SRC/$CROSS/python.wasm" build/python.wasm
