# shellcheck shell=bash
# The console format of every experiment in this repository. Source this file.
#
# An experiment prints, in this order:
#
#   EXPERIMENT  what is being done, in one line
#   QUESTION    what the run answers, as a question
#   HOW         (optional) how the run works, in one or two lines
#
#   [1/4] <place>: <what this step is>
#     do    what the step does, in plain words
#     got   what came out of it, in plain words
#     next  what happens after it
#     prog  one line printed by the program under test
#     raw   one line of the tool's own output, unchanged, as evidence
#
#   RESULT  PASS, FAIL or the finding, then one line for each fact behind it
#
# A "do" line says what is about to happen, a "got" line says what happened,
# and a "raw" or "prog" line is the evidence for it. Nothing else is printed,
# so a reader can follow the "do" and "got" lines alone and skip the rest.

# say_line LABEL TEXT...: one indented line with a label of at most 5 letters.
say_line() { local label=$1; shift; printf '  %-5s %s\n' "$label" "$*"; }

say_head() { # TITLE QUESTION [HOW]
    printf 'EXPERIMENT  %s\nQUESTION    %s\n' "$1" "$2"
    [[ -z ${3-} ]] || printf 'HOW         %s\n' "$3"
}
say_step() { printf '\n[%s/%s] %s\n' "$1" "$2" "$3"; } # N TOTAL TITLE
say_do() { say_line 'do' "$*"; }
say_got() { say_line got "$*"; }
say_next() { say_line next "$*"; }

# say_quote LABEL: print each line read from stdin with the same label.
say_quote() {
    local label=$1 line
    while IFS= read -r line; do say_line "$label" "$line"; done
}

# say_result VERDICT [LINE...]: the last block of an experiment.
say_result() {
    local verdict=$1; shift
    printf '\nRESULT  %s\n' "$verdict"
    local l; for l in "$@"; do printf '        %s\n' "$l"; done
}

# say_section TITLE: a heading for a block that is not a numbered step.
say_section() { printf '\n%s\n' "$1"; }

# vm_desc HOST: "h2: aarch64, CPU model neoverse-n1, emulated in software (QEMU TCG)".
# It reads the CPU model and the accelerator from QEMU's own command line, so it
# describes what is running now. Call it from the repository root.
vm_desc() {
    local arch args model accel how
    arch=$("vms/$1.sh" ssh uname -m)
    args=$(tr '\0' '\n' < "/proc/$(cat "vms/run/$1.pid")/cmdline")
    model=$(grep -A1 -x -- -cpu <<< "$args" | tail -1)
    accel=$(grep -A1 -x -- -accel <<< "$args" | tail -1)
    if [[ $accel == kvm ]]; then how="runs on the real CPU (KVM)"; else how="emulated in software (QEMU TCG)"; fi
    echo "$1: $arch, CPU model $model, $how"
}
