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
# Two different anchoring strategies, one per site shape:
# sanitize_for_annotation() interpolates the constant as its WHOLE jq
# argument, self-contained on one line, so a direct grep -F anchor on that
# line is stable. semgrep-report-check.sh's two sites splice the constant
# into a larger, multi-line single-quoted jq program instead - an anchor
# keyed on the jq punctuation immediately around the splice (a closing
# `) as $path`, a closing `)`) is fragile, since moving that punctuation
# onto its own line changes no jq/bash behaviour at all yet breaks a
# line-anchored match (mutation-confirmed, test-quality-reviewer, GH-91).
# A file-wide COUNT of the splice text is stable against that reformat, but
# introduces a different gap: two sites checked as one aggregate number
# lets a doubled occurrence at one site mask a reversion at the other,
# since both shapes sum to the same total (mutation-confirmed,
# test-quality-reviewer, GH-91). Extracting each site's own block first
# (via extract_block, anchored on text that identifies WHICH pipeline this
# is - "no-skipped-inventory" for the .path pipeline, the NUL-split call
# for the batched one - neither of which a jq reformat has any reason to
# move) and counting the splice WITHIN each site's own block independently
# closes both gaps at once: reformat-tolerant, because the window spans the
# whole block rather than the immediate splice-adjacent punctuation, and
# masking-proof, because each site's count is asserted on its own, so one
# site's total can never stand in for another's.
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

# The bash quote-splice that concatenates the constant into a multi-line jq
# program - close the single-quote, double-quoted ${VAR}, reopen the
# single-quote - is a fixed three-token unit a jq-level reformat has no
# reason to ever split, unlike the jq punctuation around it.
sq="'"
splice_pattern="${sq}"'"${ANNOTATION_SANITIZE_JQ_FILTER}"'"${sq}"

# Each real call site's own block, extracted independently via stable,
# site-identifying anchors that name WHICH pipeline this is rather than
# the immediate splice-adjacent jq punctuation.
path_pipeline_block="$(extract_block 'no-skipped-inventory' 'join("%0A")' "${REPORT_CHECK_FILE}")"
missing_path_block="$(extract_block 'split("\\u0000")' 'join("%0A")' "${REPORT_CHECK_FILE}")"

assert_eq "the .path pipeline in ${REPORT_CHECK_FILE} interpolates ANNOTATION_SANITIZE_JQ_FILTER exactly once, not a hand-typed literal" \
    "1" "$(grep -cF -- "${splice_pattern}" <<<"${path_pipeline_block}")"
assert_eq "the batched missing-path pipeline in ${REPORT_CHECK_FILE} interpolates ANNOTATION_SANITIZE_JQ_FILTER exactly once, not a hand-typed literal" \
    "1" "$(grep -cF -- "${splice_pattern}" <<<"${missing_path_block}")"

report_and_exit "annotation-sanitize jq-filter parity drift-guard test"
