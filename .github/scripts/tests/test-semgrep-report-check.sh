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

# Bootstrap self-check for every harness.sh function whose FAIL branch
# touches `failures`, BEFORE any real test below trusts one of them -
# test-quality-reviewer, rounds 15-16: every other assertion in this file
# is built on assert_eq()/_harness_fail(), and this script's own trailing
# report_and_exit() call is what turns a correctly-printed "FAIL: ..."
# line into the nonzero exit code run-tests.sh (and lint.yml's
# shell-tests job) actually gates on. A broken one of these that always
# reports PASS, or a broken report_and_exit() that always exits 0, would
# make EVERY later assertion in this file - even one using assert_eq() to
# test assert_eq() itself, as a first attempt tried - silently vanish
# rather than fail CI (mutation-confirmed live, repeatedly).
#
# _bootstrap_check() itself uses only bare `[ ]` comparisons and a direct
# `exit 1`, never assert_eq/failures/report_and_exit, breaking the
# circularity outright rather than routing through the thing under test -
# and it calls the function under test as a PLAIN statement (`"$@" > file`,
# not `$(...)`), so no subshell is forked and `failures` mutations reach
# this script's real, global counter. Round 15's reverted first attempt
# broke because the SUT call itself was `$(...)`-captured; extracting the
# surrounding boilerplate into a function is a different, safe axis
# (simplicity-reviewer, round 17, verified live both directions: a correct
# SUT is confirmed, and a SUT with only its `failures` increment silently
# dropped - message text left intact - is still caught with a real exit 1).
_bootstrap_check() {
    local out_file="$1" expected_output="$2" expected_failures="$3" fatal_msg="$4"
    shift 4
    "$@" > "${out_file}" 2>&1
    local actual
    actual="$(cat "${out_file}")"
    if [ "${actual}" != "${expected_output}" ] || [ "${failures}" != "${expected_failures}" ]; then
        echo "FATAL: ${fatal_msg}: output='${actual}' failures='${failures}'"
        exit 1
    fi
    failures=0
}

_bootstrap_out="${work_dir}/bootstrap.out"
_bootstrap_check "${_bootstrap_out}" "FAIL: bootstrap probe: expected 'expected-x', got 'actual-y'" 1 \
    "assert_eq()'s own mismatch-detection contract is broken - every later assertion in this file is untrustworthy" \
    assert_eq "bootstrap probe" "expected-x" "actual-y"
_bootstrap_check "${_bootstrap_out}" "PASS: bootstrap probe" 0 \
    "assert_eq()'s own match-detection contract is broken - every later assertion in this file is untrustworthy" \
    assert_eq "bootstrap probe" "same" "same"

# _harness_fail() is the increment path shared by assert_contains()/
# assert_contains_in_order()/assert_starts_with_fail() below.
_bootstrap_check "${_bootstrap_out}" "FAIL: bootstrap probe: got 'haystack'" 1 \
    "_harness_fail()'s own contract is broken - assert_contains()/assert_contains_in_order()/assert_starts_with_fail() all rely on it to actually count a failure" \
    _harness_fail "bootstrap probe" "haystack"

# _harness_fail() being independently verified above only proves CALLING it
# increments `failures` correctly - it says nothing about whether
# assert_contains()/assert_contains_in_order() actually still DELEGATE to
# it on their fail path, rather than reimplementing the print inline
# without the increment (code-reviewer, round 17, reproduced live: exactly
# that mutation left this file's own later, `$(...)`-captured self-tests
# for these two functions reporting PASS with `failures` unchanged - the
# closure claim two commits ago was one layer short).
_bootstrap_check "${_bootstrap_out}" "FAIL: bootstrap probe: got 'haystack'" 1 \
    "assert_contains()'s own fail-path contract is broken - it may no longer be delegating to the verified _harness_fail()" \
    assert_contains "bootstrap probe" "haystack" "missing-needle"
_bootstrap_check "${_bootstrap_out}" "PASS: bootstrap probe" 0 \
    "assert_contains()'s own pass-path contract is broken" \
    assert_contains "bootstrap probe" "haystack" "hay"

_bootstrap_check "${_bootstrap_out}" "FAIL: bootstrap probe: got 'b a'" 1 \
    "assert_contains_in_order()'s own fail-path contract is broken - it may no longer be delegating to the verified _harness_fail()" \
    assert_contains_in_order "bootstrap probe" "b a" "a" "b"
_bootstrap_check "${_bootstrap_out}" "PASS: bootstrap probe" 0 \
    "assert_contains_in_order()'s own pass-path contract is broken" \
    assert_contains_in_order "bootstrap probe" "a b" "a" "b"

