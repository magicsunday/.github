#!/usr/bin/env bash
# Pins the order of effects in ai-issue-labeler.yml's "Classify and label the
# issue" step: the label set is filtered right after it is fetched and before
# it is counted, and only then reaches the request builder and the guard. The
# library tests call the filter directly, so a step that dropped the call or
# moved it behind the count would leave them green while the model is offered
# the pull-request labels again. The same table pins where the API error log,
# the authentication exit and the confidence threshold sit around the call.
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

# Prints PASS when the statements of script "$1" run in the order the ORDER
# table below lists. Prints the failing step and the script otherwise.
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
the API error log||| echo "Anthropic API error for issue #
the auth failure exit|if [ "$http_status" = "401" ]
the non-200 skip||| warn_and_skip "Anthropic API request failed
the usage log|echo "Usage for issue #${ISSUE_NUMBER}: $(describe_api_usage "$response_body")"
the tool input extraction|tool_input=$(extract_tool_input "$response_body")
the confidence threshold|tool_input=$(apply_label_confidence "$tool_input" 2>/dev/null)
the guard|selected_output=$(resolve_labels_to_apply
ORDER
    echo "PASS: the step filters the label set between its fetch and its count"
}

# Prints PASS when the statement of script "$1" that starts with "$2" sits
# directly behind the test that keeps it from running on a successful call, so
# the statement cannot run for status 200. "$3" names the statement in the
# message. Prints FAIL otherwise.
check_status_gate() {
    awk -v prefix="$2" -v what="$3" '
        { lines[NR] = $0 }
        END {
            for (i = 2; i <= NR; i++) {
                if (index(lines[i], prefix) == 1) {
                    if (lines[i - 1] == "[ \"$http_status\" = \"200\" ] \\") { print "PASS: the " what " runs only for a status other than 200"; exit }
                    print "FAIL: the " what " is not directly behind the status test"; exit
                }
            }
            print "FAIL: no " what " statement"
        }
    ' <<<"$1"
}

check_error_log_gate() {
    check_status_gate "$1" '|| echo "Anthropic API error for issue #' "API error log"
}

check_skip_gate() {
    check_status_gate "$1" '|| warn_and_skip "Anthropic API request failed' "non-200 skip"
}

output="$(check_order "$(step_script "${WORKFLOW_FILE}")")"
assert_eq "the workflow step filters before it counts" \
    "PASS: the step filters the label set between its fetch and its count" "${output}"

output="$(check_error_log_gate "$(step_script "${WORKFLOW_FILE}")")"
assert_eq "the workflow step logs an API error only for a status other than 200" \
    "PASS: the API error log runs only for a status other than 200" "${output}"

output="$(check_skip_gate "$(step_script "${WORKFLOW_FILE}")")"
assert_eq "the workflow step skips a failed call only for a status other than 200" \
    "PASS: the non-200 skip runs only for a status other than 200" "${output}"

# Negative controls on fixture scripts: each must make the check fail, or the
# check would pass for the wrong reason.
FETCH='labels_json=$(gh api "repos/${REPO}/labels" --paginate)'
FILTER='labels_json=$(drop_pull_request_only_labels "$labels_json")'
MFILTER='labels_json=$(drop_maintainer_set_labels "$labels_json")'
COUNT='label_count=$(jq '"'"'length'"'"' <<<"$labels_json")'
REQUEST='request_body=$(build_ai_labeler_request "$REPO" "$TITLE" "$BODY" "$labels_json")'
EXTRACT='tool_input=$(extract_tool_input "$response_body")'
USAGE='echo "Usage for issue #${ISSUE_NUMBER}: $(describe_api_usage "$response_body")"'
SKIP='|| warn_and_skip "Anthropic API request failed for issue #${ISSUE_NUMBER} (HTTP ${http_status}); leaving labels untouched."'
CONFIDENCE='tool_input=$(apply_label_confidence "$tool_input" 2>/dev/null)'
ERRLOG='|| echo "Anthropic API error for issue #${ISSUE_NUMBER} (HTTP ${http_status}): $(describe_api_error "$response_body")"'
ERRGATE='[ "$http_status" = "200" ] \'
AUTHEXIT='if [ "$http_status" = "401" ] || [ "$http_status" = "402" ] || [ "$http_status" = "403" ]; then'
GUARD='selected_output=$(resolve_labels_to_apply "$tool_input" "$labels_json" "$existing")'

fixture_script() {
    printf '%s\n' "$@"
}

# A negative control must fail for the property it names. This asserts the
# check fails and that the failure names statement "$2", so a fixture that
# fails for another reason does not pass.
assert_fails_at() {
    local description="$1"
    local statement="$2"
    local output="$3"

    assert_starts_with_fail "${description}" "${output}"
    assert_contains "${description}: the failure names ${statement}" "${output}" ": ${statement}"
}

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${SKIP}" "${USAGE}" "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_eq "the fixture in the right order is accepted" \
    "PASS: the step filters the label set between its fetch and its count" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${SKIP}" "${USAGE}" "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a step without the filter does not count" "the filter" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${MFILTER}" "${FILTER}" "${COUNT}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${SKIP}" "${USAGE}" "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a pull-request filter behind the maintainer filter does not count" "the maintainer filter" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${COUNT}" "${FILTER}" "${MFILTER}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${SKIP}" "${USAGE}" "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a count before the filters does not count" "the count" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${GUARD}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${SKIP}" "${USAGE}" "${EXTRACT}" "${CONFIDENCE}")")"
