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

# assert_absent_from_json_array() is lint.yml's semgrep-smoke job's own
# helper (shared the same way build_minified_fixture() is), extracted here
# after shipping inline, unpinned, three times within rounds 8-9 of issue
# #49 - a missing positive control, a jq-crash/not-found conflation whose
# first fix attempt was itself broken by a `set -e` assignment-ordering
# trap, then a filter (`.path // .`) that LOOKED like it guarded a
# non-object array element but didn't: `//` only substitutes on a
# null/false RESULT, not on a raised type error, so `.path` indexing a
# bare string still crashed - the caller's own filter now reads `.path? //
# .` instead. Three branches, matching this function's own docblock: found
# (jq -e exits 0), legitimately absent (jq -e exits 1), and jq itself could
# not evaluate the filter at all (any other exit code - reproduced by
# feeding the "scanned" filter a haystack that is valid JSON but not an
# array, which crashes `index($p)` with exit 5; the "skipped" filter's own
# former crash shape no longer reproduces one, now that its caller's filter
# is guarded).
absent_output="$(assert_absent_from_json_array scanned 'index($p) != null' '["target.js"]' link.js vendored-dir logo.png 2>&1)"
absent_rc=$?
assert_eq "assert_absent_from_json_array: all tracked paths legitimately absent returns 0" "0" "${absent_rc}"
assert_eq "assert_absent_from_json_array: all tracked paths legitimately absent prints nothing" "" "${absent_output}"

# Every fixture above and below this line puts the interesting tracked path
# FIRST in the argument list - link.js, always link.js - so a mutation that
# collapsed the `for tracked_path in "$@"` loop to checking only "$1" would
# still pass all of them (mutation-confirmed, test-quality-reviewer round
# 10). This one deliberately matches on the THIRD (logo.png), not the
# first, so the loop's own iteration is what a regression would need to
# break for this test to still pass.
third_arg_found_output="$(assert_absent_from_json_array scanned 'index($p) != null' '["logo.png"]' link.js vendored-dir logo.png 2>&1)"
third_arg_found_rc=$?
assert_eq "assert_absent_from_json_array: a match on the THIRD tracked path, not just the first, still fails" "1" "${third_arg_found_rc}"
assert_contains_in_order "assert_absent_from_json_array: the third-tracked-path found-message names logo.png before its kind" \
    "${third_arg_found_output}" "::error::" "logo.png" "scanned"

found_output="$(assert_absent_from_json_array scanned 'index($p) != null' '["link.js"]' link.js vendored-dir logo.png 2>&1)"
found_rc=$?
assert_eq "assert_absent_from_json_array: a tracked path the filter matches returns 1" "1" "${found_rc}"
assert_contains_in_order "assert_absent_from_json_array: the found-message names the path before the kind" \
    "${found_output}" "::error::" "link.js" "scanned"

crash_output="$(assert_absent_from_json_array scanned 'index($p) != null' '42' link.js vendored-dir logo.png 2>&1)"
crash_rc=$?
assert_eq "assert_absent_from_json_array: a jq evaluation crash returns 1, not silently treated as absent" "1" "${crash_rc}"
assert_contains "assert_absent_from_json_array: the crash-message names jq's own exit code, not a generic fallback" \
    "${crash_output}" "::error::" "could not evaluate" "exit 5"

# The caller's own guarded filter (`.path? // .`, lint.yml's actual
# "skipped" call) mixes a well-formed object with a bare, non-object string
# in the same array - proving both halves at once: the object entry's
# `.path?` half doesn't crash the non-object entry alongside it (unlike the
# unguarded `.path // .` this replaced), AND the `// .` fallback actually
# still matches a bare string against itself, rather than the `?` silently
# turning every non-object entry into a no-op that never matches.
guarded_found_output="$(assert_absent_from_json_array skipped 'any(.[]?; (.path? // .) == $p)' '[{"path":"unrelated.php","reason":"binary"},"link.js"]' link.js vendored-dir logo.png 2>&1)"
guarded_found_rc=$?
assert_eq "assert_absent_from_json_array: the guarded skipped filter still matches a bare-string entry via its fallback, not just object entries" "1" "${guarded_found_rc}"
assert_contains_in_order "assert_absent_from_json_array: the guarded skipped filter's found-message names the matched bare-string entry before its kind" \
    "${guarded_found_output}" "::error::" "link.js" "skipped"

