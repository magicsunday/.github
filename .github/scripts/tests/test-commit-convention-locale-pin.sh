#!/usr/bin/env bash
# Pins commit-convention.yml's locale handling, which the decision-table test
# cannot see: that test keeps an LC_ALL that is set and falls back to UTF-8
# when it is not, so it stays green if the job-level `LC_ALL` pin is deleted.
# Checked here instead: the job env pins a UTF-8 locale, and the self-test
# step asserts it with assert_utf8_locale before it runs the table.
#
# Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"
# shellcheck source=../lib/commit-subject-predicate.sh
source "${SCRIPT_DIR}/../lib/commit-subject-predicate.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/commit-convention.yml"

require_files_or_bail "commit-convention locale-pin test" "${WORKFLOW_FILE}"

# The job-level env sits at 12 spaces; a step-level env is indented deeper,
# so it cannot stand in for the job pin.
job_locale="$(grep -E '^ {12}LC_ALL: ' "${WORKFLOW_FILE}" | sed -E 's/^ {12}LC_ALL: *//')"
assert_nonempty "${job_locale}" \
    "found no job-level LC_ALL in ${WORKFLOW_FILE} - the pin was dropped or moved"
if locale_is_utf8 "${job_locale}"; then actual=utf8; else actual=other; fi
assert_eq "the job-level LC_ALL (\"${job_locale}\") is a UTF-8 locale" utf8 "${actual}"

self_test_step="$(extract_block '- name: Self-test the subject predicate' '- name:' "${WORKFLOW_FILE}")"
assert_contains_in_order "the self-test step asserts the locale before it runs the table" \
    "${self_test_step}" \
    'assert_utf8_locale "${LC_ALL:-}" || exit 1' \
    'bash ".magicsunday-shared/.github/scripts/tests/test-commit-subject-predicate.sh"'

report_and_exit "commit-convention locale-pin test"
