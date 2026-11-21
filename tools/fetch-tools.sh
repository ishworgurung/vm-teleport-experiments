#!/usr/bin/env bash
# Fetch the pinned build tools into tools/ (gitignored): the wasmtime CLI
# (for `wasmtime compile` and the CPython build's host runner), binaryen's
# wasm-opt (the Asyncify pass), wasi-sdk (clang + wasi-libc for CPython) and
# wasmer (the journaling spike). Versions are pinned so results reproduce.
#
#   tools/fetch-tools.sh                   fetch all four
#   tools/fetch-tools.sh binaryen          fetch only the ones named
#
# The downloads are x86-64 Linux builds.
set -euo pipefail
cd "$(dirname "$0")"

WASMTIME=v51.0.0
BINARYEN=version_133
WASI_SDK=33 # the version CPython 3.15's Platforms/WASI/config.toml supports
WASMER=v7.5.0

# get URL DIR: unpack a release tarball (gzip or xz) into DIR, unless it is already there.
get() {
    [[ -d $2 ]] && return 0
    echo "fetching $1"
    local flag=-z
    [[ $1 == *.xz ]] && flag=-J
    rm -rf "$2.part"
    mkdir -p "$2.part"
    curl -fsSL --retry 3 "$1" | tar -x "$flag" -C "$2.part" --strip-components=1
    mv "$2.part" "$2"
}

fetch_wasmtime() {
    get "https://github.com/bytecodealliance/wasmtime/releases/download/$WASMTIME/wasmtime-$WASMTIME-x86_64-linux.tar.xz" wasmtime
    ./wasmtime/wasmtime --version
}
fetch_binaryen() {
    get "https://github.com/WebAssembly/binaryen/releases/download/$BINARYEN/binaryen-$BINARYEN-x86_64-linux.tar.gz" binaryen
    ./binaryen/bin/wasm-opt --version
}
fetch_wasi_sdk() {
    get "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-$WASI_SDK/wasi-sdk-$WASI_SDK.0-x86_64-linux.tar.gz" wasi-sdk
    ./wasi-sdk/bin/clang --version | head -1
}
fetch_wasmer() {
    # This archive has no top-level directory to strip, so it is not fetched with `get`.
    if [[ ! -d wasmer ]]; then
        mkdir -p wasmer.part
        curl -fsSL --retry 3 "https://github.com/wasmerio/wasmer/releases/download/$WASMER/wasmer-linux-amd64.tar.gz" |
            tar -xz -C wasmer.part
        mv wasmer.part wasmer
    fi
    ./wasmer/bin/wasmer --version
}

want=("$@")
((${#want[@]})) || want=(wasmtime binaryen wasi-sdk wasmer)
for tool in "${want[@]}"; do
    case $tool in
    wasmtime) fetch_wasmtime ;;
    binaryen) fetch_binaryen ;;
    wasi-sdk) fetch_wasi_sdk ;;
    wasmer) fetch_wasmer ;;
    *)
        echo "unknown tool '$tool': choose from wasmtime binaryen wasi-sdk wasmer" >&2
        exit 2
        ;;
    esac
done