# A raw newline in the matched tracked path must not split the annotation
# into a second, unattributed log line - security-reviewer, round 10:
# neither interpolated value here went through sanitize_for_annotation()
# before this fix, unlike every other annotation site in this file. Built
# via `jq -n --arg` so the newline is properly JSON-escaped in the fixture
# itself, same as the reason-check's own newline fixture above - a raw,
# un-escaped newline spliced into a JSON string LITERAL is invalid JSON and
# would exercise the crash branch instead of the found branch under test.
newline_tracked_path="$(printf 'evil\nfile')"
newline_haystack="$(jq -nc --arg p "${newline_tracked_path}" '[$p]')"
newline_output="$(assert_absent_from_json_array scanned 'index($p) != null' "${newline_haystack}" "${newline_tracked_path}" 2>&1)"
newline_line_count="$(printf '%s\n' "${newline_output}" | wc -l)"
assert_eq "assert_absent_from_json_array: a raw newline in the tracked path stays one annotation line" "1" "${newline_line_count}"
assert_contains "assert_absent_from_json_array: a raw newline in the tracked path is folded, not dropped" \
    "${newline_output}" "::error::" "evil file"

# assert_contains() has the identical gap round 12 closed for its sibling
# below, just never closed for itself: its three real call sites (two
# above, one further down in the repo_root block) all happen to have every
# needle genuinely present, so a mutation that only
# checked the FIRST needle (`for needle in "$1"` instead of `"$@"`) is
# invisible to the whole suite (test-quality-reviewer, mutation-confirmed,
# round 13). The needle ORDER passed here ("b" then "a") deliberately
# doesn't match the haystack's own word order ("a" ... "b"), so a genuine
# pass here also proves this function's order-independence, not just that
# it can find things.
contains_ok_output="$(assert_contains "probe" "a needle b needle" "b" "a" 2>&1)"
assert_eq "assert_contains: needles present in any order pass" "PASS: probe" "${contains_ok_output}"

contains_missing_output="$(assert_contains "probe" "a needle only" "a" "b" 2>&1)"
assert_starts_with_fail "assert_contains: a missing needle fails" "${contains_missing_output}"

# assert_contains_in_order() itself has no fixture below other than the
# three real assert_absent_from_json_array() call sites above, all of
# which only ever receive correctly-ordered production strings - so a
# regression that silently degraded it back to assert_contains()'s
# order-independent behaviour (exactly the round-10 bug this function
# exists to catch) would leave every call site above green anyway
# (test-quality-reviewer, mutation-confirmed, round 12). These three
# assertions drive the function directly instead.
in_order_ok_output="$(assert_contains_in_order "probe" "a needle b needle" "a" "b" 2>&1)"
assert_eq "assert_contains_in_order: needles present in order pass" "PASS: probe" "${in_order_ok_output}"

in_order_swapped_output="$(assert_contains_in_order "probe" "b needle a needle" "a" "b" 2>&1)"
assert_starts_with_fail "assert_contains_in_order: needles present but out of order fail" "${in_order_swapped_output}"

in_order_missing_output="$(assert_contains_in_order "probe" "a needle only" "a" "b" 2>&1)"
assert_starts_with_fail "assert_contains_in_order: a missing needle fails" "${in_order_missing_output}"

# require_file() and assert_nonempty() have the same gap
# assert_contains()/assert_contains_in_order() had before rounds 12-13: every
# real call site across the whole test suite only ever passes an existing
# file / a genuinely non-empty extraction in a passing run, so neither
# function's own FAIL branch has ever actually executed anywhere - mutation-
# confirmed (test-quality-reviewer, round 14) that disabling either guard
# entirely leaves the WHOLE suite green. Both are silent on success (no
# `echo "PASS: ..."` - see their own definitions), so only the failure
# branch has anything to assert on; captured via `$(...)` so the inner
# `failures` increment stays subshell-local, same as every assert_contains*
# probe above.
require_file_missing_output="$(require_file "${work_dir}/does-not-exist-fixture" 2>&1)"
assert_eq "require_file: a missing file fails, naming its own path" \
    "FAIL: expected file not found: ${work_dir}/does-not-exist-fixture" "${require_file_missing_output}"

require_file_present_output="$(require_file "${fixture_file}" 2>&1)"
assert_eq "require_file: an existing file prints nothing" "" "${require_file_present_output}"

