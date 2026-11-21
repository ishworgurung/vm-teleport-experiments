# vm-teleport-experiments
#
# Pause a running program on one CPU and resume it on another. Run `make help`
# to list every target. The README gives the order to run them in.

SHELL := /bin/bash
# pipefail: in `script | tee`, a failing script must fail make.
.SHELLFLAGS := -o pipefail -ec
.DEFAULT_GOAL := help

PYTHON ?= python3
# ruff and pyright come from uv (`uvx`) unless they are installed.
RUFF ?= $(if $(shell command -v ruff),ruff,uvx ruff)
PYRIGHT ?= $(if $(shell command -v pyright),pyright,uvx pyright)

# The four hosts of the main demos: Intel x86-64, Arm, RISC-V, AMD x86-64.
HOSTS := h1 h2 h3 h4
TC := target/release/tc
# The cross C compiler for the two emulated hosts: zig, through the wrappers in tools/.
CROSS_ENV := CC_aarch64_unknown_linux_musl=$(CURDIR)/tools/zcc-aarch64 \
             CC_riscv64gc_unknown_linux_gnu=$(CURDIR)/tools/zcc-riscv64-gnu

# Every guest crate. They build for wasm32-wasip1 and each has its own lock file.
GUESTS := step-counter async-counter net-counter wasmer-spike

.PHONY: help doctor tools images host-native host guests python up up-h4 up-vip hosts down run \
        demo-step demo-async demo-py criu demo-net criu-net criu-net-probe vip-check criu-vip \
        crosscheck test mutate lint lint-rust lint-py lint-sh lint-md fmt clean

##@ Help
help: ## List the targets
	@awk 'BEGIN { FS = ":.*## " } \
	      /^##@/ { printf "\n%s\n", substr($$0, 5) } \
	      /^[a-zA-Z_-]+:.*## / { printf "  %-16s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

##@ Setup (once)
doctor: ## Check that this machine has everything the experiments need
	scripts/doctor.sh

tools: ## Download the pinned build tools into tools/ (wasmtime, binaryen, wasi-sdk, wasmer)
	tools/fetch-tools.sh

images: vms/images/.verified ## Download the three Debian VM images and check their checksums

# A stamp, so that the 1.5 GB of checksums are not redone by every experiment.
# `rm vms/images/.verified` checks them again.
vms/images/.verified: vms/fetch-images.sh
	vms/fetch-images.sh
	touch $@

##@ Build
host-native: ## Build the host runtime `tc` for this machine
	cargo build --release -q -p tc

# tc for every host architecture: static musl for aarch64, glibc for riscv64
# (.cargo/config.toml says why).
host: host-native ## Build `tc` for x86-64, aarch64 and riscv64
	$(CROSS_ENV) cargo build --release -q -p tc --target aarch64-unknown-linux-musl
	$(CROSS_ENV) cargo build --release -q -p tc --target riscv64gc-unknown-linux-gnu

guests: tools ## Build the Wasm guests and the native CRIU guest into build/
	$(MAKE) -s -C guests
	$(MAKE) -s -C guests/criu-counter

python: build/python.stamp ## Build CPython for WASI with a checkpoint module, and precompile it

# A stamp: the CPython build takes minutes, so it runs once, not for every experiment.
# Cargo.lock is a prerequisite because a .cwasm only loads into the wasmtime that made it.
build/python.stamp: guests/py-counter/build.sh guests/py-counter/_ckptmodule.c Cargo.lock | tools host-native
	guests/py-counter/build.sh
	for t in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu riscv64gc-unknown-linux-gnu; do \
		$(TC) precompile --module build/python.wasm --target $$t; done
	touch $@

##@ Virtual machines
up: images ## Boot h1 to h4 (several minutes: h2 and h3 are emulated)
	for h in $(HOSTS); do vms/$$h.sh up; done
	for h in $(HOSTS); do vms/$$h.sh wait; done

up-h4: images ## Boot only h4 (the CRIU experiment reboots it with other CPU models)
	vms/h4.sh up && vms/h4.sh wait

# h1, h4 and h5 get a second network card on a private link (L2=1, see
# vms/common.sh). h5 runs the test server.
up-vip: images ## Reboot h1 and h4 with a private link, and boot h5 (for the floating-IP run)
	for h in h1 h4 h5; do vms/$$h.sh down; done
	for h in h1 h4 h5; do L2=1 vms/$$h.sh up; done
	for h in h1 h4 h5; do vms/$$h.sh wait; done

hosts: up ## Show each VM's architecture, CPU model and kernel
	scripts/hosts.sh | tee results/hosts.txt.part
	mv results/hosts.txt.part results/hosts.txt

down: ## Power the VMs off
	for h in h1 h2 h3 h4 h5; do vms/$$h.sh down; done

##@ Experiments that need no VM
run: host-native guests ## Pause and resume both Wasm guests on this machine
	@echo "== step mode, on this machine:"
	rm -rf build/local
	$(TC) start --module build/step-counter.wasm --mode step --steps 1000 --out build/local/s0
	$(TC) resume --module build/step-counter.wasm --capsule build/local/s0 --steps 1000
	@echo "== async mode (Asyncify), on this machine:"
	$(TC) start --module build/async-counter.wasm --mode async --out build/local/a0
	$(TC) resume --module build/async-counter.wasm --capsule build/local/a0 --out build/local/a1
	$(TC) resume --module build/async-counter.wasm --capsule build/local/a1