_bootstrap_existing_file="${work_dir}/bootstrap-existing-file"
: > "${_bootstrap_existing_file}"
_bootstrap_check "${_bootstrap_out}" "FAIL: expected file not found: ${work_dir}/does-not-exist-fixture" 1 \
    "require_file()'s own missing-file contract is broken" \
    require_file "${work_dir}/does-not-exist-fixture"
_bootstrap_check "${_bootstrap_out}" "" 0 \
    "require_file()'s own existing-file contract is broken" \
    require_file "${_bootstrap_existing_file}"

_bootstrap_check "${_bootstrap_out}" "FAIL: bootstrap probe message" 1 \
    "assert_nonempty()'s own empty-value contract is broken" \
    assert_nonempty "" "bootstrap probe message"
_bootstrap_check "${_bootstrap_out}" "" 0 \
    "assert_nonempty()'s own non-empty-value contract is broken" \
    assert_nonempty "x" "bootstrap probe message"

# assert_starts_with_fail() must be bootstrap-verified here too, BEFORE the
# assert_contains()/assert_contains_in_order() self-tests further down use
# it to check THEIR OWN failure branches - test-quality-reviewer, round 16:
# with assert_starts_with_fail()'s own direct test running only later in
# the file (as an earlier version of this file had it), a simultaneous
# break in both assert_starts_with_fail() and the loop logic it was
# checking would go undetected for the whole window between them.
_bootstrap_check "${_bootstrap_out}" "FAIL: bootstrap probe: got 'PASS: not a failure'" 1 \
    "assert_starts_with_fail()'s own negative-case contract is broken" \
    assert_starts_with_fail "bootstrap probe" "PASS: not a failure"
_bootstrap_check "${_bootstrap_out}" "PASS: bootstrap probe" 0 \
    "assert_starts_with_fail()'s own positive-case contract is broken" \
    assert_starts_with_fail "bootstrap probe" "FAIL: genuinely a failure"

# report_and_exit() calls `exit` itself, so it can only be driven in a real
# CHILD PROCESS - calling it in-process would exit this test script. Here
# the `$(...)` captures a genuinely separate `bash -c` process, not the
# counter under test, so this has no S16 blind spot to begin with.
_bootstrap_check_report_and_exit() {
    local failures_input="$1" expected_rc="$2" expected_output="$3" fatal_msg="$4"
    local out rc
    out="$(SCRIPT_DIR="${SCRIPT_DIR}" BOOTSTRAP_FAILURES="${failures_input}" bash -c '
        source "${SCRIPT_DIR}/lib/harness.sh"
        failures="${BOOTSTRAP_FAILURES}"
        report_and_exit "bootstrap probe"
    ' 2>&1)"
    rc=$?
    if [ "${rc}" != "${expected_rc}" ] || [ "${out}" != "${expected_output}" ]; then
        echo "FATAL: ${fatal_msg}: rc='${rc}' output='${out}'"
        exit 1
    fi
}
_bootstrap_check_report_and_exit 1 1 "1 failure(s)." \
    "report_and_exit()'s own nonzero-failures contract is broken - this file's own trailing report_and_exit call would exit 0 no matter what fails below"
_bootstrap_check_report_and_exit 0 0 "All bootstrap probe passed." \
    "report_and_exit()'s own zero-failures contract is broken"

# assert_contains() has the identical gap round 12 closed for its sibling
# below, just never closed for itself: every genuine call site in this file
# - grep for `assert_contains "`, skip the two lines marked "bootstrap
# probe" and the self-test of assert_contains()'s own ordering further
# down - happens to have every needle genuinely present, so a mutation
# that only
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

# Besides the bootstrap self-check above (re-derive with `grep -c
# '^    assert_contains_in_order "bootstrap probe"'
# test-semgrep-report-check.sh` -> 2, which only verify delegation to
# _harness_fail() on the fail/pass path), assert_contains_in_order() has no
# other call site in this file - the assert_absent_from_json_array()
# fixtures that used to justify these self-tests moved to
# test-semgrep-smoke-helpers.sh (issue #99). Re-derive with
# `grep -c '^[a-z_]*_output="\$(assert_contains_in_order "probe"'
# test-semgrep-report-check.sh` (3, all three below): these three assertions
# are this file's only DEDICATED coverage of the function's order-sensitivity
# (the round-10 bug this function exists to catch, test-quality-reviewer,
# mutation-confirmed, round 12).
in_order_ok_output="$(assert_contains_in_order "probe" "a needle b needle" "a" "b" 2>&1)"
assert_eq "assert_contains_in_order: needles present in order pass" "PASS: probe" "${in_order_ok_output}"