nonempty_empty_output="$(assert_nonempty "" "probe message" 2>&1)"
assert_eq "assert_nonempty: an empty value fails, naming the caller's own message" "FAIL: probe message" "${nonempty_empty_output}"

nonempty_present_output="$(assert_nonempty "x" "probe message" 2>&1)"
assert_eq "assert_nonempty: a non-empty value prints nothing" "" "${nonempty_present_output}"

# report_and_exit() is the one function whose own correctness gates whether
# a real, printed FAIL: line anywhere in this suite actually turns into a
# nonzero exit code for run-tests.sh (and therefore for lint.yml's
# shell-tests job) - mutation-confirmed (test-quality-reviewer, round 14)
# that changing its `exit 1` to `exit 0` leaves a genuinely failing
# assertion's FAIL: line on screen while the whole run still reports
# success and exits 0. It can only be driven in a real CHILD PROCESS, never
# in-process: calling it directly would itself `exit` THIS test script.
# SCRIPT_DIR is passed via the environment rather than string-interpolated
# into the child's single-quoted script text, so the source path can't be
# mangled by quoting.
report_and_exit_failure_output="$(SCRIPT_DIR="${SCRIPT_DIR}" bash -c '
    source "${SCRIPT_DIR}/lib/harness.sh"
    failures=1
    report_and_exit "probe suite"
' 2>&1)"
report_and_exit_failure_rc=$?
assert_eq "report_and_exit: a nonzero failures count exits 1" "1" "${report_and_exit_failure_rc}"
assert_eq "report_and_exit: a nonzero failures count prints the failure count" "1 failure(s)." "${report_and_exit_failure_output}"

report_and_exit_success_output="$(SCRIPT_DIR="${SCRIPT_DIR}" bash -c '
    source "${SCRIPT_DIR}/lib/harness.sh"
    failures=0
    report_and_exit "probe suite"
' 2>&1)"
report_and_exit_success_rc=$?
assert_eq "report_and_exit: a zero failures count exits 0" "0" "${report_and_exit_success_rc}"
assert_eq "report_and_exit: a zero failures count prints the all-passed line" "All probe suite passed." "${report_and_exit_success_output}"

