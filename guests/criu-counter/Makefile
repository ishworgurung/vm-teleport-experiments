# Built here, run in the x86-64 VMs: zig links against glibc 2.41 (Debian 13)
# dynamically, so the VM's own libc.so.6 is what the process maps.
all: ../../build/criu-counter ../../build/isa-probe

../../build/criu-counter: counter.c
	mkdir -p ../../build
	zig cc -target x86_64-linux-gnu.2.41 -O2 -Wall -o $@ $<

../../build/isa-probe: isa-probe.c
	zig cc -target x86_64-linux-gnu.2.41 -O1 -Wall -o $@ $<

clean:
	rm -f ../../build/criu-counter ../../build/isa-probe
.PHONY: clean
