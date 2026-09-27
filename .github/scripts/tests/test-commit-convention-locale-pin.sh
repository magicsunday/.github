#!/usr/bin/env bash
# Pins what test-commit-subject-predicate.sh's LC_ALL fallback cannot see
# (see its comment there): the commit-convention job's env pins a UTF-8
# locale, and its self-test step asserts it with assert_utf8_locale before
# it runs the table. Both are read from the parsed workflow, so the value
# cannot come from another key or job, and comment lines do not count.
#
# Run via run-tests.sh. Needs PyYAML, which lint.yml's shell-tests job
# installs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"
# shellcheck source=../lib/commit-subject-predicate.sh
source "${SCRIPT_DIR}/../lib/commit-subject-predicate.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/commit-convention.yml"

require_files_or_bail "commit-convention locale-pin test" "${WORKFLOW_FILE}"

# Prints jobs.commit-convention.env.LC_ALL, or nothing when that key is absent.
job_locale() {
    python3 - "$1" <<'PY'
import sys
import yaml

job = (yaml.safe_load(open(sys.argv[1], encoding="utf-8")).get("jobs") or {}).get("commit-convention") or {}
value = (job.get("env") or {}).get("LC_ALL")
if value is not None:
    print(value)
PY
}

# Prints the non-comment lines of the self-test step's run script.
self_test_script() {
    python3 - "$1" <<'PY'
import sys
import yaml

job = (yaml.safe_load(open(sys.argv[1], encoding="utf-8")).get("jobs") or {}).get("commit-convention") or {}
for step in job.get("steps") or []:
    if step.get("name") == "Self-test the subject predicate":
        for line in (step.get("run") or "").splitlines():
            if not line.lstrip().startswith("#"):
                print(line)
PY
}

readonly ASSERT_LINE='assert_utf8_locale "${LC_ALL:-}" || exit 1'
readonly TABLE_LINE='bash ".magicsunday-shared/.github/scripts/tests/test-commit-subject-predicate.sh"'

check_locale() {
    local locale="$1"
    assert_nonempty "${locale}" \
        "found no jobs.commit-convention.env.LC_ALL - the pin was dropped or moved"
    if locale_is_utf8 "${locale}"; then actual=utf8; else actual=other; fi
    assert_eq "the job-level LC_ALL (\"${locale}\") is a UTF-8 locale" utf8 "${actual}"
}

check_order() {
    assert_contains_in_order "the self-test step asserts the locale before it runs the table" \
        "$1" "${ASSERT_LINE}" "${TABLE_LINE}"
}

check_locale "$(job_locale "${WORKFLOW_FILE}")"
check_order "$(self_test_script "${WORKFLOW_FILE}")"

# Negative controls on fixture workflows: each must make the check it
# targets fail, or that check would pass for the wrong reason.
fixture_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "${fixture_dir}"' EXIT

write_fixture() {
    cat >"${fixture_dir}/wf.yml"
}

write_fixture <<'YAML'
jobs:
    other:
        env:
            LC_ALL: C.UTF-8
    commit-convention:
        outputs:
            LC_ALL: C.UTF-8
YAML
output="$(check_locale "$(job_locale "${fixture_dir}/wf.yml")")"
assert_starts_with_fail "a pin under another job or key does not count" "${output}"

write_fixture <<'YAML'
jobs:
    commit-convention:
        env:
            LC_ALL: "C.UTF-8" # pinned
YAML
if [ "$(job_locale "${fixture_dir}/wf.yml")" = "C.UTF-8" ]; then r=read; else r=misread; fi
assert_eq "a quoted pin with a trailing comment reads as its value" read "${r}"

write_fixture <<'YAML'
jobs:
    commit-convention:
        steps:
            - name: Self-test the subject predicate
              run: |
                  # assert_utf8_locale "${LC_ALL:-}" || exit 1
                  bash ".magicsunday-shared/.github/scripts/tests/test-commit-subject-predicate.sh"
YAML
output="$(check_order "$(self_test_script "${fixture_dir}/wf.yml")")"
assert_starts_with_fail "a commented-out assertion does not count" "${output}"

write_fixture <<'YAML'
jobs:
    commit-convention:
        steps:
            - name: Self-test the subject predicate
              run: |
                  bash ".magicsunday-shared/.github/scripts/tests/test-commit-subject-predicate.sh"
                  assert_utf8_locale "${LC_ALL:-}" || exit 1
YAML
output="$(check_order "$(self_test_script "${fixture_dir}/wf.yml")")"
assert_starts_with_fail "an assertion after the table does not count" "${output}"

report_and_exit "commit-convention locale-pin test"