assert_pass() {
    local description="$1"
    local fixture="$2"
    local repo_root="${3:-}"
    local output rc

    output="$(assert_semgrep_report_complete "${fixture}" "${repo_root}" 2>&1)"
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
    local repo_root="${4:-}"
    local output rc

    output="$(assert_semgrep_report_complete "${fixture}" "${repo_root}" 2>&1)"
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

# Runs "$@" with TMPDIR pointed at tmp_scan_dir and asserts no tmp.* file
# survives the call - shared by every leak assertion below (two here for
# jq_stderr_file, two more further down for the repo_root block's
# git_ls_files_file). Extracted per simplicity-reviewer (round 2): the same
# duplication shape round 1 already fixed once, for the git-case setup, via
# new_git_case() a few lines below.
assert_no_tmp_leak() {
    local description="$1"
    shift
    local before after
    before="$(find "${tmp_scan_dir}" -maxdepth 1 -name 'tmp.*' | wc -l)"
    TMPDIR="${tmp_scan_dir}" "$@" > /dev/null 2>&1
    after="$(find "${tmp_scan_dir}" -maxdepth 1 -name 'tmp.*' | wc -l)"
    assert_eq "${description}" "${before}" "${after}"
}

assert_no_tmp_leak "jq's stderr temp file does not survive a crash-path call" \
    assert_semgrep_report_complete "${non_string_path}"

# The crash-path assertion above only exercises the `rm -f` inside the
# `|| { ... }` handler - it proves nothing about the OTHER cleanup site,
# which runs on every non-crashing report (the far more common branch, hit
# by every fixture above this one). Deleting that second `rm -f` in a
# scratch copy left this suite green even with it removed, which is exactly
# the coverage gap a fixture naming only one branch cannot catch.
assert_no_tmp_leak "jq's stderr temp file does not survive a successful call" \
    assert_semgrep_report_complete "${tolerated_skip}"

# `repo_root` cases (issue #49, channel 2): the completeness check is only
# reachable with a REAL git repository behind it, so these build one per
# case rather than the pure-JSON fixtures above - matching the isolation
# test-canonical-file-guard.sh already established (own fresh directory per
# case, never reused, since a leftover tracked file from an earlier case
# could mask a later one). `original_dir` is tracked and restored explicitly
# rather than via a subshell: a subshell's own `failures` increment would
# never reach this script's top-level counter.
original_dir="$(pwd)" || exit 1

# The one place that defines the git-case naming scheme; every
# `git_case_<name>="$(git_case_dir <slug>)"` assignment below and
# new_git_case() itself call through it, per simplicity-reviewer, so a future
# rename of the scheme cannot drift between the two.
git_case_dir() {
    printf '%s' "${work_dir}/git-case-$1"
}

# Shared prefix for every git-case setup below: fresh directory, entered, a
# real repo initialised in it. Extracted per simplicity-reviewer, matching
# the isolation new_case_dirs() established in test-canonical-file-guard.sh
# (own fresh directory per case) - each case still creates its own files and
# calls `git add -Af .` itself, since that content is what varies per case.
new_git_case() {
    local dir
    dir="$(git_case_dir "$1")"
    mkdir -p "${dir}"
    cd "${dir}" || exit 1
    git init -q
}

git_case_baseline="$(git_case_dir baseline)"
new_git_case baseline
printf 'x' > a.php
git add -Af .
cd "${original_dir}" || exit 1
report_baseline="${work_dir}/report-baseline.json"
jq -n '{paths: {scanned: ["a.php"], skipped: []}}' > "${report_baseline}"
assert_pass "repo_root: every tracked file accounted for in scanned" "${report_baseline}" "${git_case_baseline}"

# The confirmed gap this channel exists for: a git-tracked symlink is
# neither scanned nor skipped by the pinned engine (reproduced against it
# directly, 2026-09-02 - see the library's own docstring for the command).
git_case_symlink="$(git_case_dir symlink)"
new_git_case symlink
printf 'x' > target.php
ln -s target.php link.php
git add -Af .
cd "${original_dir}" || exit 1
report_symlink="${work_dir}/report-symlink.json"
jq -n '{paths: {scanned: ["target.php"], skipped: []}}' > "${report_symlink}"
assert_fail "repo_root: a git-tracked path absent from both inventories fails, naming it" \
    "${report_symlink}" "link.php" "${git_case_symlink}"

# A tracked SYMLINK the engine already accounted for via `.paths.skipped`
# (any reason) must not be re-flagged - it is covered, just not via
# `.paths.scanned`. Neither file in an earlier version of this fixture was
# mode 120000/160000, so it never reached the repo_root comparison at all
# and passed for the wrong reason - mutation-confirmed: deleting the
# `.paths.skipped` half of the `covered` jq pipeline, or widening the mode
# filter to match every file, both left that version green. `a.php` (a
# regular file, present as a decoy so the report's `scanned` array is
# non-empty) stays in this fixture; `link.php` is the actual symlink under
# test, and only it exercises the skipped-branch of `covered`.
git_case_skipped_covered="$(git_case_dir skipped-covered)"
new_git_case skipped-covered
printf 'x' > a.php
ln -s a.php link.php
git add -Af .
cd "${original_dir}" || exit 1
report_skipped_covered="${work_dir}/report-skipped-covered.json"
jq -n '{paths: {scanned: ["a.php"], skipped: [{path: "link.php", reason: "binary"}]}}' > "${report_skipped_covered}"
assert_pass "repo_root: a symlink the report accounts for via .paths.skipped is not re-flagged" \
    "${report_skipped_covered}" "${git_case_skipped_covered}"

# `repo_root` pointing at a directory that is not a git repository at all
# fails closed with its own distinct message, rather than silently reading
# as "zero tracked files, nothing missing".
git_case_not_a_repo="$(git_case_dir not-a-repo)"
mkdir -p "${git_case_not_a_repo}"
report_not_a_repo="${work_dir}/report-not-a-repo.json"
jq -n '{paths: {scanned: ["a.php"], skipped: []}}' > "${report_not_a_repo}"
assert_fail "repo_root: a non-git directory fails closed rather than silently passing" \
    "${report_not_a_repo}" "git ls-files" "${git_case_not_a_repo}"

# A raw newline in repo_root itself must not split the "git ls-files
# failed" annotation into a second, unattributed log line -
# shell-script-reviewer, round 11: this interpolation site was the only
# one in the function that skipped sanitize_for_annotation(). Not
# reachable through the sole production caller (a fixed, runner-controlled
# $GITHUB_WORKSPACE), but this pins the fix as a regression-proof of the
# function's own stated single-annotation invariant.
newline_repo_root="${work_dir}/repo-root-$(printf 'evil\nroot')"
mkdir -p "${newline_repo_root}"
newline_root_output="$(assert_semgrep_report_complete "${report_not_a_repo}" "${newline_repo_root}" 2>&1)"
newline_root_line_count="$(printf '%s\n' "${newline_root_output}" | wc -l)"
assert_eq "repo_root: a raw newline in repo_root itself stays one annotation line" "1" "${newline_root_line_count}"
assert_contains "repo_root: a raw newline in repo_root itself is folded, not dropped" \
    "${newline_root_output}" "git ls-files" "evil root"

# Omitting `repo_root` must skip this check entirely, even when run from
# INSIDE a git tree that has the exact gap the check above catches - proving
# the check is strictly opt-in via the parameter, never inferred from the
# caller's own working directory.
cd "${git_case_symlink}" || exit 1
assert_pass "repo_root omitted: the completeness check does not run even from inside a git tree with a real gap" \
    "${report_symlink}"
cd "${original_dir}" || exit 1

# A missing path carrying a literal percent sign is sanitised the same way
# every other path-derived annotation value in this library already is.
git_case_percent="$(git_case_dir percent)"
new_git_case percent
printf 'x' > target.php
ln -s target.php 'weird%name.php'
git add -Af .
cd "${original_dir}" || exit 1
report_percent="${work_dir}/report-percent.json"
jq -n '{paths: {scanned: ["target.php"], skipped: []}}' > "${report_percent}"
assert_fail "repo_root: a missing path with a literal percent sign is sanitised in the annotation" \
    "${report_percent}" "weird%25name.php" "${git_case_percent}"

# A missing path shaped like a jq CLI flag (`--rawfile` takes two
# parameters) must still be sanitised and named, not silently dropped or
# collapsed to "(sanitisation failed)" for the whole batch. An earlier,
# argv-based version of the sanitiser (`jq --args ... "${missing[@]}"`)
# failed exactly this way - fixable with a `--` separator, but the
# NUL-delimited-stdin form the library uses now (see its own comment)
# removes the whole class: a path never reaches jq's own argv/option
# parser at all, so there is nothing shaped like a flag from jq's point of
# view. This fixture pins that regardless of which mechanism is in use.
git_case_flag_shaped="$(git_case_dir flag-shaped)"
new_git_case flag-shaped
printf 'x' > target.php
ln -s target.php -- '--rawfile'
git add -Af .
cd "${original_dir}" || exit 1
report_flag_shaped="${work_dir}/report-flag-shaped.json"
jq -n '{paths: {scanned: ["target.php"], skipped: []}}' > "${report_flag_shaped}"
assert_fail "repo_root: a missing path shaped like a jq flag is still named, not dropped" \
    "${report_flag_shaped}" "--rawfile" "${git_case_flag_shaped}"

# The reason-based check above (see "path with a raw newline stays one
# annotation") has a dedicated fixture proving its sanitiser folds a
# control byte; the repo_root/missing-path sanitiser is a separate jq
# filter (batched via a NUL-delimited pipe, not the shared
# sanitize_for_annotation() helper) and had no equivalent case until
# this one.
git_case_control_byte="$(git_case_dir control-byte)"
new_git_case control-byte
printf 'x' > target.php
control_byte_name="$(printf 'weird\001byte.php')"
ln -s target.php "${control_byte_name}"
git add -Af .
cd "${original_dir}" || exit 1
report_control_byte="${work_dir}/report-control-byte.json"
jq -n '{paths: {scanned: ["target.php"], skipped: []}}' > "${report_control_byte}"
assert_fail "repo_root: a missing path with a control byte is folded, staying one annotation" \
    "${report_control_byte}" "weird byte.php" "${git_case_control_byte}"

# `printf '%s\0' "${missing[@]}"` emits a trailing NUL after the LAST
# element too, so `split("\u0000")` alone would leave a trailing empty
# string in the array - `[0:-1]` drops it. Nothing above pins this: every
# fixture above has exactly one missing path, so `join("%0A")` never has a
# second element to separate, and assert_fail's substring check does not
# see a trailing artifact either way. Proven with two simultaneously
# missing paths, against a scratch copy with `[0:-1]` removed: the
# annotation gained a stray trailing "%0A" and every existing assert_fail
# call above still matched its substring, unaffected.
git_case_multi_missing="$(git_case_dir multi-missing)"
new_git_case multi-missing
printf 'x' > target.php
ln -s target.php link-a.php
ln -s target.php link-b.php
git add -Af .
cd "${original_dir}" || exit 1
report_multi_missing="${work_dir}/report-multi-missing.json"
jq -n '{paths: {scanned: ["target.php"], skipped: []}}' > "${report_multi_missing}"
assert_fail "repo_root: two simultaneously-missing paths are joined by exactly one %0A" \
    "${report_multi_missing}" "link-a.php%0Alink-b.php" "${git_case_multi_missing}"

multi_missing_output="$(assert_semgrep_report_complete "${report_multi_missing}" "${git_case_multi_missing}" 2>&1)"
case "${multi_missing_output}" in
    *%0A)
        echo "FAIL: repo_root: no trailing %0A after the last missing path: ${multi_missing_output}"
        failures=$((failures + 1))
        ;;
    *)
        echo "PASS: repo_root: no trailing %0A after the last missing path"
        ;;
