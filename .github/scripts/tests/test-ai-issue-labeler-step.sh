#!/usr/bin/env bash
# Pins the order of effects in ai-issue-labeler.yml's "Classify and label the
# issue" step: the label set is filtered right after it is fetched and before
# it is counted, and only then reaches the request builder and the guard. The
# library tests call the filter directly, so a step that dropped the call or
# moved it behind the count would leave them green while the model is offered
# the pull-request labels again.
# The statements are read from the parsed workflow with comment lines
# dropped, so a comment that only mentions a call does not count.
#
# Run via run-tests.sh. Needs PyYAML, which lint.yml's shell-tests job
# installs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/ai-issue-labeler.yml"

require_files_or_bail "ai issue labeler step test" "${WORKFLOW_FILE}"

# Prints the run script of the "Classify and label the issue" step of
# workflow "$1", one statement per line, stripped of surrounding whitespace,
# with comment lines dropped.
step_script() {
    python3 - "$1" <<'PY'
import sys
import yaml

for job in (yaml.safe_load(open(sys.argv[1], encoding="utf-8")).get("jobs") or {}).values():
    for step in job.get("steps") or []:
        if step.get("name") != "Classify and label the issue":
            continue
        for line in (step.get("run") or "").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                print(line)
PY
}

# Prints the number of the first line of "$2" that starts with "$1", or
# nothing when no line does.
line_starting_with() {
    awk -v prefix="$1" 'index($0, prefix) == 1 { print NR; exit }' <<<"$2"
}

# Prints PASS when the statements of script "$1" run in this order: the
# fetch of the label set, the filter, the count, the request builder and the
# guard. Prints the failing step and the script otherwise.
check_order() {
    local script="$1"
    local previous=0
    local name prefix number
    while IFS='|' read -r name prefix; do
        number="$(line_starting_with "${prefix}" "${script}")"
        if [ -z "${number}" ]; then
            _harness_fail "the step has a statement for: ${name}" "${script}"
            return
        fi
        if [ "${number}" -le "${previous}" ]; then
            _harness_fail "the step runs this before the statement above it: ${name}" "${script}"
            return
        fi
        previous="${number}"
    done <<'ORDER'
the fetch of the label set|labels_json=$(gh api "repos/${REPO}/labels"
the filter|labels_json=$(drop_pull_request_only_labels "$labels_json")
the maintainer filter|labels_json=$(drop_maintainer_set_labels "$labels_json")
the count|label_count=$(jq 'length' <<<"$labels_json")
the request builder|request_body=$(build_ai_labeler_request
the confidence threshold|tool_input=$(apply_label_confidence "$tool_input")
the guard|selected_output=$(resolve_labels_to_apply
ORDER
    echo "PASS: the step filters the label set between its fetch and its count"
}

output="$(check_order "$(step_script "${WORKFLOW_FILE}")")"
assert_eq "the workflow step filters before it counts" \
    "PASS: the step filters the label set between its fetch and its count" "${output}"

# Negative controls on fixture scripts: each must make the check fail, or the
# check would pass for the wrong reason.
FETCH='labels_json=$(gh api "repos/${REPO}/labels" --paginate)'
FILTER='labels_json=$(drop_pull_request_only_labels "$labels_json")'
MFILTER='labels_json=$(drop_maintainer_set_labels "$labels_json")'
COUNT='label_count=$(jq '"'"'length'"'"' <<<"$labels_json")'
REQUEST='request_body=$(build_ai_labeler_request "$REPO" "$TITLE" "$BODY" "$labels_json")'
CONFIDENCE='tool_input=$(apply_label_confidence "$tool_input")'
GUARD='selected_output=$(resolve_labels_to_apply "$tool_input" "$labels_json" "$existing")'

fixture_script() {
    printf '%s\n' "$@"
}

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${CONFIDENCE}" "${GUARD}")")"
assert_eq "the fixture in the right order is accepted" \
    "PASS: the step filters the label set between its fetch and its count" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${CONFIDENCE}" "${GUARD}")")"
assert_starts_with_fail "a step without the filter does not count" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${MFILTER}" "${COUNT}" "${FILTER}" "${REQUEST}" "${CONFIDENCE}" "${GUARD}")")"
assert_starts_with_fail "a filter behind the count does not count" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${GUARD}" "${REQUEST}" "${CONFIDENCE}")")"
assert_starts_with_fail "a guard before the request builder does not count" "${output}"

output="$(check_order "$(fixture_script "${FILTER}" "${FETCH}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${CONFIDENCE}" "${GUARD}")")"
assert_starts_with_fail "a filter before the fetch does not count" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "# ${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${CONFIDENCE}" "${GUARD}")")"
assert_starts_with_fail "a commented-out filter does not count" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${COUNT}" "${REQUEST}" "${CONFIDENCE}" "${GUARD}")")"
assert_starts_with_fail "a step without the maintainer filter does not count" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${COUNT}" "${MFILTER}" "${REQUEST}" "${CONFIDENCE}" "${GUARD}")")"
assert_starts_with_fail "a maintainer filter behind the count does not count" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "# ${MFILTER}" "${COUNT}" "${REQUEST}" "${CONFIDENCE}" "${GUARD}")")"
assert_starts_with_fail "a commented-out maintainer filter does not count" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${GUARD}")")"
assert_starts_with_fail "a step without the confidence threshold does not count" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${GUARD}" "${CONFIDENCE}")")"
assert_starts_with_fail "a confidence threshold behind the guard does not count" "${output}"

# The same through the parser: a workflow whose step carries the filter only
# in a comment yields no filter statement.
fixture_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "${fixture_dir}"' EXIT
{
    printf 'jobs:\n    label:\n        steps:\n            - name: Classify and label the issue\n              run: |\n'
    printf '                  %s\n' "${FETCH}" "# ${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${CONFIDENCE}" "${GUARD}"
} >"${fixture_dir}/wf.yml"
output="$(check_order "$(step_script "${fixture_dir}/wf.yml")")"
assert_starts_with_fail "a comment line in the parsed step does not count" "${output}"

report_and_exit "ai issue labeler step test"
