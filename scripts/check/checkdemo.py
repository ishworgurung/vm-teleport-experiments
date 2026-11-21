#!/usr/bin/env python3
"""Assert that a teleport demo did what the README says, host by host.

    checkdemo.py step|async|py TRANSCRIPT     check one transcript
    checkdemo.py --self-test                  break the real transcripts on
                                              purpose; every break must fail

The transcript is teleport.sh's output for h1 -> h2 -> h3 -> h4. It is split into
one section per host (each starts with `[N/4] hN: ARCH, ...`). The checks read two
kinds of line inside a section: `raw` lines (the tool's own output, unchanged) and
`prog` lines (what the program under test printed). The `do`, `got` and `next`
lines are for the reader and are not checked. Then, for every payload:

- the hosts are h1, h2, h3, h4, in that order, on x86_64 (Intel model), aarch64,
  riscv64 and x86_64 (AMD model), and each `tc` line names the host and
  architecture of its own section;
- every host but the last writes a capsule, and the next host restores exactly that
  capsule (same sha256 prefix) with the same module hash;
- each host prints exactly its own share of the work, and the values carry on from
  the previous host (nothing restarts, nothing is lost or repeated).
"""

from __future__ import annotations

import pathlib
import re
import sys
from typing import TYPE_CHECKING, NamedTuple

if TYPE_CHECKING:
    from collections.abc import Callable

ROOT = pathlib.Path(__file__).resolve().parents[2]
HOSTS = [("h1", "x86_64"), ("h2", "aarch64"), ("h3", "riscv64"), ("h4", "x86_64")]

# The work each payload gives one host, as the guests are written.
ITERATIONS_PER_HOST = 1000  # the step counter and the async loop
PRINT_EVERY = 250  # the async loop prints every 250 iterations
PY_LINES_PER_HOST = 10  # the Python script pauses after every 10 lines
FINAL_COUNTER = 4000


class CheckError(Exception):
    """A claim about the transcript did not hold."""


class Step(NamedTuple):
    """One host's part of the transcript."""

    host: str
    arch: str
    body: str


class Report:
    """What a passing check proved, in plain words, in the order it was proved."""

    def __init__(self) -> None:
        """Start with nothing proved."""
        self.passed: list[str] = []

    def add(self, claim: str) -> None:
        """Record one claim that held."""
        self.passed.append(claim)


def need(ok: object, why: str) -> None:
    """Fail with `why` unless `ok` is truthy."""
    if not ok:
        raise CheckError(why)


# A transcript line of the given kind: "  raw   ..." or "  prog  ...".
RAW = r"^ +raw +"
PROG = r"^ +prog +"


def steps(text: str) -> list[Step]:
    """Split a transcript into one `Step` per host."""
    parts = re.split(r"^\[\d+/\d+\] ", text, flags=re.MULTILINE)[1:]
    out: list[Step] = []
    for part in parts:
        match = re.match(r"(h\d): (\S+), ", part)
        if match is None:
            bad_header = part.splitlines()[0]
            msg = f"bad step header: {bad_header!r}"
            raise CheckError(msg)
        out.append(Step(match.group(1), match.group(2), part))
    return out


def check_common(sections: list[Step], report: Report) -> None:
    """Check host order, architectures, the capsule chain and the module hash."""
    seen = [(s.host, s.arch) for s in sections]
    need(seen == HOSTS, f"hosts {seen}, want {HOSTS}")
    modules: set[str] = set()
    prev_capsule: str | None = None
    for i, step in enumerate(sections):
        for m in re.finditer(
            RAW
            + r"tc: checkpoint host=(\S+) arch=(\S+) .*capsule=sha256:(\w+) module=sha256:(\w+)",
            step.body,
            re.MULTILINE,
        ):
            need(
                m.group(1, 2) == (step.host, step.arch),
                f"{step.host}: checkpoint line says {m.group(1, 2)}",
            )
            modules.add(m.group(4))
        restored = re.findall(
            RAW
            + r"tc: restored on (\S+) \((\S+), .*capsule=sha256:(\w+) written on (\S+) "
            + r".*module=sha256:(\w+) verified",
            step.body,
            re.MULTILINE,
        )
        checkpoints = re.findall(
            RAW + r"tc: checkpoint .*capsule=sha256:(\w+)", step.body, re.MULTILINE
        )
        if i == 0:
            need(not restored, "h1 must start fresh, not restore")
        else:
            previous = sections[i - 1].host
            need(len(restored) == 1, f"{step.host}: {len(restored)} restore lines, want 1")
            r_host, r_arch, capsule, source, module = restored[0]
            need(
                (r_host, r_arch) == (step.host, step.arch),
                f"{step.host}: restore line says {r_host} ({r_arch})",
            )
            need(
                capsule == prev_capsule,
                f"{step.host} restored capsule {capsule}, but {previous} wrote {prev_capsule}",
            )
            need(source == previous, f"{step.host}: capsule written on {source}, want {previous}")
            modules.add(module)
        if i < len(sections) - 1:
            need(len(checkpoints) == 1, f"{step.host}: {len(checkpoints)} checkpoints, want 1")
            prev_capsule = checkpoints[0]
        else:
            need(not checkpoints, f"{step.host}: the last host must not checkpoint")
    need(len(modules) == 1, f"module hashes differ across hosts: {modules}")
    report.add(
        "the hosts ran in this order: " + ", ".join(f"{s.host} ({s.arch})" for s in sections)
    )
    report.add("each host loaded exactly the capsule that the previous host saved")
    report.add(f"every host ran the same program (module {next(iter(modules))[:8]})")


