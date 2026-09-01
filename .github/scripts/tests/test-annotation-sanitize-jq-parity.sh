#!/usr/bin/env bash
# Guards against the exact recurring drift annotation-sanitize.sh's function
# comment names: two hand-maintained implementations of the same
# escape-then-fold strategy going out of sync (issue #78 fixed one instance,
# issue #80 fixed a second - sanitize_for_annotation() now routes through jq
# itself, but the filter text is still duplicated as a literal string in two
# files, so nothing stops a third).
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

# The pattern requires the two gsub() calls joined by exactly `|` with
# nothing else between them, so a one-sided edit that swaps the joining
# operator (e.g. `,`) or inserts a third jq step between the two calls
# breaks the match on that side instead of silently comparing equal -
# the two separately-run `grep -oE 'gsub\(...\)'` extractions this
# replaced would reconstruct an artificial `|`-joined string via `paste`
# regardless of what actually joined the calls in the source. Squeezed to
# one line first (tr) so the match works across semgrep-report-check.sh's
# multi-line formatting the same way it does on annotation-sanitize.sh's
# single line. gsub("<match>"; "<replacement>") preserves the exact quoted
# content of each call, so this cannot mistake the space
# sanitize_for_annotation() folds a control byte to for the empty string a
# naive whitespace-strip would leave behind - a real risk here, since the
# second gsub's own replacement literal IS a single space.
extract_gsub_pair() {
    extract_block "$1" "$2" "$3" | tr '\n' ' ' | tr -s ' ' \
        | grep -oE 'gsub\([^)]*\)[[:space:]]*\|[[:space:]]*gsub\([^)]*\)'
}

sanitize_filter="$(extract_gsub_pair '^sanitize_for_annotation' '^}' "${ANNOTATION_SANITIZE_FILE}")"
report_check_filter="$(extract_gsub_pair '(.path \/\/ "(no path)")' 'as \$path' "${REPORT_CHECK_FILE}")"

assert_nonempty "${sanitize_filter}" \
    "extracted no gsub() calls from sanitize_for_annotation() in ${ANNOTATION_SANITIZE_FILE} - function body or regex shape changed"
assert_nonempty "${report_check_filter}" \
    "extracted no gsub() calls from the .path pipeline in ${REPORT_CHECK_FILE} - pipeline or regex shape changed"

assert_eq "sanitize_for_annotation()'s jq filter matches semgrep-report-check.sh's .path gsub pipeline" \
    "${report_check_filter}" "${sanitize_filter}"

report_and_exit "annotation-sanitize jq-filter parity drift-guard test"