##@ Experiments that need the VMs (each builds and boots what it needs first)
demo-step: host guests up ## 1. Move a counter paused between calls: h1 -> h2 -> h3 -> h4
	scripts/teleport.sh wasm-step $(HOSTS) | tee results/demo-step.txt.part
	$(PYTHON) -I scripts/check/checkdemo.py step results/demo-step.txt.part | tee -a results/demo-step.txt.part
	mv results/demo-step.txt.part results/demo-step.txt

demo-async: host guests up ## 2. Move a loop paused in the middle of its run
	scripts/teleport.sh wasm-async $(HOSTS) | tee results/demo-async.txt.part
	$(PYTHON) -I scripts/check/checkdemo.py async results/demo-async.txt.part | tee -a results/demo-async.txt.part
	mv results/demo-async.txt.part results/demo-async.txt

demo-py: host python up ## 3. Move a Python script paused in the middle of its run
	scripts/teleport.sh wasm-py $(HOSTS) | tee results/demo-py.txt.part
	$(PYTHON) -I scripts/check/checkdemo.py py results/demo-py.txt.part | tee -a results/demo-py.txt.part
	mv results/demo-py.txt.part results/demo-py.txt

criu: host-native guests up ## 4. Move a native process with CRIU (reboots h4 through three CPU models)
	scripts/criu/all.sh

demo-net: host guests up ## 5a. Move a Wasm program that has an open network connection
	scripts/net/net-demo.sh | tee results/demo-net.txt.part
	mv results/demo-net.txt.part results/demo-net.txt

criu-net: up ## 5b. Move a native client with an open HTTPS connection, with CRIU
	scripts/net/criu-all.sh | tee results/criu-net.txt.part
	mv results/criu-net.txt.part results/criu-net.txt

criu-net-probe: up ## 5c. Look inside the restored TCP socket of the case that fails
	scripts/net/criu-probe.sh | tee results/criu-net-probe.txt.part
	mv results/criu-net-probe.txt.part results/criu-net-probe.txt

vip-check: up-vip ## 6a. Check the private link of the floating-IP run
	scripts/net/vip-check.sh | tee results/vip-check.txt.part
	mv results/vip-check.txt.part results/vip-check.txt

criu-vip: up-vip ## 6b. Keep a connection across hosts with a floating IP
	scripts/net/criu-vip.sh all | tee results/criu-vip.txt.part
	mv results/criu-vip.txt.part results/criu-vip.txt

crosscheck: demo-step demo-async demo-py ## Check the capsules and the output with independent tools
	$(PYTHON) -I scripts/check/crosscheck.py | tee results/crosscheck.txt.part
	mv results/crosscheck.txt.part results/crosscheck.txt

##@ Quality
test: guests ## Run the host's tests, and the checker's self-test
	cargo test --release -q
	$(PYTHON) -I scripts/check/checkdemo.py --self-test

mutate: guests ## Delete each check in the host in turn; a test must fail each time
	$(PYTHON) -I scripts/mutate.py

lint: lint-rust lint-py lint-sh lint-md ## Run every linter

lint-rust: ## rustfmt and clippy, for the host and for every guest
	cargo fmt --all --check
	cargo clippy --workspace --all-targets -- -D warnings
	for g in $(GUESTS); do \
		(cd guests/$$g && cargo fmt --check && cargo clippy --target wasm32-wasip1 -- -D warnings); done

lint-py: ## ruff (lint and format) and pyright
	$(RUFF) check .
	$(RUFF) format --check .
	$(PYRIGHT)

lint-sh: ## shellcheck on every shell script
	shellcheck $$(find scripts vms tools guests -type f \( -name '*.sh' -o -name 'zcc-*' \) \
		-not -path 'tools/wasmtime/*' -not -path 'tools/binaryen/*' -not -path 'tools/wasi-sdk/*' \
		-not -path 'tools/wasmer/*' -not -path 'tools/node_modules/*' -not -path '*/target/*' \
		-not -path 'vms/shared/*' -not -path 'vms/run/*')

lint-md: ## markdownlint, and a parse check of every Mermaid diagram
	npx --yes markdownlint-cli2 README.md "docs/**/*.md" "results/**/*.md"
	npm --prefix tools install --silent
	node tools/check-mermaid.mjs README.md docs/*.md

fmt: ## Format the Rust and Python code
	cargo fmt --all
	for g in $(GUESTS); do (cd guests/$$g && cargo fmt); done
	$(RUFF) format .

##@ Cleanup
# Everything generated: build output, the downloaded tools and VM images, VM
# disks and shares, the test server's state, and tool caches. The VMs are
# powered off first. After this the tree holds only source files, which
# `git status --ignored` shows. The transcripts in results/ are source: they
# are the recorded output that the README quotes.
clean: ## Remove everything generated, VM images included, so only source files remain
	-for h in h1 h2 h3 h4 h5; do vms/$$h.sh down; done
	rm -rf target build guests/step-counter/target guests/async-counter/target
	rm -rf guests/net-counter/target guests/wasmer-spike/target
	rm -rf tools/wasmtime tools/binaryen tools/wasi-sdk tools/wasmer tools/node_modules tools/package-lock.json
	rm -rf vms/images vms/run vms/shared
	rm -f results/*.part results/criu/*.part
	find . -path ./.git -prune -o -type d \( -name __pycache__ -o -name .ruff_cache -o -name .pyright \) -prune -exec rm -rf {} +
