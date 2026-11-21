#!/usr/bin/env python3
"""Check the capsules and demo output with tools other than `tc`.

1. Every capsule's hashes, recomputed with Python's hashlib: memory.bin,
   globals.json and wasi.json against the manifest, and module_sha256 against
   the .wasm files in build/.
2. The step counter read straight out of memory.bin: the address comes from
   the module's own code (the i64.load in `step`, via binaryen's wasm-dis),
   and the value must equal the manifest's counter_hint. The Wasm spec fixes
   linear memory as little-endian, so the same bytes mean the same number on
   x86_64, aarch64 and riscv64.
3. The teleported output against one uninterrupted run under the official
   wasmtime CLI, with ckpt.checkpoint stubbed out
   (-W unknown-imports-default=y makes it a no-op).

Run after `make demo-step demo-async demo-py`.
"""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import subprocess
import sys
from typing import NamedTuple

ROOT = pathlib.Path(__file__).resolve().parents[2]
WASM_DIS = ROOT / "tools/binaryen/bin/wasm-dis"
WASMTIME = ROOT / "tools/wasmtime/wasmtime"
# A u64 counter, as the step guest keeps it in linear memory.
COUNTER_BYTES = 8
# The three data files of a capsule, and the manifest field that holds each one's hash.
CAPSULE_FILES = [
    ("memory.bin", "memory_sha256"),
    ("globals.json", "globals_sha256"),
    ("wasi.json", "wasi_sha256"),
]

failures: list[str] = []


class Manifest(NamedTuple):
    """The fields of a capsule's manifest.json that this script reads."""

    source_host: str
    source_arch: str
    module_sha256: str
    counter_hint: int | None  # null when the guest reports no counter (the Python script)
    hashes: dict[str, str]


def line(label: str, text: str) -> None:
    """Print one labelled line, in the console format of scripts/lib/say.sh."""
    print(f"  {label:<5} {text}")


def step(n: int, total: int, title: str) -> None:
    """Print the heading of step `n` of `total`."""
    print(f"\n[{n}/{total}] {title}")


def check(ok: object, what: str) -> None:
    """Print `what` as ok or FAIL, and remember a failure for the result."""
    line("ok" if ok else "FAIL", what)
    if not ok:
        failures.append(what)