esac

# Regression guard (round 3): an ORDINARY tracked file absent from both
# inventories must NOT be flagged - only a symlink or gitlink (mode
# 120000/160000) is. Semgrep's own binary-content handling can leave a
# tracked binary asset in neither .paths.scanned nor .paths.skipped under
# the real four-pack invocation (see the library's own comment for the
# reproduction); comparing every tracked path against the report, as an
# earlier version of this block did, false-positived on exactly that -
# reddening code-scanning on merge for any consumer carrying a tracked
# image, font, or archive without already declaring it via `excludes`.
git_case_ordinary_missing="$(git_case_dir ordinary-missing)"
new_git_case ordinary-missing
printf 'x' > a.php
printf 'not really a png, just needs to be a plain tracked file' > logo.png
git add -Af .
cd "${original_dir}" || exit 1
report_ordinary_missing="${work_dir}/report-ordinary-missing.json"
jq -n '{paths: {scanned: ["a.php"], skipped: []}}' > "${report_ordinary_missing}"
assert_pass "repo_root: an ordinary tracked file absent from both inventories is not flagged (only symlinks/gitlinks are)" \
    "${report_ordinary_missing}" "${git_case_ordinary_missing}"

# A tracked symlink whose name contains a literal SPACE must survive both
# the mode split (`${_entry%% *}`) and the path split (`${_entry#*$'\t'}`)
# intact - neither is space-based, but nothing above this point proves it:
# every existing missing-path fixture uses a tab, a control byte, or a
# flag-shaped name, never a plain space.
git_case_space="$(git_case_dir space)"
new_git_case space
printf 'x' > target.php
ln -s target.php 'my link.php'
git add -Af .
cd "${original_dir}" || exit 1
report_space="${work_dir}/report-space.json"
jq -n '{paths: {scanned: ["target.php"], skipped: []}}' > "${report_space}"
assert_fail "repo_root: a missing path with a space survives the mode/path split intact" \
    "${report_space}" "my link.php" "${git_case_space}"

