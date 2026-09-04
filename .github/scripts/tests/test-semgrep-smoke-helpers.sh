#!/usr/bin/env bash
# Exercises build_minified_fixture() and assert_absent_from_json_array()
# (.github/scripts/lib/semgrep-smoke-helpers.sh) - lint.yml's semgrep-smoke
# job's own helpers, sourced only there and here (issue #99). Isolated in its
# own file rather than folded into test-semgrep-report-check.sh: neither
# helper is a dependency of assert_semgrep_report_complete() - the one
# function that test file pins (warn_tracked_archives() has its own
# test-warn-tracked-archives.sh).
#
# No `set -e`: assert_eq/assert_contains capture failures via the shared
# `failures` counter, and a failing assertion must be counted, not abort the
# run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"
# shellcheck source=../lib/semgrep-smoke-helpers.sh
source "${SCRIPT_DIR}/../lib/semgrep-smoke-helpers.sh"

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

# The crash is attributed to the FIRST tracked path (link.js) per this
# function's own `shift 3` argument contract ($1-$3 are kind/filter/
# haystack, "$@" is the tracked-path list starting there) - not to the
# haystack argument itself. A `shift 3` -> `shift 2` regression leaves
# `haystack` ($3) as a bogus extra element ahead of "$@", so the crash
# (and every other outcome) would instead be attributed to it; this
# fixture's haystack ('42') and its first tracked path ('link.js')
# independently crash the same filter, so only naming the actual path
# proves which one was really checked (mutation-confirmed: `shift 2`
# leaves this suite green otherwise - test-quality-reviewer, round 26).
assert_contains "assert_absent_from_json_array: the crash-message names the first tracked path, not the haystack argument itself" \
    "${crash_output}" "link.js"

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
# before this fix, unlike every other annotation site in
# semgrep-report-check.sh at the time. Built via `jq -n --arg` so the
# newline is properly JSON-escaped in the fixture itself, same as the
# reason-check's own newline fixture in test-semgrep-report-check.sh - a
# raw, un-escaped newline spliced into a JSON string LITERAL is invalid JSON
# and would exercise the crash branch instead of the found branch under test.
newline_tracked_path="$(printf 'evil\nfile')"
newline_haystack="$(jq -nc --arg p "${newline_tracked_path}" '[$p]')"
newline_output="$(assert_absent_from_json_array scanned 'index($p) != null' "${newline_haystack}" "${newline_tracked_path}" 2>&1)"
newline_line_count="$(printf '%s\n' "${newline_output}" | wc -l)"
assert_eq "assert_absent_from_json_array: a raw newline in the tracked path stays one annotation line" "1" "${newline_line_count}"
assert_contains "assert_absent_from_json_array: a raw newline in the tracked path is folded, not dropped" \
    "${newline_output}" "::error::" "evil file"

report_and_exit "semgrep-smoke-helpers suite"
