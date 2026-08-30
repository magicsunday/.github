#!/usr/bin/env bash
# Sourced by every test-*.sh in .github/scripts/tests/ for the pieces of
# boilerplate that had drifted into separate copies: the shared `failures`
# counter, the closing pass/fail summary, and a plain expected-vs-actual
# assertion. Not itself exercised by run-tests.sh -- the test files that
# source it, and whose PASS/FAIL and exit-code lines this prints, are the
# behavioural proof it works.

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

# Compares "$2" (expected) against "$3" (actual) as plain strings, printing
# PASS/FAIL under description "$1" and incrementing `failures` on a
# mismatch -- the same expected-vs-actual shape test-retry.sh and
# test-semgrep-report-check.sh each had inline before this was extracted.
assert_eq() {
    local description="$1"
    local expected="$2"
    local actual="$3"

    if [ "${expected}" != "${actual}" ]; then
        echo "FAIL: ${description}: expected '${expected}', got '${actual}'"
        failures=$((failures + 1))
        return
    fi

    echo "PASS: ${description}"
}
