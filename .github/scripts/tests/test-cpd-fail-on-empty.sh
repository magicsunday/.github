#!/usr/bin/env bash
# Pins that cpd.yml's jscpd run fails a scan that analyzed no file, and that
# the README adoption text names the same command. Without the flag such a
# scan passes, so the gate would stay green while checking nothing.
# The command is read from the parsed workflow, so a comment that only
# mentions the flag does not count.
#
# Run via run-tests.sh. Needs PyYAML, which lint.yml's shell-tests job
# installs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/cpd.yml"
README_FILE="${REPO_ROOT}/README.md"

require_files_or_bail "cpd fail-on-empty test" "${WORKFLOW_FILE}" "${README_FILE}"

readonly EXPECTED_COMMAND='node_modules/.bin/jscpd --config .jscpd.json --skip-comments --no-tips --fail-on-empty'

# Prints the run script of the "Run jscpd" step of workflow "$1", one
# statement per line, stripped of surrounding whitespace, with comment lines
# dropped.
step_script() {
    python3 - "$1" <<'PY'
import sys
import yaml

job = (yaml.safe_load(open(sys.argv[1], encoding="utf-8")).get("jobs") or {}).get("cpd") or {}
for step in job.get("steps") or []:
    if step.get("name") != "Run jscpd":
        continue
    for line in (step.get("run") or "").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            print(line)
PY
}

# Prints the keys that can neutralize the "Run jscpd" step of workflow "$1"
# without touching its command: `if` and `continue-on-error`, on the cpd job
# and on the step, as `job_if=...`, `job_coe=...`, `step_if=...` and
# `step_coe=...`. Prints nothing for the step when it is missing.
gate_fields() {
    python3 - "$1" <<'PY'
import sys
import yaml

job = (yaml.safe_load(open(sys.argv[1], encoding="utf-8")).get("jobs") or {}).get("cpd") or {}
print(f"job_if={job.get('if', '')}")
print(f"job_coe={str(job.get('continue-on-error', False)).lower()}")
for step in job.get("steps") or []:
    if step.get("name") != "Run jscpd":
        continue
    print(f"step_if={step.get('if', '')}")
    print(f"step_coe={str(step.get('continue-on-error', False)).lower()}")
PY
}

readonly EXPECTED_GATE=$'job_if=\njob_coe=false\nstep_if=\nstep_coe=false'

check_gate() {
    assert_eq "neither the cpd job nor the Run jscpd step is skipped or allowed to fail" \
        "${EXPECTED_GATE}" "$1"
}

# Whole lines, not substrings: a statement that only mentions the command
# (an inline comment, `echo`, a trailing `|| true`) does not count.
check_command() {
    local script="$1"
    if grep -qxF -- "${EXPECTED_COMMAND}" <<<"${script}"; then
        echo "PASS: the Run jscpd step runs the command with --fail-on-empty"
    else
        _harness_fail "the Run jscpd step runs the command with --fail-on-empty" "${script}"
    fi
}

check_command "$(step_script "${WORKFLOW_FILE}")"
assert_contains "the README adoption text names the same command" \
    "$(cat "${README_FILE}")" "\`${EXPECTED_COMMAND}\`"
check_gate "$(gate_fields "${WORKFLOW_FILE}")"

# Negative controls on fixture workflows: each must make the check fail, or
# the check would pass for the wrong reason.
fixture_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "${fixture_dir}"' EXIT

# Writes a workflow whose cpd job holds only the Run jscpd step, with the
# script lines "$@".
write_fixture() {
    {
        printf 'jobs:\n    cpd:\n        steps:\n            - name: Run jscpd\n              run: |\n'
        printf '                  %s\n' "$@"
    } >"${fixture_dir}/wf.yml"
}

write_fixture "${EXPECTED_COMMAND}"
output="$(check_command "$(step_script "${fixture_dir}/wf.yml")")"
assert_eq "the fixture writer produces a step script check_command accepts" PASS "${output%%:*}"

write_fixture "node_modules/.bin/jscpd --config .jscpd.json --skip-comments --no-tips"
output="$(check_command "$(step_script "${fixture_dir}/wf.yml")")"
assert_starts_with_fail "a command without the flag does not count" "${output}"

write_fixture "# ${EXPECTED_COMMAND}" "node_modules/.bin/jscpd --config .jscpd.json --skip-comments --no-tips"
output="$(check_command "$(step_script "${fixture_dir}/wf.yml")")"
assert_starts_with_fail "a commented-out command does not count" "${output}"

write_fixture "${EXPECTED_COMMAND} || true"
output="$(check_command "$(step_script "${fixture_dir}/wf.yml")")"
assert_starts_with_fail "a command whose failure is ignored does not count" "${output}"

# Writes a workflow whose cpd job holds only the Run jscpd step with the
# accepted command: "$1" holds extra job keys and "$2" extra step keys, one
# per line (either may be empty).
write_gate_fixture() {
    local key
    {
        printf 'jobs:\n    cpd:\n'
        [ -z "$1" ] || while IFS= read -r key; do
            printf '        %s\n' "${key}"
        done <<<"$1"
        printf '        steps:\n            - name: Run jscpd\n'
        [ -z "$2" ] || while IFS= read -r key; do
            printf '              %s\n' "${key}"
        done <<<"$2"
        printf '              run: |\n                  %s\n' "${EXPECTED_COMMAND}"
    } >"${fixture_dir}/wf.yml"
}

write_gate_fixture "" ""
assert_eq "the fixture writer produces a workflow check_gate accepts" \
    "${EXPECTED_GATE}" "$(gate_fields "${fixture_dir}/wf.yml")"

for variant in "|if: false" "|if: github.event_name == 'push'" "|continue-on-error: true" \
    "if: false|" "continue-on-error: true|"; do
    write_gate_fixture "${variant%%|*}" "${variant#*|}"
    output="$(check_gate "$(gate_fields "${fixture_dir}/wf.yml")")"
    assert_starts_with_fail \
        "job keys \"${variant%%|*}\" with step keys \"${variant#*|}\" do not count" "${output}"
done

report_and_exit "cpd fail-on-empty test"
