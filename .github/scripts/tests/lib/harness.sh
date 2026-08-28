#!/usr/bin/env bash
# Sourced by every test-*.sh in .github/scripts/tests/ for the two pieces of
# boilerplate that had drifted into four separate copies: the shared
# `failures` counter and the closing pass/fail summary. Not itself exercised
# by run-tests.sh -- the four test files that source it, and whose PASS/FAIL
# and exit-code lines this prints, are the behavioural proof it works.

failures=0

# Prints the standard summary for suite "$1" (used in "All $1 passed.") and
# exits 1 if any assertion in this run failed -- the same shape every
# test-*.sh ended its own run with, before this was extracted.
report_and_exit() {
    if [ "${failures}" -gt 0 ]; then
        echo "${failures} failure(s)."
        exit 1
    fi

    echo "All $1 passed."
}
