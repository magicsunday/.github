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

# Pins the extracted literal itself, not the engine's minified-file
# thresholds - re-deriving those independently here would be exactly the
# "mirror test that misses the machine" this suite's own convention avoids
# elsewhere. A future edit that silently changes the fixture (a typo in the
# format string, a different repeat count) breaks this fast, hermetic
# assertion before it would only surface via the slower, engine-backed
# semgrep-smoke CI job. Compared as raw bytes via cmp, not through
# "$(cat ...)": command substitution strips every trailing newline on both
# sides, which would mask a trailing-newline-only drift in the fixture -
# a real difference the semgrep-smoke job's own byte-for-byte scan would see.
fixture_file="${work_dir}/fixture.js"
build_minified_fixture "${fixture_file}"
expected_file="${work_dir}/expected.js"
printf 'function f(a,b,c){return a+b+c;}%.0s' {1..80} > "${expected_file}"
cmp -s "${expected_file}" "${fixture_file}" && fixture_cmp_result="match" || fixture_cmp_result="differ"
assert_eq "build_minified_fixture() writes the expected literal fixture" "match" "${fixture_cmp_result}"

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
jq -n '{paths: {scanned: ["a.php"], skipped: [{path: "b.bin", reason: "binary"}]}}' > "${tolerated_skip}"
assert_pass "tolerated skip reason passes" "${tolerated_skip}"

# `minified` is deliberately NOT tolerated (issue #50): the pinned engine
# cannot produce it through this workflow's invocation, so a report that
# carries it anyway means either a future engine change made it reachable
# again or the allow list regressed - both must fail rather than pass
# silently.
minified_skip="${work_dir}/minified-skip.json"
jq -n '{paths: {scanned: ["a.php"], skipped: [{path: "b.min.js", reason: "minified"}]}}' > "${minified_skip}"
assert_fail "minified skip reason fails" "${minified_skip}" "b.min.js: minified"

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

# A non-string `.path` crashes the jq filter that builds the unexpected-
# reasons list, mid-evaluation, after it has already produced no output for
# the genuinely disallowed entry ahead of it. Without an exit-status check on
# that command substitution, the crash's empty stdout reads as "no unexpected
# reasons" and the gate reports success on a report it could not evaluate
# (issue #65). The expected substring pins jq's own diagnostic text, not just
# the generic prefix, so a regression back to discarding it via `2>/dev/null`
# fails this test rather than passing on the shape alone (issue #69).
non_string_path="${work_dir}/non-string-path.json"
jq -n '{paths: {scanned: ["a.php"], skipped: [{path: "x.php", reason: "some_bad_reason"}, {path: 123, reason: "some_reason"}]}}' > "${non_string_path}"
assert_fail "non-string skipped-path entry fails closed rather than masking a crash" "${non_string_path}" "jq failed while evaluating the skip inventory, so the report cannot be shown complete: jq: error (at ${non_string_path}:"
assert_fail "non-string skipped-path entry: annotation carries jq's actual diagnostic body, not a hardcoded stand-in" "${non_string_path}" "number (123) cannot be matched, as it is not a string"

# jq's own crash diagnostic previews the offending value verbatim (truncated,
# but not sanitised by jq itself), so a `%` inside it reaches the annotation
# unless this library's own sanitiser - applied to jq's stderr text, not just
# to a report `.path` value - actually runs. A non-string array whose first
# element contains a literal `%` reproduces this deterministically: jq's own
# "array ([...) cannot be matched" preview echoes that element back
# (verified: `jq -r '.path | gsub("%"; "%25")'` on `{"path":
# ["weird%valuex","b"]}` crashes with `array (["weird%val...) cannot be
# matched, as it is not a string` - the plain `jq -r '.path'` does not crash,
# since a non-string result prints fine; the crash needs the same `gsub`
# this library's real filter applies), so an unsanitised excerpt would leave
# a raw `%` in the annotation (issue #69).
percent_in_jq_diagnostic="${work_dir}/percent-in-jq-diagnostic.json"
jq -n '{paths: {scanned: ["a.php"], skipped: [{path: ["weird%valuex", "b"], reason: "x"}]}}' > "${percent_in_jq_diagnostic}"
assert_fail "a percent sign inside jq's own crash diagnostic is sanitised" "${percent_in_jq_diagnostic}" "weird%25val"

# jq only bounds the previewed VALUE in its own diagnostic, never the
# "(at <file>:<line>)" portion - a report living at a long enough path
# produces a raw diagnostic past this library's own 200-character budget.
# Padding the fixture's own path (rather than the JSON content) reproduces
# this without depending on jq's value-preview truncation point. A fixture
# that never exceeds the budget cannot tell a truncating implementation from
# one that forgot to truncate at all.
long_path_dir="${work_dir}/$(printf 'a%.0s' $(seq 1 200))"
mkdir -p "${long_path_dir}"
long_path_diagnostic="${long_path_dir}/non-string-path.json"
jq -n '{paths: {scanned: ["a.php"], skipped: [{path: 123, reason: "some_reason"}]}}' > "${long_path_diagnostic}"
assert_fail "a diagnostic past the 200-character budget is truncated, still one annotation" "${long_path_diagnostic}" "aaa..."