in_order_swapped_output="$(assert_contains_in_order "probe" "b needle a needle" "a" "b" 2>&1)"
assert_starts_with_fail "assert_contains_in_order: needles present but out of order fail" "${in_order_swapped_output}"

in_order_missing_output="$(assert_contains_in_order "probe" "a needle only" "a" "b" 2>&1)"
assert_starts_with_fail "assert_contains_in_order: a missing needle fails" "${in_order_missing_output}"

# assert_starts_with_fail(), require_file(), assert_nonempty() and
# report_and_exit() are now covered by the bootstrap self-checks near the
# top of this file, not here - test-quality-reviewer, round 16: this
# section's own earlier versions captured each call via `$(...)`, which can
# only ever prove the printed-message half of the contract (the `failures`
# increment is subshell-local and silently discarded - the same S16 blind
# spot round 15's report_and_exit fix exists to close, just manifesting in
# these functions instead). The bootstrap versions check both the message
# AND the real `failures` counter, and run before anything below could be
# misled by a broken one. report_and_exit()'s own standalone duplicate of
# this same contract survived that consolidation until now (simplicity-
# reviewer, round 29) - removed, since `_bootstrap_check_report_and_exit()`
# above already exercises it with the same rigor.

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

# Only "binary" above had a positive fixture proving it is actually on the
# allow list - a typo in, or accidental removal of, any of the other seven
# literals would silently narrow the accepted-reasons contract with nothing
# to notice (test-quality-reviewer, mutation-confirmed, round 24). One
# fixture per remaining literal, same shape as the case above.
for reason in "always_skipped" "cli_exclude_flags_match" \
    "cli_include_flags_do_not_match" "excluded_by_config" \
    "irrelevant_rule" "semgrepignore_patterns_match" "wrong_language"; do
    reason_report="${work_dir}/tolerated-skip-${reason}.json"
    jq -n --arg reason "${reason}" \
        '{paths: {scanned: ["a.php"], skipped: [{path: "b.txt", reason: $reason}]}}' \
        > "${reason_report}"
    assert_pass "tolerated skip reason passes: ${reason}" "${reason_report}"
done

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

# The two `// "unknown"` / `// "(no path)"` fallback defaults below them have
# no fixture that ever exercises them - every other skip-reason case above
# supplies both `path` and `reason`, so the fallbacks were reachable but
# untested (test-quality-reviewer, mutation-confirmed, round 23).
skip_no_path="${work_dir}/skip-no-path.json"
jq -n '{paths: {scanned: ["a.php"], skipped: [{reason: "some_new_reason"}]}}' > "${skip_no_path}"
assert_fail "a skipped entry with no path falls back to (no path)" "${skip_no_path}" "(no path): some_new_reason"

skip_no_reason="${work_dir}/skip-no-reason.json"
jq -n '{paths: {scanned: ["a.php"], skipped: [{path: "d.php"}]}}' > "${skip_no_reason}"
assert_fail "a skipped entry with no reason falls back to unknown" "${skip_no_reason}" "d.php: unknown"

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

# `jq_stderr_file`'s own mktemp (unconditional, near the top of the
# function) must fail closed with its OWN message, not crash or silently
# skip the check - the same fail-closed contract already pinned below for
# its sibling `git_ls_files_file` mktemp, just never given the same
# treatment here (test-quality-reviewer, mutation-confirmed: flipping this
# branch's `return 1` to `return 0` left the whole suite green, since
# nothing forced this FIRST mktemp call to fail on its own).
mktemp() {
    return 1
}
assert_fail "jq_stderr_file mktemp failure fails closed with its own message" \
    "${tolerated_skip}" "jq failed while evaluating the skip inventory"
unset -f mktemp

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

# `cat "$jq_stderr_file" || jq_error="(diagnostic unavailable)"` was deferred
# in round 27/28 as needing "fragile instrumentation" to test - that premise
# was wrong (test-quality-reviewer, round 28): a plain `cat` shadow, the same
# technique already used for `mktemp`/`jq` elsewhere in this file, triggers
# it deterministically, no chmod/race needed.
cat() {
    return 1
}
assert_fail "jq_stderr_file cat failure falls back to (diagnostic unavailable)" \
    "${non_string_path}" "(diagnostic unavailable)"
unset -f cat