# Mode 160000 (gitlink/submodule) is the other half of the
# `case "$_mode" in 120000 | 160000)` filter - mutation-confirmed
# unreachable by any fixture above: dropping `| 160000` from that case arm
# left the whole suite green. No real submodule is needed to stage one;
# `--cacheinfo` with the well-known empty-tree SHA registers a gitlink
# entry directly in the index.
git_case_gitlink="$(git_case_dir gitlink)"
new_git_case gitlink
printf 'x' > target.php
git add -Af .
git update-index --add --cacheinfo 160000,4b825dc642cb6eb9a060e54bf8d69288fbee4904,vendored-dir
cd "${original_dir}" || exit 1
report_gitlink="${work_dir}/report-gitlink.json"
jq -n '{paths: {scanned: ["target.php"], skipped: []}}' > "${report_gitlink}"
assert_fail "repo_root: a missing gitlink (mode 160000) is caught, not just symlinks" \
    "${report_gitlink}" "vendored-dir" "${git_case_gitlink}"

# The POSITIVE half of the `covered[$_p]+x` lookup - a symlink genuinely
# accounted for in the report - has no fixture above either: every
# assert_pass case up to this point passes because its files are mode
# 100644 and never enter `tracked` at all, not because this lookup found a
# match. A regression that compared against the wrong array, or a typo'd
# key, would leave every case above green.
git_case_symlink_covered="$(git_case_dir symlink-covered)"
new_git_case symlink-covered
printf 'x' > target.php
ln -s target.php link.php
git add -Af .
cd "${original_dir}" || exit 1
report_symlink_covered="${work_dir}/report-symlink-covered.json"
jq -n '{paths: {scanned: ["target.php", "link.php"], skipped: []}}' > "${report_symlink_covered}"
assert_pass "repo_root: a symlink the report DOES account for is not flagged" \
    "${report_symlink_covered}" "${git_case_symlink_covered}"

