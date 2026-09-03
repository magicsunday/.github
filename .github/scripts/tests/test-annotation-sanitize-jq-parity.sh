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

# Exactly one call site (sanitize_for_annotation() itself) interpolates the
# constant without quoting it inside the jq program string, and both
# semgrep-report-check.sh sites interpolate it quoted (they sit inside a
# larger single-quoted jq program, so bash string concatenation needs the
# surrounding quotes). Both forms are legitimate uses, so this counts
# occurrences of the variable NAME rather than requiring one exact spelling.
sanitize_uses="$(grep -c 'ANNOTATION_SANITIZE_JQ_FILTER' "${ANNOTATION_SANITIZE_FILE}")"
report_check_uses="$(grep -c 'ANNOTATION_SANITIZE_JQ_FILTER' "${REPORT_CHECK_FILE}")"
assert_eq "annotation-sanitize.sh references ANNOTATION_SANITIZE_JQ_FILTER at least twice (definition + use)" \
    "true" "$([ "${sanitize_uses}" -ge 2 ] && echo true || echo false)"
assert_eq "semgrep-report-check.sh references ANNOTATION_SANITIZE_JQ_FILTER at both call sites" \
    "true" "$([ "${report_check_uses}" -ge 2 ] && echo true || echo false)"

# The regression this guards against: a call site quietly reverting to its
# own hand-typed literal instead of the shared constant. A literal
# `gsub("%"; "%25")` may appear ONLY inside annotation-sanitize.sh's own
# constant definition and its prose comments (which name the filter for a
# human reader) - never as executable jq text in semgrep-report-check.sh.
literal_in_report_check="$(grep -c 'gsub("%"; "%25")' "${REPORT_CHECK_FILE}")"
assert_eq "semgrep-report-check.sh contains no hand-typed literal copy of the sanitiser filter" \
    "0" "${literal_in_report_check}"

report_and_exit "annotation-sanitize jq-filter parity drift-guard test"