# The `rm -f "$jq_stderr_file" || true` guard (see the comment above this
# function's own cleanup) is itself untested by every assertion above: none
# of them run under a real `set -e`, and the real production caller
# (code-scanning.yml) invokes this function as a bare statement under
# `set -euo pipefail`, not via `$(...)` capture - command substitution does
# NOT propagate errexit into itself by default, so a capture-based probe
# would give a false negative here (test-quality-reviewer, mutation-
# confirmed, round 28: removing `|| true` and driving the crash branch
# through a real `set -e` caller silently aborts before the ::error:: line
# ever prints - reproduced with `rm` shadowed to fail). Mirrors the
# `bash -c`-under-`set -e` technique already used in
# test-annotation-sanitize.sh for the identical class of gap - except this
# fixture's underlying call is designed to `return 1` (non_string_path
# always crashes), so there is no continuation line to echo and prove: the
# first version of this fixture asserted only the printed message, which
# left it blind to a `return 1` -> `return 0` regression on the same
# fail-closed contract (shell-script-reviewer, mutation-confirmed, round
# 29 - the annotation still printed, but the caller would silently treat
# the crash as success). Asserting the real child process's own exit code
# is what actually pins fail-closed, not just fail-loud.
# Every "rm fails under this function's real production caller shape" probe
# below drives the shared run_under_shadowed_rm() from lib/harness.sh
# (extracted per simplicity-reviewer, round 30, then generalised across
# files per simplicity-reviewer, GH-90, once test-warn-tracked-archives.sh
# needed an identically-shaped copy for a different function in the same
# library). Two of the four call sites below cover a guard that lives
# directly inside assert_semgrep_report_complete() itself (both for
# jq_stderr_file); the other two now live one or two call frames deeper,
# inside the shared _git_ls_files_filtered_deduped() helper (the
# repo_root block's own success-continuation guard, moved here by issue
# #104's extraction) and, further inside that,
# _git_tracked_entries_tempfile() (the git-ls-files-failure branch, moved
# out by an earlier GH-90 extraction) - both reached only indirectly
# through this function's calls into them.
LIB_FILE="${SCRIPT_DIR}/../lib/semgrep-report-check.sh"

rm_guard_output="$(run_under_shadowed_rm "${LIB_FILE}" assert_semgrep_report_complete "${non_string_path}")"
rm_guard_rc=$?
assert_eq "jq_stderr_file rm -f failure still fails closed under a real set -e caller" \
    "1" "${rm_guard_rc}"
assert_contains "jq_stderr_file rm -f failure still prints the annotation under a real set -e caller" \
    "${rm_guard_output}" "jq failed while evaluating the skip inventory"

# `assert_semgrep_report_complete()` itself carries TWO `rm -f ... || true`
# guards (re-derive with `awk '/^assert_semgrep_report_complete\(\)/,/^}/'
# ../lib/semgrep-report-check.sh | grep -c 'rm -f .* || true'` -> 2 - both
# for jq_stderr_file; the repo_root block's own git_ls_files_file guard
# moved entirely into the shared _git_ls_files_filtered_deduped() helper,
# which returns its filtered result as a plain array rather than a second
# tempfile the caller would need its own guard for.
# A file-wide, unscoped count also picks up that helper's own guard and
# _git_tracked_entries_tempfile()'s, so it no longer answers this question
# on its own), not one - the case above only covers jq_stderr_file's crash branch. The
# SUCCESS continuation right after it (`rm -f "$jq_stderr_file"` with no
# crash to report) shares the identical unguarded-`rm`-under-a-real-`set -e`
# caller risk and was left untested (test-quality-reviewer, mutation-
# confirmed, round 29: removing `|| true` here breaks even a genuinely
# PASSING report - the script aborts silently before "Scanned N files..."
# ever prints, turning a real production success into a mysterious no-
# output failure). `tolerated_skip` (defined above) reaches this exact
# continuation without crashing.
rm_guard_pass_output="$(run_under_shadowed_rm "${LIB_FILE}" assert_semgrep_report_complete "${tolerated_skip}")"
rm_guard_pass_rc=$?
assert_eq "jq_stderr_file rm -f failure on the SUCCESS continuation still exits 0 under a real set -e caller" \
    "0" "${rm_guard_pass_rc}"
assert_eq "jq_stderr_file rm -f failure on the SUCCESS continuation still prints the success message" \
    "Scanned 1 files, no undeclared skips." "${rm_guard_pass_output}"

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