# The `select(type == "string")` guard on the covered-set jq filter has
# nothing to guard against otherwise: a non-string `.path` value alongside
# a genuinely missing symlink must not crash the filter, and must not be
# mistaken for covering that symlink either.
git_case_non_string_covered="$(git_case_dir non-string-covered)"
new_git_case non-string-covered
printf 'x' > target.php
ln -s target.php link.php
git add -Af .
cd "${original_dir}" || exit 1
report_non_string_covered="${work_dir}/report-non-string-covered.json"
jq -n '{paths: {scanned: ["target.php"], skipped: [{path: 123, reason: "binary"}]}}' > "${report_non_string_covered}"
assert_fail "repo_root: a non-string skipped-path entry does not crash the covered-set filter or mask a genuinely missing symlink" \
    "${report_non_string_covered}" "link.php" "${git_case_non_string_covered}"

# A `.paths.skipped` element that is not an OBJECT at all (unlike the
# non-string `.path` FIELD case above, which is a well-formed object) is a
# genuinely different fixture shape no existing case covers - and it looks,
# on paper, like it should crash the covered-set filter this repo_root
# comparison runs (`.path` cannot index a bare string). A fix attempting to
# harden exactly that filter was written, tested here, and then reverted:
# this shape provably never reaches it. The unexpected-reasons check earlier
# in this same function (the one `non_string_path` above exercises) already
# iterates the identical `.paths.skipped` array and accesses `.reason` on
# every element FIRST - a strictly earlier pass over the same input, and
# `.reason`/`.path` fail on exactly the same set of non-object values, so
# whatever would crash the covered-set filter always crashes there first and
# returns before repo_root's own block is ever reached. Kept as a
# regression-proof of that control-flow fact (not the covered-set filter's
# hardening, which doesn't exist), so a future reordering of the two checks
# is caught by this exact case rather than reasoned about from scratch again.
git_case_skipped_not_object="$(git_case_dir skipped-not-object)"
new_git_case skipped-not-object
printf 'x' > target.php
ln -s target.php link.php
git add -Af .
cd "${original_dir}" || exit 1
report_skipped_not_object="${work_dir}/report-skipped-not-object.json"
jq -n '{paths: {scanned: ["target.php"], skipped: ["not-an-object"]}}' > "${report_skipped_not_object}"
assert_fail "repo_root: a non-object skipped-array entry is already caught by the earlier reason check, never reaching the covered-set filter" \
    "${report_skipped_not_object}" "jq failed while evaluating the skip inventory, so the report cannot be shown complete: jq: error (at ${report_skipped_not_object}:" "${git_case_skipped_not_object}"

# The missing-path sanitiser's own `|| missing_lines="(sanitisation
# failed)"` fallback has nothing to trigger it: the jq PROGRAM here is a
# fixed literal, never built from report content, so no fixture can break
# it through input alone. `jq` is shadowed to fail only when called with
# `-Rsr` - as observed 2026-09-02 (re-derive with `grep -n "jq -"
# ../lib/semgrep-report-check.sh`), the flag combination unique to this one
# call among the function's several jq invocations (the readability check
# uses none, the skip-reason check uses `-r`, the covered-set build uses
# `-j`) - so every OTHER jq call in the same run still succeeds normally.
git_case_sanitiser_failure="$(git_case_dir sanitiser-failure)"
new_git_case sanitiser-failure
printf 'x' > target.php
ln -s target.php link.php
git add -Af .
cd "${original_dir}" || exit 1
report_sanitiser_failure="${work_dir}/report-sanitiser-failure.json"
jq -n '{paths: {scanned: ["target.php"], skipped: []}}' > "${report_sanitiser_failure}"
jq() {
    if [ "${1:-}" = "-Rsr" ]; then
        return 1
    fi
    command jq "$@"
}
assert_fail "repo_root: the missing-path sanitiser's own jq failure falls back to a fixed message" \
    "${report_sanitiser_failure}" "(sanitisation failed)" "${git_case_sanitiser_failure}"
