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

# Fails with "FAIL: expected file not found: $1" and increments `failures`
# unless "$1" exists -- the same file-existence guard
# test-semgrep-prune-dirs.sh and test-lib-source-cp-drift.sh
# each had inline before this was extracted, both checking their own
# drift-guard inputs exist before comparing them.
require_file() {
    if [ ! -f "$1" ]; then
        echo "FAIL: expected file not found: $1"
        failures=$((failures + 1))
    fi
}

# Fails with "FAIL: $2" and increments `failures` unless "$1" is non-empty --
# the same drift-guard extraction-sanity check
# test-semgrep-prune-dirs.sh and test-lib-source-cp-drift.sh
# each had inline before this was extracted: a blind regex/shape change on
# BOTH sides of a comparison would otherwise leave two empty strings that
# assert_eq sees as equal, certifying a comparison that never ran.
assert_nonempty() {
    if [ -z "$1" ]; then
        echo "FAIL: $2"
        failures=$((failures + 1))
    fi
}

# Prints the lines from the first line matching "$1" through the first
# subsequent line matching "$2" (inclusive) out of file "$3" -- the
# `sed -n '/start/,/end/p'` idiom test-semgrep-prune-dirs.sh and
# test-lib-source-cp-drift.sh each had inline before this was extracted, to
# pull a function's or a workflow step's body out for further grepping.
extract_block() {
    local start="$1"
    local end="$2"
    local file="$3"

    sed -n "/${start}/,/${end}/p" "${file}"
}