# The case above only proves truncation HAPPENED (via the "aaa..." substring),
# not that it happened at the right length - the visible shape is governed by
# the `:0:197` slice constant, not by the `-gt 200` trigger this comment
# names, so a regression that shortens the slice (e.g. `:0:197` -> `:0:150`)
# passed the check above unnoticed (test-quality-reviewer, mutation-
# confirmed, round 31). Pinning the trigger value itself would need an exact
# byte-boundary fixture, reintroducing the jq-format/tmpdir-length fragility
# the fixture above was deliberately built to avoid - round 30's call to
# leave that specific gap alone stands. The slice LENGTH, unlike the trigger,
# is a fixed 200 once truncation fires regardless of the raw diagnostic's
# length, so it is both cheap and portable to pin directly.
long_path_output="$(assert_semgrep_report_complete "${long_path_diagnostic}" 2>&1)"
long_path_rc=$?
assert_eq "a diagnostic past the 200-character budget fails closed" "1" "${long_path_rc}"
truncated_diagnostic="${long_path_output#*complete: }"
assert_eq "a diagnostic past the 200-character budget truncates to exactly 200 characters (197 + '...'), not merely somewhere short of the raw length" \
    "200" "${#truncated_diagnostic}"

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

# assert_no_tmp_leak() (shared by every leak assertion below - two here for
# jq_stderr_file, two more further down for the repo_root block's
# git_ls_files_file, plus test-warn-tracked-archives.sh's own leak
# assertion against the same git_ls_files_file cleanup - shared via
# _git_ls_files_filtered_deduped(), not a private copy of the shape) lives
# in lib/harness.sh.

assert_no_tmp_leak "${tmp_scan_dir}" "jq's stderr temp file does not survive a crash-path call" \
    assert_semgrep_report_complete "${non_string_path}"

# The crash-path assertion above only exercises the `rm -f` inside the
# `|| { ... }` handler - it proves nothing about the OTHER cleanup site,
# which runs on every non-crashing report (the far more common branch, hit
# by every fixture above this one). Deleting that second `rm -f` in a
# scratch copy left this suite green even with it removed, which is exactly
# the coverage gap a fixture naming only one branch cannot catch.
assert_no_tmp_leak "${tmp_scan_dir}" "jq's stderr temp file does not survive a successful call" \
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

# The report fixture several of the cases below share byte-for-byte
# (re-derive with `grep -c '^write_missing_target_report "'
# test-semgrep-report-check.sh`, anchored so it doesn't also match this
# comment's own quoted example): "target.php scanned, nothing skipped" - a
# decoy the repo_root comparison already accounts for, present only so
# `.paths.scanned` isn't empty (which is its OWN, differently-tested failure
# mode). Extracted per simplicity-reviewer, round 20: unlike each case's own
# symlink/gitlink name or content (which IS the thing under test and stays
# inline per-case), this JSON carries no per-case information at all.
write_missing_target_report() {
    jq -n '{paths: {scanned: ["target.php"], skipped: []}}' > "$1"
}

git_case_baseline="$(git_case_dir baseline)"
new_git_case baseline
printf 'x' > a.php
finish_git_case "${original_dir}"
report_baseline="${work_dir}/report-baseline.json"
jq -n '{paths: {scanned: ["a.php"], skipped: []}}' > "${report_baseline}"
assert_pass "repo_root: every tracked file accounted for in scanned" "${report_baseline}" "${git_case_baseline}"

# assert_pass() (below in this file) only ever checks the function's exit
# code on the success path, never its stdout - so the success message
# itself (unlike every failure annotation above) has never been pinned by
# any fixture (test-quality-reviewer, mutation-confirmed, round 28:
# rewriting the message text entirely still leaves the whole suite green).
baseline_output="$(assert_semgrep_report_complete "${report_baseline}" "${git_case_baseline}" 2>&1)"
assert_eq "repo_root baseline: success message names the scanned count" \
    "Scanned 1 files, no undeclared skips." "${baseline_output}"

# The confirmed gap this channel exists for: a git-tracked symlink is
# neither scanned nor skipped by the pinned engine (reproduced against it
# directly, 2026-09-02 - see the library's own docstring for the command).
git_case_symlink="$(git_case_dir symlink)"
new_git_case symlink
printf 'x' > target.php
ln -s target.php link.php
finish_git_case "${original_dir}"
report_symlink="${work_dir}/report-symlink.json"
write_missing_target_report "${report_symlink}"
assert_fail "repo_root: a git-tracked path absent from both inventories fails, naming it" \
    "${report_symlink}" "link.php" "${git_case_symlink}"