def sha(path: pathlib.Path) -> str:
    """Return the sha256 of a file, as hex."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_manifest(path: pathlib.Path) -> Manifest:
    """Read the manifest at `path`."""
    raw: dict[str, object] = json.loads(path.read_text())
    hint = raw["counter_hint"]
    return Manifest(
        source_host=str(raw["source_host"]),
        source_arch=str(raw["source_arch"]),
        module_sha256=str(raw["module_sha256"]),
        counter_hint=None if hint is None else int(str(hint)),
        hashes={key: str(raw[key]) for _, key in CAPSULE_FILES},
    )


def counter_address() -> int:
    """Find where the step guest keeps its counter, from the module's own code."""
    disassembly = subprocess.run(
        [WASM_DIS, ROOT / "build/step-counter.wasm"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    body = disassembly[disassembly.index("(func $step") :]
    load = re.search(r"i64\.load offset=(\d+)", body)
    if load is None:
        # No i64.load in `step` means the module is not the step counter we expect.
        msg = "no i64.load in the step function of step-counter.wasm"
        raise SystemExit(msg)
    return int(load.group(1))


def capsules() -> list[pathlib.Path]:
    """List each distinct capsule once: the same capsule is copied to the next host."""
    seen: dict[str, pathlib.Path] = {}
    for manifest in sorted(ROOT.glob("vms/shared/h*/capsules/*/cap-*/manifest.json")):
        seen.setdefault(sha(manifest), manifest.parent)
    return list(seen.values())


def capsule_problems(
    cap: pathlib.Path, manifest: Manifest, module: str, address: int
) -> tuple[list[str], str]:
    """Return what is wrong with one capsule, and a note about its counter."""
    problems = [
        f"{name} sha256 differs from the manifest"
        for name, key in CAPSULE_FILES
        if sha(cap / name) != manifest.hashes[key]
    ]
    if module == "?":
        problems.append("module_sha256 is not the sha256 of a module in build/")
    note = ""
    if module == "step-counter.wasm":
        memory = (cap / "memory.bin").read_bytes()
        value = int.from_bytes(memory[address : address + COUNTER_BYTES], "little")
        note = f"; the counter read from memory.bin is {value}"
        if value != manifest.counter_hint:
            problems.append(
                f"u64 at {address} in memory.bin = {value}, manifest says {manifest.counter_hint}"
            )
    return problems, note


def check_capsules() -> None:
    """Step 1: recompute every capsule's hashes and read the step counter out of memory."""
    modules = {sha(p): p.name for p in (ROOT / "build").glob("*.wasm")}
    address = counter_address()
    step(1, 2, "every capsule: its hashes, recomputed with Python")
    line(
        "do",
        "for each capsule, recompute the sha256 of its three data files "
        "and compare it with the manifest",
    )
    line(
        "do",
        "for the step counter, read the counter straight out of memory.bin "
        "and compare it with the manifest",
    )
    line(
        "got",
        f"the step counter lives at linear-memory address {address} "
        "(found by disassembling the module with wasm-dis)",
    )
    for cap in capsules():
        manifest = read_manifest(cap / "manifest.json")
        module = modules.get(manifest.module_sha256, "?")
        problems, note = capsule_problems(cap, manifest, module, address)
        origin = f"written on {manifest.source_host} ({manifest.source_arch})"
        where = f"{cap.relative_to(ROOT)}: {origin}, module {module}"
        check(
            not problems,
            f"{where}; all three hashes match{note}"
            if not problems
            else f"{where}: " + "; ".join(problems),
        )


def guest_lines(text: str, pattern: str) -> list[str]:
    """Return the guest's own lines of `text` that match `pattern`.

    A transcript and a plain run differ in the "prog" label, the "[guest]"
    prefix and the elapsed-time field, so those are removed first.
    """
    out: list[str] = []
    for raw in text.splitlines():
        cleaned = re.sub(r"^ *prog +", "", raw)
        cleaned = re.sub(r"^ *(\[guest\] )?", "", cleaned)
        cleaned = re.sub(r" t=\d+ms", "", cleaned).strip()
        if re.search(pattern, cleaned):
            out.append(cleaned)
    return out


def reference(args: list[str]) -> str:
    """Run a program once under the wasmtime CLI, with checkpoint() as a no-op."""
    cmd = [str(WASMTIME), "run", "-W", "unknown-imports-default=y", *args]
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def check_against_wasmtime_cli() -> None:
    """Step 2: compare the teleported output with one uninterrupted run."""
    cases = [
        ("demo-async.txt", r"^(i=|done:)", [str(ROOT / "build/async-counter.wasm")]),
        (
            "demo-py.txt",
            r"^(python |hello world)",
            [
                "--dir",
                f"{ROOT}/build/py/lib::/lib",
                "--dir",
                f"{ROOT}/guests/py-counter/app::/app",
                str(ROOT / "build/python.wasm"),
                "-u",
                "/app/counter.py",
            ],
        ),
    ]
    step(2, 2, "the teleported output against one run without any pausing")
    line(
        "do",
        "run each program once under the official wasmtime command-line tool, "
        "with checkpoint() switched off",
    )
    line(
        "do",
        "compare its lines with the lines the program printed across the four hosts, one by one",
    )
    for transcript, pattern, args in cases:
        path = ROOT / "results" / transcript
        if not path.exists():
            check(ok=False, what=f"{transcript} missing: run the demo first")
            continue
        teleported = guest_lines(path.read_text(), pattern)
        whole = guest_lines(reference(args), pattern)
        line(
            "got",
            f"{transcript}: {len(teleported)} lines across the hosts, "
            f"{len(whole)} lines from the single run",
        )
        check(
            teleported == whole and len(whole) > 0,
            f"{transcript}: the two are identical, line for line",
        )


def main() -> int:
    """Run both steps and print the result."""
    print("EXPERIMENT  Check the capsules and the demo output with tools other than tc")
    print("QUESTION    Do independent tools agree with what tc recorded?")
    print(
        "HOW         Python recomputes every capsule's hashes. "
        "The official wasmtime command-line tool runs the same programs once, with no pausing.",
    )
    check_capsules()
    check_against_wasmtime_cli()
    print(f"\nRESULT  {'FAIL' if failures else 'PASS'}")
    if failures:
        for failure in failures:
            print(f"        failed: {failure}")
    else:
        print(
            "        every hash matched, the counter read from memory agreed, "
            "and the teleported output equals the single run",
        )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
