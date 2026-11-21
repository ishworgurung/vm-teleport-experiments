#!/usr/bin/env bash
# Compare what this run printed after each "RESULT" line with the transcript
# recorded in git (HEAD). Timings and hashes sit above that line, so what is
# left is the outcome: PASS, FAIL or the finding, and one line for each fact.
# Prints a Markdown table; exits 1 if any outcome differs. Run after the
# experiments, in the repository root.
#
#   scripts/compare-results.sh results/demo-step.txt results/criu/*.txt ...
set -euo pipefail
cd "$(dirname "$0")/.."
outcome() { awk '/^RESULT/ { on = 1 } on' ; }
differ=0
echo '| transcript | outcome vs recorded |'
echo '| --- | --- |'
for f in "$@"; do
    if ! git cat-file -e "HEAD:$f" 2> /dev/null; then echo "| $f | no recorded transcript |"; continue; fi
    if [[ ! -f $f ]]; then echo "| $f | **missing: the experiment did not write it** |"; differ=1; continue; fi
    if diff -u <(git show "HEAD:$f" | outcome) <(outcome < "$f") > /tmp/outcome.diff; then
        echo "| $f | same |"
    else
        echo "| $f | **DIFFERENT** |"; differ=1
        { echo; echo '```diff'; cat /tmp/outcome.diff; echo '```'; echo; } >&2
    fi
done
exit "$differ"