# `git_ls_files_file`'s `rm -f ... || true` guard on the SUCCESS
# continuation lives inside `_git_ls_files_filtered_deduped()` now (issue
# #104), one call frame deeper than `assert_semgrep_report_complete()`
# itself (see the file-wide count note further below) - reached the same
# way regardless, since this fixture still calls
# assert_semgrep_report_complete() with a real repo_root, which still
# reaches the helper's guard. Shares the same untested-under-a-real-`set -e`
# caller risk as the other guards in this file: without `|| true`, an
# `rm` failure here aborts the script silently before the missing-path
# annotation ever prints. Asserts rc too, not just the message -
# mutation-confirmed that the message-only form misses an independent
# regression: this branch's own `return 1` flipped to `return 0` still
# prints the identical annotation, so only the real child process's own
# exit code catches a caller silently treating a missing tracked symlink
# as success.
git_ls_success_guard_output="$(run_under_shadowed_rm "${LIB_FILE}" assert_semgrep_report_complete "${report_symlink}" "${git_case_symlink}")"
git_ls_success_guard_rc=$?
assert_eq "git_ls_files_file rm -f failure on the missing-symlink success continuation still fails closed under a real set -e caller" \
    "1" "${git_ls_success_guard_rc}"
assert_contains "git_ls_files_file rm -f failure on the missing-symlink success continuation still prints the annotation under a real set -e caller" \
    "${git_ls_success_guard_output}" "link.php"

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
finish_git_case "${original_dir}"
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

# The `rm -f ... || true` guard on the `git ls-files` FAILURE branch - now
# inside the shared `_git_tracked_entries_tempfile()` helper this block
# calls (GH-90 round 4), not inline as `git_ls_files_file`'s own guard -
# shares the same untested-under-a-real-`set -e`-caller risk as
# jq_stderr_file's guards above (test-quality-reviewer, mutation-confirmed,
# round 29): without `|| true`, an `rm` failure here aborts the
# script silently before the "\`git ls-files\` failed in ..." annotation
# ever prints. Removing just the guard leaves rc at 1 either way (this
# branch's own `return 1` is untouched by that mutation), so the message
# assertion alone was a genuine discriminator for THAT specific mutation -
# but not for the independent, adjacent one (shell-script-reviewer,
# mutation-confirmed, round 30): flipping this branch's own `return 1` to
# `return 0` prints the identical annotation and would pass the message
# check alone, silently turning a real `git ls-files` failure into a
# reported success. The rc assertion below is what actually catches that.
git_ls_guard_output="$(run_under_shadowed_rm "${LIB_FILE}" assert_semgrep_report_complete "${report_not_a_repo}" "${git_case_not_a_repo}")"
git_ls_guard_rc=$?
assert_eq "git_ls_files_file rm -f failure on the git-ls-files-failed branch still fails closed under a real set -e caller" \
    "1" "${git_ls_guard_rc}"
assert_contains "git_ls_files_file rm -f failure on the git-ls-files-failed branch still prints the annotation under a real set -e caller" \
    "${git_ls_guard_output}" "git ls-files"

# A raw newline in repo_root itself must not split the "git ls-files
# failed" annotation into a second, unattributed log line -
# shell-script-reviewer, round 11: this interpolation site was the only
# one in the function that skipped sanitize_for_annotation(). Not reachable
# through the current sole production caller (see semgrep-report-check.sh's
# own re-derive comment for that claim), but this pins the fix as a
# regression-proof of the function's own stated single-annotation
# invariant.
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
finish_git_case "${original_dir}"
report_percent="${work_dir}/report-percent.json"
write_missing_target_report "${report_percent}"
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
finish_git_case "${original_dir}"
report_flag_shaped="${work_dir}/report-flag-shaped.json"
write_missing_target_report "${report_flag_shaped}"
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
finish_git_case "${original_dir}"
report_control_byte="${work_dir}/report-control-byte.json"
write_missing_target_report "${report_control_byte}"
assert_fail "repo_root: a missing path with a control byte is folded, staying one annotation" \
    "${report_control_byte}" "weird byte.php" "${git_case_control_byte}"

