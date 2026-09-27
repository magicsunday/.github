#!/usr/bin/env bash
# Pins what test-commit-subject-predicate.sh's LC_ALL fallback cannot see
# (see its comment there): the commit-convention job's env pins a UTF-8
# locale, and its self-test step asserts it with assert_utf8_locale before
# it runs the table, on the pull-request gate and without continue-on-error.
# Whether a failing table still fails the step is left to the script itself
# (see check_order).
# All of it is read from the parsed workflow, so the value cannot come from
# another key or job, and comment lines do not count.
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

# Prints one field of the commit-convention job from workflow "$1": with
# "$2" = locale, env.LC_ALL (nothing when absent); with "$2" = script, the
# self-test step's run script, one statement per line, stripped of
# surrounding whitespace, with comment lines dropped; with "$2" = gate, the
# self-test step's `if` and `continue-on-error` as `if=...` and `coe=...`.
workflow_field() {
    python3 - "$1" "$2" <<'PY'
import sys
import yaml

job = (yaml.safe_load(open(sys.argv[1], encoding="utf-8")).get("jobs") or {}).get("commit-convention") or {}
if sys.argv[2] == "locale":
    value = (job.get("env") or {}).get("LC_ALL")
    if value is not None:
        print(value)
else:
    for step in job.get("steps") or []:
        if step.get("name") != "Self-test the subject predicate":
            continue
        if sys.argv[2] == "gate":
            print(f"if={step.get('if', '')}")
            print(f"coe={str(step.get('continue-on-error', False)).lower()}")
        else:
            for line in (step.get("run") or "").splitlines():
                line = line.strip()
                if line and not line.startswith("#"):
                    print(line)
PY
}

readonly ASSERT_LINE='assert_utf8_locale "${LC_ALL:-}" || exit 1'
readonly TABLE_LINE='bash ".magicsunday-shared/.github/scripts/tests/test-commit-subject-predicate.sh"'
# The gate every shared-checkout step carries. The self-test must run on it
# without continue-on-error.
readonly EXPECTED_GATE=$'if=github.event.pull_request.number != \'\'\ncoe=false'

check_locale() {
    local locale="$1"
    assert_nonempty "${locale}" \
        "found no jobs.commit-convention.env.LC_ALL - the pin was dropped or moved"
    if locale_is_utf8 "${locale}"; then actual=utf8; else actual=other; fi
    assert_eq "the job-level LC_ALL (\"${locale}\") is a UTF-8 locale" utf8 "${actual}"
}

# Whole lines, not substrings: a single-line statement that only mentions the
# call (an inline comment, `if false; then ...; fi`, a trailing `|| true`)
# does not count. This matches statements line by line and does not follow
# the shell's control flow, so it misses anything that skips the table or
# ignores its result on other lines: a multi-line block that never runs, a
# heredoc, an `exit` in between, or `set +e` before it.
check_order() {
    local script="$1" assert_at table_at
    assert_at="$(grep -nxF -- "${ASSERT_LINE}" <<<"${script}" | head -n 1 | cut -d: -f1)"
    table_at="$(grep -nxF -- "${TABLE_LINE}" <<<"${script}" | head -n 1 | cut -d: -f1)"
    if [ -n "${assert_at}" ] && [ -n "${table_at}" ] && [ "${assert_at}" -lt "${table_at}" ]; then
        echo "PASS: the self-test step asserts the locale before it runs the table"
    else
        _harness_fail "the self-test step asserts the locale before it runs the table" "${script}"
    fi
}

check_gate() {
    assert_eq "the self-test step runs on the pull-request gate without continue-on-error" \
        "${EXPECTED_GATE}" "$1"
}

check_locale "$(workflow_field "${WORKFLOW_FILE}" locale)"
check_order "$(workflow_field "${WORKFLOW_FILE}" script)"
check_gate "$(workflow_field "${WORKFLOW_FILE}" gate)"

# Negative controls on fixture workflows: each must make the check it
# targets fail, or that check would pass for the wrong reason.
fixture_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "${fixture_dir}"' EXIT

# Writes a workflow whose commit-convention job holds only the self-test
# step: "$1" is one extra step key (or empty), the rest are its script lines.
write_step_fixture() {
    local extra="$1"
    shift
    {
        printf 'jobs:\n    commit-convention:\n        steps:\n            - name: Self-test the subject predicate\n'
        [ -z "${extra}" ] || printf '              %s\n' "${extra}"
        printf '              run: |\n'
        printf '                  %s\n' "$@"
    } >"${fixture_dir}/wf.yml"
}

cat >"${fixture_dir}/wf.yml" <<'YAML'
jobs:
    other:
        env:
            LC_ALL: C.UTF-8
    commit-convention:
        outputs:
            LC_ALL: C.UTF-8
YAML
output="$(check_locale "$(workflow_field "${fixture_dir}/wf.yml" locale)")"
assert_starts_with_fail "a pin under another job or key does not count" "${output}"

printf 'jobs:\n    commit-convention:\n        env:\n            LC_ALL: C\n' >"${fixture_dir}/wf.yml"
output="$(check_locale "$(workflow_field "${fixture_dir}/wf.yml" locale)")"
assert_starts_with_fail "a non-UTF-8 pin does not count" "${output}"

write_step_fixture "" "# ${ASSERT_LINE}" "${TABLE_LINE}"
output="$(check_order "$(workflow_field "${fixture_dir}/wf.yml" script)")"
assert_starts_with_fail "a commented-out assertion does not count" "${output}"

write_step_fixture "" "${TABLE_LINE}" "${ASSERT_LINE}"
output="$(check_order "$(workflow_field "${fixture_dir}/wf.yml" script)")"
assert_starts_with_fail "an assertion after the table does not count" "${output}"

for variant in ": # ${ASSERT_LINE}" "if false; then ${ASSERT_LINE}; fi"; do
    write_step_fixture "" "${variant}" "${TABLE_LINE}"
    output="$(check_order "$(workflow_field "${fixture_dir}/wf.yml" script)")"
    assert_starts_with_fail "an assertion written as \"${variant}\" does not count" "${output}"
done

write_step_fixture "" "${ASSERT_LINE}" "${TABLE_LINE} || true"
output="$(check_order "$(workflow_field "${fixture_dir}/wf.yml" script)")"
assert_starts_with_fail "a table run whose failure is ignored does not count" "${output}"

write_step_fixture "if: github.event.pull_request.number != ''" "${ASSERT_LINE}" "${TABLE_LINE}"
if [ "$(workflow_field "${fixture_dir}/wf.yml" gate)" = "${EXPECTED_GATE}" ]; then r=matched; else r=missed; fi
assert_eq "the fixture writer produces the expected gate" matched "${r}"

for extra in "if: false" "continue-on-error: true"; do
    write_step_fixture "${extra}" "${ASSERT_LINE}" "${TABLE_LINE}"
    output="$(check_gate "$(workflow_field "${fixture_dir}/wf.yml" gate)")"
    assert_starts_with_fail "a self-test step with \"${extra}\" does not count" "${output}"
done

report_and_exit "commit-convention locale-pin test"
