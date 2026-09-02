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

# Prints "FAIL: ${1}: got '${2}'" and increments `failures` - the shared
# failure shape assert_contains() and assert_contains_in_order() below both
# need on their first unmatched needle. Not `return`-ing itself: each
# caller's own `return` right after is what ends ITS loop, not this
# helper's.
_harness_fail() {
    echo "FAIL: ${1}: got '${2}'"
    failures=$((failures + 1))
}

# Fails with "FAIL: ${description}: got '$2'" and increments `failures`
# unless "$2" (a haystack) contains EVERY one of "$3.." as a literal
# substring, IN ANY ORDER -- the single-needle case is the same shape
# assert_fail() below already had inline. Round 10 of issue #49 also used
# this shape at three multi-needle call sites in
# test-semgrep-report-check.sh's assert_absent_from_json_array() assertions,
# but those sites previously used one ORDERED glob per needle set
# (`*"::error::"*"link.js"*"scanned"*`), not independent per-needle checks -
# collapsing them to this order-independent form silently dropped that
# ordering guarantee (code-reviewer and test-quality-reviewer,
# mutation-confirmed, round 11: a message with two interpolated values
# swapped still passed). Use this function only when the needles are
# genuinely independent (no two interpolated values in the message could
# plausibly swap position and still read as a match) -- otherwise use
# assert_contains_in_order() below.
assert_contains() {
    local description="$1"
    local haystack="$2"
    shift 2
    local needle
    for needle in "$@"; do
        case "${haystack}" in
            *"${needle}"*) ;;
            *)
                _harness_fail "${description}" "${haystack}"
                return
                ;;
        esac
    done

    echo "PASS: ${description}"
}

# Like assert_contains() above, but requires "$3.." to appear IN ORDER, each
# strictly after the previous match, not merely all be present somewhere.
# For a message built from several interpolated values whose ARRANGEMENT is
# itself part of the contract (e.g. "...as ${path} ${kind}..." vs
# "...as ${kind} ${path}..." both contain the same substrings if $path and
# $kind get swapped) - mutation-confirmed (round 11 of issue #49) that
# assert_contains() cannot catch such a swap, since presence alone doesn't
# depend on position. Narrows the remaining haystack after each match
# (`${remaining#*"${needle}"}`) rather than building one dynamic glob
# pattern, so every needle stays a literal substring match, same as
# assert_contains() itself - no needle can accidentally act as a glob
# wildcard.
assert_contains_in_order() {
    local description="$1"
    local haystack="$2"
    shift 2
    local remaining="${haystack}"
    local needle
    for needle in "$@"; do
        case "${remaining}" in
            *"${needle}"*)
                remaining="${remaining#*"${needle}"}"
                ;;
            *)
                echo "FAIL: ${description}: got '${haystack}'"
                failures=$((failures + 1))
                return
                ;;
        esac
    done

    echo "PASS: ${description}"
}

# Asserts that "$2" - the CAPTURED OUTPUT of some other assert_*() call -
# itself starts with "FAIL:", i.e. that the inner assertion correctly
# failed. Prints PASS/FAIL under description "$1" and increments
# `failures` on a mismatch, same as every other assert here. For probing
# an assert_*() helper's own failure branch directly (round 12/13/14 of
# issue #49 each needed this shape once, testing assert_contains_in_order()
# and assert_contains() themselves rather than a real caller) - the inner
# call's own `failures` increment happens inside the `$(...)` command
# substitution that captured it, so it is a subshell-local copy that never
# reaches this script's real counter; this function's own increment, on
# the real (non-subshell) counter, is what actually gets counted.
assert_starts_with_fail() {
    local description="$1"
    local output="$2"

    case "${output}" in
        FAIL:*) echo "PASS: ${description}" ;;
        *) _harness_fail "${description}" "${output}" ;;
    esac
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

# Writes an always-failing `jq` shim into already-created directory "$1", so
# a caller can shadow the real jq on PATH to simulate a jq failure -- the
# same fixture test-annotation-sanitize.sh and test-semgrepignore-guard.sh
# each need to exercise sanitize_for_annotation()'s internal fallback
# (issue #83). Does not create or clean up "$1" itself: the two callers
# mktemp it differently (one bare, one nested under a shared work_dir with
# its own trap), so only the shim-writing step -- the part that was
# duplicated verbatim -- is shared here.
write_failing_jq_stub() {
    cat > "$1/jq" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
    chmod +x "$1/jq"
}