# `printf '%s\0' "${missing[@]}"` emits a trailing NUL after the LAST
# element too, so `split("\u0000")` alone would leave a trailing empty
# string in the array - `[0:-1]` drops it. Nothing above pins this: none of
# the fixtures above this point pairs two symlinks missing from the SAME
# report (re-derive by reading each `write_missing_target_report` case
# above for more than one `ln -s`/tracked-and-missing path), so
# `join("%0A")` never has a second element to separate, and assert_fail's
# substring check does not see a trailing artifact either way. Proven with
# two simultaneously
# missing paths, against a scratch copy with `[0:-1]` removed: the
# annotation gained a stray trailing "%0A" and every existing assert_fail
# call above still matched its substring, unaffected.
git_case_multi_missing="$(git_case_dir multi-missing)"
new_git_case multi-missing
printf 'x' > target.php
ln -s target.php link-a.php
ln -s target.php link-b.php
finish_git_case "${original_dir}"
report_multi_missing="${work_dir}/report-multi-missing.json"
write_missing_target_report "${report_multi_missing}"
assert_fail "repo_root: two simultaneously-missing paths are joined by exactly one %0A" \
    "${report_multi_missing}" "link-a.php%0Alink-b.php" "${git_case_multi_missing}"

multi_missing_output="$(assert_semgrep_report_complete "${report_multi_missing}" "${git_case_multi_missing}" 2>&1)"
case "${multi_missing_output}" in
    *%0A) _harness_fail "repo_root: no trailing %0A after the last missing path" "${multi_missing_output}" ;;
    *) echo "PASS: repo_root: no trailing %0A after the last missing path" ;;
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
finish_git_case "${original_dir}"
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
finish_git_case "${original_dir}"
report_space="${work_dir}/report-space.json"
write_missing_target_report "${report_space}"
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
write_missing_target_report "${report_gitlink}"
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
finish_git_case "${original_dir}"
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
finish_git_case "${original_dir}"
report_non_string_covered="${work_dir}/report-non-string-covered.json"
jq -n '{paths: {scanned: ["target.php"], skipped: [{path: 123, reason: "binary"}]}}' > "${report_non_string_covered}"
assert_fail "repo_root: a non-string skipped-path entry does not crash the covered-set filter or mask a genuinely missing symlink" \
    "${report_non_string_covered}" "link.php" "${git_case_non_string_covered}"

# The case above has only ONE `.paths.skipped` entry, so it cannot tell
# "the guard is present and working" apart from "the guard is absent, jq
# crashed, and the truncated stream still correctly reported link.php
# missing anyway" - both give the same PASS/FAIL result for a symlink with
# nothing genuinely covering it. This case puts the non-string entry FIRST
# and a legitimate, genuinely-covering entry for the SAME symlink second -
# correctness (Lane A), round 20, mutation-confirmed: without
# `select(type == "string")`, the jq crash on the non-string entry
# truncates the stream before the covering entry after it is ever read,
# silently dropping link.php from `covered` and false-flagging it as
# missing despite the report genuinely accounting for it.
report_non_string_then_covered="${work_dir}/report-non-string-then-covered.json"
jq -n '{paths: {scanned: ["target.php"], skipped: [{path: 123, reason: "binary"}, {path: "link.php", reason: "binary"}]}}' > "${report_non_string_then_covered}"
assert_pass "repo_root: a non-string skipped-path entry does not mask a genuinely covered symlink listed after it" \
    "${report_non_string_then_covered}" "${git_case_non_string_covered}"

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
finish_git_case "${original_dir}"
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
finish_git_case "${original_dir}"
report_sanitiser_failure="${work_dir}/report-sanitiser-failure.json"
write_missing_target_report "${report_sanitiser_failure}"
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
write_missing_target_report "${report_conflict}"
conflict_output="$(assert_semgrep_report_complete "${report_conflict}" "${git_case_conflict}" 2>&1)"
conflict_occurrences="$(printf '%s' "${conflict_output}" | grep -o 'link.php' | wc -l)"
assert_eq "repo_root: a conflicted-stage path is named exactly once, not once per stage" "1" "${conflict_occurrences}"

# The `repo_root` block's own `git_ls_files_file` (semgrep-report-check.sh)
# has NEITHER cleanup site directly in `assert_semgrep_report_complete()`
# itself - both the `git ls-files`-failure branch and the success
# continuation live entirely inside the shared `_git_ls_files_filtered_deduped()`
# helper this block calls, reached only indirectly through it. Neither of
# the two leak assertions above this point passes `repo_root` at all, so
# neither reaches either cleanup site; without a dedicated assertion here,
# deleting either `rm -f` inside the shared helper would leave this suite
# green (proven: removing either in a scratch copy left "All report-check
# tests passed." unchanged). Both guards are exercised by the next two
# assertions below, which still call assert_semgrep_report_complete() with
# a real repo_root.
assert_no_tmp_leak "${tmp_scan_dir}" "repo_root: git_ls_files_file does not survive a git-ls-files failure" \
    assert_semgrep_report_complete "${report_not_a_repo}" "${git_case_not_a_repo}"