def check_step(sections: list[Step], report: Report) -> None:
    """Check the step counter: 1000, 2000, 3000, 4000, each host from where the last stopped."""
    want = [(None, 1000), (1000, 2000), (2000, 3000), (3000, 4000)]
    for step, (start, end) in zip(sections, want, strict=True):
        if start is not None:
            need(
                re.search(RAW + rf"tc: restored .* counter={start} ", step.body, re.MULTILINE),
                f"{step.host}: not restored at counter={start}",
            )
        reached = re.search(
            RAW + rf"tc: (checkpoint .*counter={end} |ran to counter={end}, done)",
            step.body,
            re.MULTILINE,
        )
        need(reached, f"{step.host}: did not reach counter={end}")
    report.add(
        "the counter went 1000, 2000, 3000, 4000: each host started where the previous one stopped"
    )


def check_async(sections: list[Step], report: Report) -> None:
    """Check the async loop: no iteration lost or repeated, the sum and the history carried over."""
    total = 0
    sum_sq = 0
    history: list[int] = []
    for k, step in enumerate(sections):
        lines = re.findall(r"i=(\d+) sum_sq=(\d+) history=\[([\d, ]*)\]", step.body)
        first = ITERATIONS_PER_HOST * k + PRINT_EVERY
        want_i = list(range(first, ITERATIONS_PER_HOST * k + ITERATIONS_PER_HOST + 1, PRINT_EVERY))
        printed = [int(i) for i, _, _ in lines]
        need(printed == want_i, f"{step.host}: printed i={printed}, want {want_i}")
        for i_text, sum_text, history_text in lines:
            i = int(i_text)
            while total < i:
                total += 1
                sum_sq += total * total
            need(int(sum_text) == sum_sq, f"{step.host}: i={i} sum_sq={sum_text}, want {sum_sq}")
            need(
                history_text == ", ".join(map(str, history)),
                f"{step.host}: i={i} history=[{history_text}], want {history}",
            )
        if k < len(sections) - 1:
            history.append(ITERATIONS_PER_HOST * (k + 1))
    report.add(
        "the loop printed i = 250, 500, ... 4000 in order, 1000 iterations on each host, "
        "and the running sum and the history were correct each time",
    )
    last = sections[-1]
    done = re.findall(rf"done: i={FINAL_COUNTER} sum_sq=(\d+) \(expected (\d+)\)", last.body)
    need(
        done and done[0][0] == done[0][1] == str(sum_sq),
        f"{last.host}: done line {done}, want sum_sq={sum_sq}",
    )
    need(
        re.search(RAW + r"tc: guest finished \(exit 0\)", last.body, re.MULTILINE),
        f"{last.host}: guest did not finish with exit 0",
    )
    report.add(f"the program finished by itself on {last.host} (exit 0), with sum_sq {sum_sq}")


def check_py(sections: list[Step], report: Report) -> None:
    """Check the Python script: one interpreter start-up, ten lines per host, the right totals."""
    banners = [
        s.host
        for s in sections
        if re.search(PROG + r"python 3\.\d+\.\d+ on wasi/wasm32$", s.body, re.MULTILINE)
    ]
    need(
        banners == ["h1"],
        f"interpreter start-up line printed on {banners}, want only h1 "
        "(a restart would print it again)",
    )
    for k, step in enumerate(sections):
        lines = [
            (int(i), int(t))
            for i, t in re.findall(
                PROG + r"hello world (\d+) total=(\d+)$", step.body, re.MULTILINE
            )
        ]
        want = list(range(PY_LINES_PER_HOST * k, PY_LINES_PER_HOST * (k + 1)))
        printed = [i for i, _ in lines]
        need(printed == want, f"{step.host}: printed i={printed}, want {want}")
        for i, total in lines:
            expected = i * (i + 1) // 2
            need(total == expected, f"{step.host}: i={i} total={total}, want {expected}")
    last = sections[-1]
    need(
        re.search(RAW + r"tc: guest finished \(exit 0\)", last.body, re.MULTILINE),
        f"{last.host}: guest did not finish with exit 0",
    )
    report.add(
        "the interpreter started once, on h1, and the script printed 'hello world' 0 to 39 "
        "in order, ten on each host, with the right total",
    )


