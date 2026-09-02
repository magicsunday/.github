#!/usr/bin/env bash
# Guards against the exact recurring drift annotation-sanitize.sh's function
# comment names: hand-maintained implementations of the same escape-then-fold
# strategy going out of sync (issue #78 fixed one instance, issue #80 fixed a
# second - sanitize_for_annotation() now routes through jq itself, but the
# filter text is still duplicated as a literal string, so nothing stops
# another - issue #49's batched missing-path sanitiser is the third).
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
# The batched missing-path sanitiser (issue #49) hand-inlines the same
# escape-then-fold pair a third time, rather than calling
# sanitize_for_annotation() per element, specifically to avoid one jq fork
# per missing path - see that block's own comment for the measured reason.
# Anchored on real code, not the surrounding prose: the start anchor
# (`split("\u0000")[0:-1]`) is unique in the file, so sed's range begins
# there - the earlier, unrelated `join("%0A")` a different jq pipeline
# emits well above it is never reachable as an end match, since sed only
# looks for it from the start match onward (re-derive:
# `grep -n 'split(\|join(' <REPORT_CHECK_FILE>` before trusting this
# comment - it names what is true of the CURRENT file, not a fixed fact).
missing_path_filter="$(extract_gsub_pair 'split("\\u0000")\[0:-1\]$' 'join("%0A")$' "${REPORT_CHECK_FILE}")"

assert_nonempty "${sanitize_filter}" \
    "extracted no gsub() calls from sanitize_for_annotation() in ${ANNOTATION_SANITIZE_FILE} - function body or regex shape changed"
assert_nonempty "${report_check_filter}" \
    "extracted no gsub() calls from the .path pipeline in ${REPORT_CHECK_FILE} - pipeline or regex shape changed"
assert_nonempty "${missing_path_filter}" \
    "extracted no gsub() calls from the batched missing-path pipeline in ${REPORT_CHECK_FILE} - pipeline or regex shape changed"

assert_eq "sanitize_for_annotation()'s jq filter matches semgrep-report-check.sh's .path gsub pipeline" \
    "${report_check_filter}" "${sanitize_filter}"
assert_eq "sanitize_for_annotation()'s jq filter matches semgrep-report-check.sh's batched missing-path pipeline" \
    "${missing_path_filter}" "${sanitize_filter}"

report_and_exit "annotation-sanitize jq-filter parity drift-guard test"
