#!/usr/bin/env bash
# Tests the gate job `all-security-checks` of the canonical security caller
# (templates/security.yml) and of this repository's own caller
# (.github/workflows/security.yml). Run via run-tests.sh. Optional arguments
# name the caller files to test instead of those two.
#
# The run script of the gate step is read from the parsed caller, so a comment
# that only mentions a result does not count. It is fed the `needs` document of
# a run and the exit status is checked. The structure that a branch protection
# depends on is checked as well: the job name, `if: always()`, no token scopes,
# the results read from the environment and a `needs` list that names every
# other job of the file.
#
# Needs python3 with PyYAML and jq. No `set -e`: assertions capture exit codes
# themselves, and a failing assertion must be counted, not abort the run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

# The expected expressions are literal workflow text, never shell expansions.
# shellcheck disable=SC2016
EXPECTED_IF='${{ always() }}'
# shellcheck disable=SC2016
EXPECTED_NEEDS_ENV='${{ toJSON(needs) }}'

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

if [ "$#" -gt 0 ]; then
    callers=("$@")
else
    callers=("${REPO_ROOT}/templates/security.yml" "${REPO_ROOT}/.github/workflows/security.yml")
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Prints one JSON object that describes the gate job of the caller "$1".
describe_gate() {
    python3 -I - "$1" << 'PY'
import json
import sys
import yaml

jobs = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["jobs"]
gate = jobs.get("all-security-checks") or {}
steps = gate.get("steps") or []
step = steps[0] if steps else {}
print(json.dumps({
    "name": gate.get("name"),
    "if": gate.get("if"),
    "permissions": gate.get("permissions"),
    "needs": sorted(gate.get("needs") or []),
    "others": sorted(key for key in jobs if key != "all-security-checks"),
    "step_count": len(steps),
    "has_checkout": any("uses" in each for each in steps),
    "run": step.get("run", ""),
    "needs_env": (step.get("env") or {}).get("NEEDS"),
}))
PY
}

# Runs the gate script "$2" with the needs document "$3" and expects a passing
# gate when "$1" is 0 and any failing exit status otherwise, because a document
# that jq cannot read has to fail the gate too, whatever status it ends with.
# Sets `case_output` for the caller.
run_case() {
    local label="$1" expected="$2" script="$3" needs="$4" name="$5"
    local status=0
    case_output="$(NEEDS="${needs}" bash "${script}" 2>&1)" || status=$?

    if [ "${expected}" -eq 0 ]; then
        assert_eq "${label}: ${name}" '0' "${status}"
    elif [ "${status}" -ne 0 ]; then
        echo "PASS: ${label}: ${name}"
    else
        echo "FAIL: ${label}: ${name}: expected a failing exit status, got 0"
        failures=$((failures + 1))
    fi
}

for caller in "${callers[@]}"; do
    label="$(basename "$(dirname "${caller}")")/$(basename "${caller}")"

    if ! structure="$(describe_gate "${caller}")"; then
        echo "FAIL: ${label}: cannot parse the caller"
        failures=$((failures + 1))
        continue
    fi

    field() {
        jq -r "$1" <<< "${structure}"
    }

    assert_eq "${label}: job name is the required check name" 'All security checks' "$(field .name)"
    assert_eq "${label}: gate runs always" "${EXPECTED_IF}" "$(field .if)"
    assert_eq "${label}: gate has no token scopes" '{}' "$(field '.permissions | tojson')"
    assert_eq "${label}: gate has exactly one step" '1' "$(field .step_count)"
    assert_eq "${label}: gate checks nothing out" 'false' "$(field .has_checkout)"
    assert_eq "${label}: results come from toJSON(needs)" "${EXPECTED_NEEDS_ENV}" "$(field .needs_env)"
    assert_eq "${label}: needs names every other job" "$(field '.others | tojson')" "$(field '.needs | tojson')"
    assert_nonempty "${label}: the other jobs exist" "$(field '.others | join(",")')"

    script_file="$(mktemp "${WORK_DIR}/gate.XXXXXX")"
    field .run > "${script_file}"
    assert_nonempty "${label}: gate step has a run script" "$(cat "${script_file}")"

    run_case "${label}" 0 "${script_file}" '{"a":{"result":"success"},"b":{"result":"success"}}' 'all succeeded passes'
    run_case "${label}" 0 "${script_file}" '{"a":{"result":"success"},"b":{"result":"skipped"}}' 'succeeded and skipped passes'
    run_case "${label}" 0 "${script_file}" '{"a":{"result":"skipped"},"b":{"result":"skipped"}}' 'only skipped passes'
    run_case "${label}" 1 "${script_file}" '{"a":{"result":"success"},"b":{"result":"failure"}}' 'one failure fails'
    assert_contains "${label}: the failure names the job and its result" "${case_output}" 'b=failure'
    run_case "${label}" 1 "${script_file}" '{"a":{"result":"success"},"b":{"result":"cancelled"}}' 'one cancellation fails'
    assert_contains "${label}: the cancellation names the job and its result" "${case_output}" 'b=cancelled'
    run_case "${label}" 1 "${script_file}" '{"a":{"result":"skipped"},"b":{"result":"failure"}}' 'failure next to skipped fails'
    run_case "${label}" 1 "${script_file}" '{"a":{"result":"success"},"b":{"result":"neutral"}}' 'unknown result fails'
    run_case "${label}" 1 "${script_file}" '{"a":{"result":"success"},"b":{}}' 'a job without a result fails'
    run_case "${label}" 1 "${script_file}" '{"a":{"result":"success"},"b":"success"}' 'a job entry that is no object fails'
    run_case "${label}" 1 "${script_file}" '{}' 'empty needs fails'
    run_case "${label}" 1 "${script_file}" '' 'an empty document fails'
    run_case "${label}" 1 "${script_file}" 'not json' 'malformed document fails'
    run_case "${label}" 1 "${script_file}" '[{"result":"success"}]' 'a document that is no object fails'
done

report_and_exit 'security gate tests'
