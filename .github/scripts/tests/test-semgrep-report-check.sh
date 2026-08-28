#!/usr/bin/env bash
# Exercises assert_semgrep_report_complete()
# (.github/scripts/lib/semgrep-report-check.sh), the function
# code-scanning.yml sources to fail a scan whose report covers less than the
# tree it was given. Run via run-tests.sh.
#
# No `set -e`: assert_fail/assert_pass capture the function's exit code
# themselves, and a failing assertion must be counted, not abort the run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"
# shellcheck source=../lib/semgrep-report-check.sh
source "${SCRIPT_DIR}/../lib/semgrep-report-check.sh"

work_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "${work_dir}"' EXIT

assert_pass() {
    local description="$1"
    local fixture="$2"
    local output rc

    output="$(assert_semgrep_report_complete "${fixture}" 2>&1)"
    rc=$?

    if [ "${rc}" -ne 0 ]; then
        echo "FAIL: ${description}: expected success, got exit ${rc}: ${output}"
        failures=$((failures + 1))
        return
    fi

    echo "PASS: ${description}"
}

# Asserts the function fails, that the failure is exactly one workflow
# annotation on a single physical line - a raw newline in the message would
# end the annotation early and leave the rest unattributed, which is exactly
# what the sanitiser in the library is there to prevent - AND that the
# message actually names the reason this fixture was built for. The shape
# checks alone (exit code, line count, `::error::` prefix) are identical
# across every failure branch, so without this substring check a mutation
# that fed the wrong branch's text, or dropped the sanitiser entirely,
# would leave every case here green: mutation-tested by collapsing every
# `echo "::error::..."` in the library down to one literal string, which
# made this exact suite pass before this substring check was added.
assert_fail() {
    local description="$1"
    local fixture="$2"
    local expected_substring="$3"
    local output rc

    output="$(assert_semgrep_report_complete "${fixture}" 2>&1)"
    rc=$?

    if [ "${rc}" -eq 0 ]; then
        echo "FAIL: ${description}: expected failure, got success: ${output}"
        failures=$((failures + 1))
        return
    fi

    local line_count
    line_count="$(printf '%s\n' "${output}" | wc -l)"
    if [ "${line_count}" -ne 1 ]; then
        echo "FAIL: ${description}: expected exactly 1 output line, got ${line_count}: ${output}"
        failures=$((failures + 1))
        return
    fi

    local annotation_count
    annotation_count="$(printf '%s\n' "${output}" | grep -c '^::error::')"
    if [ "${annotation_count}" -ne 1 ]; then
        echo "FAIL: ${description}: expected exactly one ::error:: annotation, got ${annotation_count}: ${output}"
        failures=$((failures + 1))
        return
    fi

    case "${output}" in
        *"${expected_substring}"*) ;;
        *)
            echo "FAIL: ${description}: expected output to contain '${expected_substring}', got: ${output}"
            failures=$((failures + 1))
            return
            ;;
    esac

    echo "PASS: ${description}"
}

tolerated_skip="${work_dir}/tolerated-skip.json"
jq -n '{paths: {scanned: ["a.php"], skipped: [{path: "b.min.js", reason: "minified"}]}}' > "${tolerated_skip}"
assert_pass "tolerated skip reason passes" "${tolerated_skip}"

disallowed_skip="${work_dir}/disallowed-skip.json"
jq -n '{paths: {scanned: ["a.php"], skipped: [{path: "c.php", reason: "some_new_reason"}]}}' > "${disallowed_skip}"
assert_fail "disallowed skip reason fails" "${disallowed_skip}" "c.php: some_new_reason"

no_inventory="${work_dir}/no-inventory.json"
jq -n '{paths: {scanned: ["a.php"]}}' > "${no_inventory}"
assert_fail "absent skip inventory fails" "${no_inventory}" "no-skipped-inventory"

zero_scanned="${work_dir}/zero-scanned.json"
jq -n '{paths: {scanned: [], skipped: []}}' > "${zero_scanned}"
assert_fail "zero-file scan fails" "${zero_scanned}" "scanned no files at all"

non_array_scanned="${work_dir}/non-array-scanned.json"
jq -n '{paths: {scanned: "abc", skipped: []}}' > "${non_array_scanned}"
assert_fail "non-array scanned inventory fails rather than counting characters" "${non_array_scanned}" "does not have a scanned-files list"

unreadable="${work_dir}/unreadable.json"
printf 'not json' > "${unreadable}"
assert_fail "unreadable report fails" "${unreadable}" "could not be read"

# A path holding a literal percent sign and a control character must still
# collapse into exactly one annotation, sanitised rather than passed through
# raw. The control character is injected via jq --arg (an ANSI-C \x01
# literal) rather than typed into the JSON text directly, since raw control
# bytes are not valid inside a JSON string. The substring check confirms the
# sanitised text itself, not just the annotation's shape - a gsub() dropped
# from the library still produces one line and one ::error::, so only the
# content check catches it.
weird_path="${work_dir}/weird-path.json"
weird_value=$'weird%path\x01name'
jq -n --arg p "${weird_value}" '{paths: {scanned: ["a.php"], skipped: [{path: $p, reason: "some_bad_reason"}]}}' > "${weird_path}"
assert_fail "path with percent sign and control character stays one annotation" "${weird_path}" "weird%25path?name: some_bad_reason"

# The library's own docstring names a raw newline as the specific character
# that would end a workflow annotation early and leave the rest as an
# unattributed log line - so it gets its own fixture rather than relying on
# the \x01 case above to stand in for it.
newline_path="${work_dir}/newline-path.json"
newline_value=$'line1\nline2'
jq -n --arg p "${newline_value}" '{paths: {scanned: ["a.php"], skipped: [{path: $p, reason: "some_bad_reason"}]}}' > "${newline_path}"
assert_fail "path with a raw newline stays one annotation" "${newline_path}" "line1?line2: some_bad_reason"

report_and_exit "report-check tests"