assert_fails_at "a guard before the request builder does not count" "the guard" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${ERRLOG}" "${AUTHEXIT}" "${SKIP}" "${USAGE}" "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a step without the request builder does not count" "the request builder" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${ERRLOG}" "${REQUEST}" "${AUTHEXIT}" "${SKIP}" "${USAGE}" "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a request builder behind the API error log does not count" "the API error log" "${output}"

output="$(check_order "$(fixture_script "${FILTER}" "${FETCH}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${SKIP}" "${USAGE}" "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a filter before the fetch does not count" "the filter" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${COUNT}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${SKIP}" "${USAGE}" "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a step without the maintainer filter does not count" "the maintainer filter" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${COUNT}" "${MFILTER}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${SKIP}" "${USAGE}" "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a maintainer filter behind the count does not count" "the count" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${SKIP}" "${USAGE}" "${EXTRACT}" "${GUARD}")")"
assert_fails_at "a step without the confidence threshold does not count" "the confidence threshold" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${SKIP}" "${USAGE}" "${EXTRACT}" "${GUARD}" "${CONFIDENCE}")")"
assert_fails_at "a confidence threshold behind the guard does not count" "the guard" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${SKIP}" "${USAGE}" "${CONFIDENCE}" "${EXTRACT}" "${GUARD}")")"
assert_fails_at "a tool input extraction behind the confidence threshold does not count" "the confidence threshold" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${SKIP}" "${USAGE}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a step without the tool input extraction does not count" "the tool input extraction" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${AUTHEXIT}" "${SKIP}" "${USAGE}" "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a step without the API error log does not count" "the API error log" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${AUTHEXIT}" "${SKIP}" "${USAGE}" "${ERRLOG}" "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "an API error log behind the authentication exit does not count" "the auth failure exit" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${ERRLOG}" "${SKIP}" "${USAGE}" "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a step without the authentication exit does not count" "the auth failure exit" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${SKIP}" "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a step without the usage log does not count" "the usage log" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${SKIP}" "${EXTRACT}" "${USAGE}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a usage log behind the tool input extraction does not count" "the tool input extraction" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${USAGE}" "${SKIP}" "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a usage log before the non-200 skip does not count" "the usage log" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${USAGE}" "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a step without the non-200 skip does not count" "the non-200 skip" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${ERRLOG}" "${SKIP}" "${AUTHEXIT}" "${USAGE}" "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a non-200 skip before the authentication exit does not count" "the non-200 skip" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${SKIP}" 'echo "Usage for issue #${ISSUE_NUMBER}: $response_body"' "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a usage log that echoes the raw body does not count" "the usage log" "${output}"

output="$(check_order "$(fixture_script "${FETCH}" "${FILTER}" "${MFILTER}" "${COUNT}" "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${SKIP}" 'echo "Usage for issue #${ISSUE_NUMBER}: $(describe_api_error "$response_body")"' "${EXTRACT}" "${CONFIDENCE}" "${GUARD}")")"
assert_fails_at "a usage log that describes the error instead does not count" "the usage log" "${output}"

output="$(check_error_log_gate "$(fixture_script "${REQUEST}" "${ERRGATE}" "${ERRLOG}" "${AUTHEXIT}" "${CONFIDENCE}")")"
assert_eq "an API error log behind the status test is accepted" \
    "PASS: the API error log runs only for a status other than 200" "${output}"

output="$(check_error_log_gate "$(fixture_script "${REQUEST}" "${ERRLOG}" "${AUTHEXIT}" "${CONFIDENCE}")")"
assert_starts_with_fail "an API error log without the status test does not count" "${output}"

output="$(check_skip_gate "$(fixture_script "${REQUEST}" "${ERRGATE}" "${SKIP}" "${USAGE}")")"
assert_eq "a non-200 skip behind the status test is accepted" \
    "PASS: the non-200 skip runs only for a status other than 200" "${output}"

output="$(check_skip_gate "$(fixture_script "${REQUEST}" "true \\" "${SKIP}" "${USAGE}")")"
assert_starts_with_fail "a non-200 skip behind another test does not count" "${output}"

# The parser drops a comment line, so a call that only a comment mentions
# yields no statement, and it reads only the named step, so a statement of
# another step yields none either. The check reads the statements themselves,
# because the order check anchors on the start of a line and would pass either
# way.
fixture_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "${fixture_dir}"' EXIT
{
    printf 'jobs:\n    label:\n        steps:\n            - name: Classify and label the issue\n              run: |\n'
    printf '                  %s\n' "${FETCH}" "# ${FILTER}" "${MFILTER}" "${COUNT}"
    printf '            - name: Another step\n              run: |\n'
    printf '                  %s\n' "${REQUEST}"
} >"${fixture_dir}/wf.yml"
output="$(step_script "${fixture_dir}/wf.yml")"
expected="$(printf '%s\n' "${FETCH}" "${MFILTER}" "${COUNT}")"
assert_eq "a comment line and another step are left out of the parsed step" "${expected}" "${output}"

report_and_exit "ai issue labeler step test"