# A path holding a literal percent sign and a control character must still
# collapse into exactly one annotation, sanitised rather than passed through
# raw. The control character is injected via jq --arg (an ANSI-C \x01
# literal) rather than typed into the JSON text directly, since raw control
# bytes are not valid inside a JSON string. The substring check confirms the
# sanitised text itself, not just the annotation's shape - a gsub() dropped
# from the library still produces one line and one ::error::, so only the
# content check catches it. The control byte folds to a space, not `?`
# (issue #78) - `?` collides with a literal `?` a path may legally contain,
# which is what the case below this one pins.
weird_path="${work_dir}/weird-path.json"
weird_value=$'weird%path\x01name'
jq -n --arg p "${weird_value}" '{paths: {scanned: ["a.php"], skipped: [{path: $p, reason: "some_bad_reason"}]}}' > "${weird_path}"
assert_fail "path with percent sign and control character stays one annotation" "${weird_path}" "weird%25path name: some_bad_reason"

# The library's own docstring names a raw newline as the specific character
# that would end a workflow annotation early and leave the rest as an
# unattributed log line - so it gets its own fixture rather than relying on
# the \x01 case above to stand in for it.
newline_path="${work_dir}/newline-path.json"
newline_value=$'line1\nline2'
jq -n --arg p "${newline_value}" '{paths: {scanned: ["a.php"], skipped: [{path: $p, reason: "some_bad_reason"}]}}' > "${newline_path}"
assert_fail "path with a raw newline stays one annotation" "${newline_path}" "line1 line2: some_bad_reason"

# A literal `?` in a path must survive intact rather than collide with a
# control byte folded to the same placeholder character - the exact
# collision the old `gsub("[[:cntrl:]]"; "?")` shape produced here before
# issue #78 fixed it, mirroring the case test-annotation-sanitize.sh pins for
# the bash-side sanitizer this jq-level gsub deliberately matches.
literal_question_mark_path="${work_dir}/literal-question-mark-path.json"
literal_question_mark_value=$'sub?\x01dir'
jq -n --arg p "${literal_question_mark_value}" '{paths: {scanned: ["a.php"], skipped: [{path: $p, reason: "some_bad_reason"}]}}' > "${literal_question_mark_path}"
assert_fail "a literal question mark next to a folded control byte stays distinguishable" "${literal_question_mark_path}" "sub? dir: some_bad_reason"

# The temp file mktemp creates for jq's stderr is only useful for the
# duration of one crash-path evaluation - assert it does not survive past
# the call, rather than trusting the two `rm -f` call sites to be exhaustive
# by inspection alone. This class of gap is exactly what an earlier
# `trap ... RETURN` attempt at this cleanup got wrong in a way inspection
# alone did not catch (issue #69): the trap looked scoped to the function on
# a read but was not, so this assertion outlives the specific mechanism used
# to satisfy it.
#
# Scanning the shared /tmp for this would flake under a busy host: another
# process creating or removing an unrelated `tmp.*` file between the two
# counts changes the count for a reason unrelated to this library. Pointing
# `TMPDIR` at a private directory under `work_dir` for the duration of the
# call (mktemp honours `TMPDIR`) makes the count deterministic instead.
tmp_scan_dir="${work_dir}/tmp-scan"
mkdir -p "${tmp_scan_dir}"

before_tmp_count="$(find "${tmp_scan_dir}" -maxdepth 1 -name 'tmp.*' | wc -l)"
TMPDIR="${tmp_scan_dir}" assert_semgrep_report_complete "${non_string_path}" > /dev/null 2>&1
after_tmp_count="$(find "${tmp_scan_dir}" -maxdepth 1 -name 'tmp.*' | wc -l)"
assert_eq "jq's stderr temp file does not survive a crash-path call" "${before_tmp_count}" "${after_tmp_count}"

# The crash-path assertion above only exercises the `rm -f` inside the
# `|| { ... }` handler - it proves nothing about the OTHER cleanup site,
# which runs on every non-crashing report (the far more common branch, hit
# by every fixture above this one). Deleting that second `rm -f` in a
# scratch copy left this suite green even with it removed, which is exactly
# the coverage gap a fixture naming only one branch cannot catch.
before_tmp_count="$(find "${tmp_scan_dir}" -maxdepth 1 -name 'tmp.*' | wc -l)"
TMPDIR="${tmp_scan_dir}" assert_semgrep_report_complete "${tolerated_skip}" > /dev/null 2>&1
after_tmp_count="$(find "${tmp_scan_dir}" -maxdepth 1 -name 'tmp.*' | wc -l)"
assert_eq "jq's stderr temp file does not survive a successful call" "${before_tmp_count}" "${after_tmp_count}"

report_and_exit "report-check tests"
