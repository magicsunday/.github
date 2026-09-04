#!/usr/bin/env bash
# Sourced by lint.yml's semgrep-smoke job and by
# .github/scripts/tests/test-semgrep-smoke-helpers.sh. Split out of
# semgrep-report-check.sh (issue #99): both functions below are consumed only
# by this repository's own smoke test against the pinned engine, never by
# code-scanning.yml's production completeness gate.

# shellcheck source=annotation-sanitize.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/annotation-sanitize.sh"

# Writes a fixture crossing the pinned engine's own minified-file thresholds
# (see the re-derive recipe inside semgrep-report-check.sh's
# assert_semgrep_report_complete() for the exact wording and command) to the
# path given as $1. Shared by that recipe and lint.yml's semgrep-smoke job,
# so the fixture the job actually scans and the recipe a reader re-derives by
# hand cannot drift apart.
build_minified_fixture() {
    printf 'function f(a,b,c){return a+b+c;}%.0s' {1..80} > "$1"
}

# Asserts none of the tracked paths given as $4.. satisfy the jq boolean
# expression $2 (run as `jq -e --arg p <path> "$2"`) against the JSON value
# $3 - e.g. a Semgrep report's `.paths.scanned`/`.paths.skipped` array, as
# lint.yml's semgrep-smoke job uses this for. $1 is a label folded into the
# failure message only (e.g. "scanned"/"skipped"), not evaluated.
#
# Distinguishes jq's three possible outcomes explicitly rather than folding
# them into one boolean `if`: exit 0 means the filter matched (a tracked path
# WAS found - fails, naming it); exit 1 means the filter legitimately
# evaluated to false/null (continues); any OTHER exit code means jq itself
# could not evaluate the filter at all (a compile error, or - as observed
# 2026-09-02 - `.path` indexing a non-object array element, which jq exits 5
# for) and must also fail rather than be silently read as "not found" - the
# same failure class issue #65 already documents for semgrep-report-check.sh's
# other jq calls, reintroduced once in an earlier, inline version of this
# exact helper (round 8 of issue #49) before being extracted here with a test.
#
# The assignment is the `if`'s own condition, not a standalone statement
# before one: under `set -e`, a bare `out="$(cmd)"` line trips errexit
# immediately on a failing `cmd`, before a following `rc=$?` line is ever
# reached - as observed 2026-09-02.
#
# Every value folded into the annotation goes through
# sanitize_for_annotation() first, same as semgrep-report-check.sh's
# assert_semgrep_report_complete() - not because either current caller passes
# untrusted input (the test file's tracked-path/haystack arguments are
# literals; lint.yml's haystack is the pinned engine's own real JSON output,
# but neither is attacker-influenced), but because this is a shared library
# function extracted specifically for reuse, and a raw newline reaching a
# future caller's tracked-path/haystack argument would otherwise split one
# annotation into an unattributed second log line, exactly the forgery class
# semgrep-report-check.sh's own assert_semgrep_report_complete() takes care
# to prevent.
assert_absent_from_json_array() {
    local kind="$1" filter="$2" haystack="$3"
    shift 3
    local tracked_path out rc safe_path safe_value
    for tracked_path in "$@"; do
        if out="$(jq -e --arg p "$tracked_path" "$filter" <<< "$haystack" 2>&1)"; then
            rc=0
        else
            rc=$?
        fi
        if [ "$rc" -ne 1 ]; then
            # rc==0 (found) and rc not in {0,1} (crash) are the only two
            # ways to reach here (a legitimate absence, rc==1, loops on
            # without entering this block at all) - both terminate the same
            # way, so the one thing they share (sanitising tracked_path) is
            # computed once instead of once per branch.
            safe_path="$(sanitize_for_annotation "${tracked_path}")"
            if [ "$rc" -eq 0 ]; then
                safe_value="$(sanitize_for_annotation "${haystack}")"
                echo "::error::The pinned engine reported the git-tracked ${safe_path} as ${kind} - this comparison assumes it never is: ${safe_value}"
            else
                safe_value="$(sanitize_for_annotation "${out}")"
                echo "::error::jq could not evaluate the ${kind} check for ${safe_path} (exit ${rc}), so this check verified nothing: ${safe_value}"
            fi
            return 1
        fi
    done
}