unset -f jq

# Adjacent-duplicate dedup: `git ls-files -s` emits one line per
# (mode, object, stage) combination, not one line per path, so an
# unresolved merge conflict on a tracked symlink produces THREE stage
# 1/2/3 lines for the same path, all still mode 120000. Without the
# check against the last-appended element, `tracked` (and then `missing`)
# named the same path three times. `--index-info` stages the conflict
# directly, without a real merge.
git_case_conflict="$(git_case_dir conflict)"
new_git_case conflict
printf 'x' > target.php
git add -Af .
blob1="$(printf 'a' | git hash-object -w --stdin)"
blob2="$(printf 'b' | git hash-object -w --stdin)"
blob3="$(printf 'c' | git hash-object -w --stdin)"
printf '120000 %s 1\tlink.php\n120000 %s 2\tlink.php\n120000 %s 3\tlink.php\n' \
    "${blob1}" "${blob2}" "${blob3}" | git update-index --index-info
cd "${original_dir}" || exit 1
report_conflict="${work_dir}/report-conflict.json"
jq -n '{paths: {scanned: ["target.php"], skipped: []}}' > "${report_conflict}"
conflict_output="$(assert_semgrep_report_complete "${report_conflict}" "${git_case_conflict}" 2>&1)"
conflict_occurrences="$(printf '%s' "${conflict_output}" | grep -o 'link.php' | wc -l)"
assert_eq "repo_root: a conflicted-stage path is named exactly once, not once per stage" "1" "${conflict_occurrences}"

# The new `git_ls_files_file` mktemp (semgrep-report-check.sh, the
# `repo_root` block) is cleaned up on TWO exit paths - the `git ls-files`
# failure branch and the success continuation - mirroring the jq-stderr
# temp file's own two cleanup sites above. Neither of the two leak
# assertions above this point passes `repo_root` at all, so neither reaches
# this mktemp; without a dedicated assertion here, deleting either of its
# `rm -f` calls would leave this suite green (proven: removing the
# success-path `rm -f` in a scratch copy left "All report-check tests
# passed." unchanged).
assert_no_tmp_leak "repo_root: git_ls_files_file does not survive a git-ls-files failure" \
    assert_semgrep_report_complete "${report_not_a_repo}" "${git_case_not_a_repo}"

assert_no_tmp_leak "repo_root: git_ls_files_file does not survive a successful call" \
    assert_semgrep_report_complete "${report_baseline}" "${git_case_baseline}"

# A `mktemp` failure for `git_ls_files_file` itself must fail closed with
# its OWN message, not crash or silently skip the check. A globally broken
# `TMPDIR` does not isolate this: `jq_stderr_file`'s own mktemp (near the
# top of the function, unconditional) trips FIRST under the same broken
# TMPDIR and returns ITS message instead - verified, that is a real, weaker
# but still fail-closed property the two leak assertions above already
# exercise via TMPDIR, not this specific branch. To reach `git_ls_files_file`
# specifically, `mktemp` is shadowed as a function that succeeds on its
# first call (jq_stderr_file) and fails on its second (git_ls_files_file) -
# a plain counter variable does not survive across `$(mktemp)`'s own
# subshell, so the count lives in a file instead (verified: a variable-only
# counter silently reset to 1 on every call).
mktemp_call_count_file="$(mktemp)" || exit 1
echo 0 > "${mktemp_call_count_file}"
mktemp() {
    local n
    n=$(($(cat "${mktemp_call_count_file}") + 1))
    echo "${n}" > "${mktemp_call_count_file}"
    if [ "${n}" -eq 2 ]; then
        return 1
    fi
    command mktemp "$@"
}
assert_fail "repo_root: a git_ls_files_file mktemp failure fails closed with its own message" \
    "${report_baseline}" "Could not create a temp file" "${git_case_baseline}"
unset -f mktemp
rm -f "${mktemp_call_count_file}"

report_and_exit "report-check tests"
