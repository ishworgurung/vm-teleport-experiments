# The Wasm guests, built once to wasm32-wasip1 and run unchanged on every host.
WASM_OPT ?= ../tools/binaryen/bin/wasm-opt
OUT := ../build
WT := target/wasm32-wasip1/release
# wasm-ld hides __stack_pointer by default. The host must save and restore it
# (see crates/tc/src/runtime.rs), so export it.
EXPORT_SP := -C link-arg=--export=__stack_pointer

all: $(OUT)/step-counter.wasm $(OUT)/async-counter.wasm $(OUT)/net-counter.wasm

$(OUT)/step-counter.wasm: step-counter/src/lib.rs step-counter/Cargo.toml
	cd step-counter && RUSTFLAGS="$(EXPORT_SP)" cargo build --release --target wasm32-wasip1 -q
	./check-globals.sh step-counter/$(WT)/step_counter.wasm
	mkdir -p $(OUT) && cp step-counter/$(WT)/step_counter.wasm $@

# Asyncify only what can reach ckpt.checkpoint; every other import (the WASI
# calls) is declared not to unwind, which keeps the code-size cost down.
$(OUT)/async-counter.wasm: async-counter/src/main.rs async-counter/Cargo.toml
	cd async-counter && RUSTFLAGS="$(EXPORT_SP)" cargo build --release --target wasm32-wasip1 -q
	./check-globals.sh async-counter/$(WT)/async-counter.wasm
	mkdir -p $(OUT)
	$(WASM_OPT) async-counter/$(WT)/async-counter.wasm -O1 --asyncify \
		--pass-arg=asyncify-imports@ckpt.checkpoint -o $@

# Phase 6: the same Asyncify recipe. Its net.* imports are not asyncify-imports,
# so they are declared not to unwind, as the WASI calls are.
$(OUT)/net-counter.wasm: net-counter/src/main.rs net-counter/Cargo.toml
	cd net-counter && RUSTFLAGS="$(EXPORT_SP)" cargo build --release --target wasm32-wasip1 -q
	./check-globals.sh net-counter/$(WT)/net-counter.wasm
	mkdir -p $(OUT)
	$(WASM_OPT) net-counter/$(WT)/net-counter.wasm -O1 --asyncify \
		--pass-arg=asyncify-imports@ckpt.checkpoint -o $@

clean:
	rm -rf step-counter/target async-counter/target net-counter/target $(OUT)/step-counter.wasm $(OUT)/async-counter.wasm $(OUT)/net-counter.wasm

.PHONY: all clean