CHECKS: dict[str, Callable[[list[Step], Report], None]] = {
    "step": check_step,
    "async": check_async,
    "py": check_py,
}


def check(payload: str, text: str, report: Report) -> None:
    """Check `text`, the transcript of `payload`, adding each claim that holds to `report`.

    Raises `CheckError` at the first claim that does not hold.
    """
    sections = steps(text)
    check_common(sections, report)
    CHECKS[payload](sections, report)


def swap(a: str, b: str) -> Callable[[str], str]:
    """Return a mutation that exchanges every `a` with every `b`."""
    return lambda t: t.replace(a, "\0").replace(b, a).replace("\0", b)


def replace(old: str, new: str, count: int = -1) -> Callable[[str], str]:
    """Return a mutation that replaces `old` with `new`."""
    return lambda t: t.replace(old, new, count)


def resub(pattern: str, repl: str) -> Callable[[str], str]:
    """Return a mutation that rewrites the text with a regular expression."""
    return lambda t: re.sub(pattern, repl, t)


def mutations() -> dict[str, list[tuple[str, Callable[[str], str]]]]:
    """Each payload's list of ways to break its transcript, with what each one breaks."""
    hello = "  prog  hello world 15 total=120\n"
    return {
        "py": [
            (
                "lines 9 and 10 swap hosts",
                swap("hello world 9 total=45", "hello world 10 total=55"),
            ),
            ("a line missing", replace(hello, "")),
            ("a line repeated", replace(hello, hello * 2)),
            ("total wrong", replace("total=120", "total=121")),
            (
                "interpreter restarted on h2",
                replace(
                    "  prog  hello world 10 total=55",
                    "  prog  python 3.15.2 on wasi/wasm32\n  prog  hello world 10 total=55",
                ),
            ),
            ("h3 ran on x86_64", replace("h3: riscv64,", "h3: x86_64,")),
            (
                "h3 restored a stale capsule",
                resub(r"(restored on h3 .*capsule=sha256:)\w+", r"\g<1>000000000000"),
            ),
            ("h4 ran on riscv64", replace("h4: x86_64,", "h4: riscv64,")),
            (
                "h4 restored a stale capsule",
                resub(r"(restored on h4 .*capsule=sha256:)\w+", r"\g<1>000000000000"),
            ),
            ("guest did not finish", replace("tc: guest finished (exit 0)", "")),
        ],
        "async": [
            ("loop restarted on h2", replace("i=1250 ", "i=250 ")),
            ("history lost", replace("history=[1000] t=", "history=[] t=", 1)),
            ("sum wrong", replace("sum_sq=2668667000", "sum_sq=2668667001")),
            (
                "history lost on h4",
                replace("history=[1000, 2000, 3000] t=", "history=[1000, 3000] t=", 1),
            ),
        ],
        "step": [
            ("h2 started from zero", resub(r"(restored on h2 .*counter=)1000", r"\g<1>0")),
            ("h4 stopped short", replace("ran to counter=4000", "ran to counter=3999")),
            ("h4 started from zero", resub(r"(restored on h4 .*counter=)3000", r"\g<1>0")),
            (
                "module changed on h3",
                resub(r"(restored on h3 .*module=sha256:)\w+", r"\g<1>ffffffffffff"),
            ),
            (
                "module changed on h4",
                resub(r"(restored on h4 .*module=sha256:)\w+", r"\g<1>ffffffffffff"),
            ),
        ],
    }


def self_test() -> int:
    """Break the recorded transcripts on purpose. Each mutation must be rejected."""
    bad = 0
    for payload, muts in mutations().items():
        text = (ROOT / "results" / f"demo-{payload}.txt").read_text()
        check(payload, text, Report())  # the real transcript must pass first
        print(f"demo-{payload}.txt: passes as recorded")
        for what, mutate in muts:
            broken = mutate(text)
            if broken == text:
                print(f"  NOT APPLIED  {what}")
                bad += 1
                continue
            try:
                check(payload, broken, Report())
            except CheckError as err:
                print(f"  rejected     {what}: {err}")
            else:
                print(f"  ACCEPTED     {what}")
                bad += 1
    print("self-test passed" if not bad else f"self-test FAILED: {bad}")
    return 1 if bad else 0


def main() -> int:
    """Run the self-test, or check one transcript and print what held."""
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    if len(sys.argv) != len(("checkdemo.py", "payload", "transcript")) or sys.argv[1] not in CHECKS:
        print(__doc__)
        return 2
    print("\nCHECK   Does this transcript show what the README says it shows?")
    payload, path = sys.argv[1], pathlib.Path(sys.argv[2])
    report = Report()
    try:
        check(payload, path.read_text(), report)
    except CheckError as err:
        for claim in report.passed:
            print(f"  ok    {claim}")
        print(f"\nRESULT  FAIL\n        {err}")
        return 1
    for claim in report.passed:
        print(f"  ok    {claim}")
    print("\nRESULT  PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