assert_no_tmp_leak "${tmp_scan_dir}" "repo_root: git_ls_files_file does not survive a successful call" \
    assert_semgrep_report_complete "${report_baseline}" "${git_case_baseline}"

# A `mktemp` failure for `git_ls_files_file` itself must fail closed with
# its OWN message, not crash or silently skip the check. A globally broken
# `TMPDIR` does not isolate this: `jq_stderr_file`'s own mktemp (near the
# top of the function, unconditional) trips FIRST under the same broken
# TMPDIR and returns ITS message instead - verified, that is a real, weaker
# but still fail-closed property the leak assertions immediately above
# already exercise via TMPDIR, not this specific branch. To reach `git_ls_files_file`
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

# `_git_ls_files_filtered_deduped()`'s nameref out-parameter resolves the
# caller's array by NAME against the function's own scope - before every
# one of its own locals was underscore-prefixed, a caller naming its array
# `mode` or `path` (both plain, unprefixed names the function used
# internally) would have the write silently land in the function's OWN
# local instead of the caller's array: `rc=0` (false success), caller's
# array stays empty - and the exit code is what a caller actually branches
# on, so nothing here makes the check FAIL. Reproducible by removing the
# underscore prefix from the function's internal locals and calling it
# with a colliding array name; Bash does print SOME diagnostic
# line to stderr once the shadowed scalar is hit (the exact wording
# depends on which `set` options are active at the call site - not worth
# pinning here, since it is not what this fix cares about), but that line
# never affects `$?`, so it is not a signal a caller can branch on the way
# it branches on the exit code - the false success (`rc=0`, empty result)
# is the actual defect this fix closes, independent of whatever stderr
# noise happens to accompany it. Pin the fix
# directly, calling the helper (not either of its two
# callers, whose own array names - `tracked`, `raw_paths` - never collided
# and so could not have caught this) with an array named exactly `mode`,
# one of the collision-prone names.
git_case_filtered_deduped_nameref="$(git_case_dir filtered-deduped-nameref)"
new_git_case filtered-deduped-nameref
printf 'x' > a.php
ln -s a.php link.php
finish_git_case "${original_dir}"
declare -a mode=()
_git_ls_files_filtered_deduped_rc=0
_git_ls_files_filtered_deduped mode "${git_case_filtered_deduped_nameref}" keep \
    || _git_ls_files_filtered_deduped_rc=$?
assert_eq "_git_ls_files_filtered_deduped(): a caller array named like an internal local (mode) still succeeds" \
    "0" "${_git_ls_files_filtered_deduped_rc}"
assert_eq "_git_ls_files_filtered_deduped(): a caller array named like an internal local (mode) is still filled, not silently left empty" \
    "1" "${#mode[@]}"
assert_eq "_git_ls_files_filtered_deduped(): the caller's mode array holds the real result, not the function's own internal value" \
    "link.php" "${mode[0]:-}"

# The header comment's contract ("leaving the array untouched" on either
# failure return; implicitly clearing stale data on a success return) has
# no coverage above - every case there starts from a freshly-declared EMPTY
# array, so nothing proves `_out=()` runs at all. Mutation-confirmed:
# deleting that line leaves every case above green.
declare -a stale_success=(bogus-leftover)
_git_ls_files_filtered_deduped stale_success "${git_case_filtered_deduped_nameref}" keep
assert_eq "_git_ls_files_filtered_deduped(): a stale pre-existing element is cleared on a successful call" \
    "1" "${#stale_success[@]}"
assert_eq "_git_ls_files_filtered_deduped(): the cleared array holds the real result, not the stale element" \
    "link.php" "${stale_success[0]:-}"

git_case_filtered_deduped_not_a_repo="$(git_case_dir filtered-deduped-not-a-repo)"
mkdir -p "${git_case_filtered_deduped_not_a_repo}"
declare -a stale_failure=(bogus-leftover)
_git_ls_files_filtered_deduped_rc=0
_git_ls_files_filtered_deduped stale_failure "${git_case_filtered_deduped_not_a_repo}" keep \
    || _git_ls_files_filtered_deduped_rc=$?
assert_eq "_git_ls_files_filtered_deduped(): a git-ls-files failure returns 2" \
    "2" "${_git_ls_files_filtered_deduped_rc}"
assert_eq "_git_ls_files_filtered_deduped(): a git-ls-files failure leaves a pre-existing array untouched, per its own contract" \
    "bogus-leftover" "${stale_failure[0]:-}"

report_and_exit "report-check tests"
