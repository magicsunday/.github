#!/usr/bin/env bash
# Guards against the drift annotation-sanitize.sh's function comment used to
# warn about: hand-maintained implementations of the same escape-then-fold
# strategy going out of sync (issue #78 fixed one instance, issue #80 fixed
# a second, issue #49's batched missing-path sanitiser was a third). Issue
# #91 removed the duplication itself rather than testing that it stayed in
# sync: the filter text now lives in ONE readonly bash constant
# (ANNOTATION_SANITIZE_JQ_FILTER, annotation-sanitize.sh), and every call
# site interpolates it instead of retyping it - so the three sites are
# identical by construction, and this test's job shrinks to proving no site
# quietly reverted to a hand-typed literal.
#
# Anchored on each REAL call site's own surrounding, unrelated code rather
# than counted by occurrence of the constant's name anywhere in the file:
# a plain `grep -c NAME >= 2` threshold passes on two unrelated prose
# comments alone, with the one real call site reverted to a hand-typed
# literal right beside them - mutation-confirmed, test-quality-reviewer,
# GH-91. Anchoring on the call site's own neighbouring text (which a
# reversion does not touch) closes that gap without trying to pattern-match
# every whitespace/quoting variant a hand-typed reversion could take.
#
# Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
ANNOTATION_SANITIZE_FILE="${REPO_ROOT}/.github/scripts/lib/annotation-sanitize.sh"
REPORT_CHECK_FILE="${REPO_ROOT}/.github/scripts/lib/semgrep-report-check.sh"

require_file "${ANNOTATION_SANITIZE_FILE}"
require_file "${REPORT_CHECK_FILE}"
# failures=0 is set at lib/harness.sh's top level, sourced above.
# shellcheck disable=SC2154
if [ "${failures}" -gt 0 ]; then
    report_and_exit "annotation-sanitize jq-filter parity drift-guard test"
fi

# shellcheck source=../lib/annotation-sanitize.sh
source "${ANNOTATION_SANITIZE_FILE}"
assert_eq "ANNOTATION_SANITIZE_JQ_FILTER is the exact escape-then-fold filter" \
    'gsub("%"; "%25") | gsub("[[:cntrl:]]"; " ")' "${ANNOTATION_SANITIZE_JQ_FILTER:-}"

# Exactly one definition, and it is readonly - a second, non-readonly
# definition anywhere would let a later reassignment silently diverge from
# the assertion above without any of the per-site checks below noticing.
assert_eq "ANNOTATION_SANITIZE_JQ_FILTER is declared readonly exactly once" \
    "1" "$(grep -cE '^readonly ANNOTATION_SANITIZE_JQ_FILTER=' "${ANNOTATION_SANITIZE_FILE}")"

# sanitize_for_annotation() passes the WHOLE jq program as one argument, so
# its interpolation (`jq -Rsr "${ANNOTATION_SANITIZE_JQ_FILTER}"`) is
# self-contained on one line - anchoring on it directly is safe (confirmed,
# test-quality-reviewer, GH-91: a line-continuation reformat of the
# surrounding printf | jq pipe does not break it).
assert_nonempty \
    "$(grep -F -- 'jq -Rsr "${ANNOTATION_SANITIZE_JQ_FILTER}"' "${ANNOTATION_SANITIZE_FILE}")" \
    "sanitize_for_annotation() in ${ANNOTATION_SANITIZE_FILE} does not interpolate ANNOTATION_SANITIZE_JQ_FILTER into its jq -Rsr call"

# semgrep-report-check.sh's two call sites sit inside a larger, multi-line
# single-quoted jq program, so the interpolation is a bash quote-SPLICE
# (close the single-quote, double-quoted `${VAR}`, reopen the single-quote)
# rather than a whole-argument interpolation. An anchor keyed on the jq
# text AROUND that splice (the .path pipeline's closing `) as $path`, the
# batched pipeline's closing `)`) is fragile: moving that jq punctuation
# onto its own line changes no jq/bash behaviour at all, yet broke a
# line-anchored match in an earlier version of this test
# (mutation-confirmed, test-quality-reviewer, GH-91). The splice text
# itself - the sq single quote and the sq double-quoted variable
# reference between them - is a fixed three-token bash unit that a jq-level
# reformat has no reason to ever split, so counting its occurrences is the
# stable anchor: exactly two real call sites exist, and a hand-typed
# literal reversion at either one drops the count below two regardless of
# how the jq around it is laid out. A stray prose comment cannot inflate
# this count by accident - unlike a bare mention of the constant's name,
# reproducing this exact bash quoting inside a comment would be a strange
# thing to write.
sq="'"
splice_pattern="${sq}"'"${ANNOTATION_SANITIZE_JQ_FILTER}"'"${sq}"
assert_eq "semgrep-report-check.sh's two call sites both interpolate ANNOTATION_SANITIZE_JQ_FILTER (neither reverted to a hand-typed literal)" \
    "2" "$(grep -cF -- "${splice_pattern}" "${REPORT_CHECK_FILE}")"

report_and_exit "annotation-sanitize jq-filter parity drift-guard test"
