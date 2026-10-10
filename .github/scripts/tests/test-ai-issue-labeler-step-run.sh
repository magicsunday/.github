#!/usr/bin/env bash
# Runs the "Classify and label the issue" step of ai-issue-labeler.yml for
# real, with stubs for `gh` and `curl` and a trace around the library
# functions, and asserts what the step did. The text pins in
# test-ai-issue-labeler-step.sh cannot see a call that is still in the text
# but never runs, for example behind `if false; then ... fi`. A run can.
#
# No test here reaches the network or the model. The stub for `curl` answers
# with a fixed response and the stub for `gh` serves a fixed label set.
#
# Run via run-tests.sh. Needs PyYAML, which lint.yml's shell-tests job
# installs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/ai-issue-labeler.yml"
LIBRARY_FILE="${REPO_ROOT}/.github/scripts/lib/ai-issue-labeler.sh"

require_files_or_bail "ai issue labeler step run test" "${WORKFLOW_FILE}" "${LIBRARY_FILE}"

WORK_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "${WORK_DIR}"' EXIT

mkdir -p "${WORK_DIR}/bin" "${WORK_DIR}/lib"

# Writes the run script of the "Classify and label the issue" step to "$2".
python3 - "${WORKFLOW_FILE}" "${WORK_DIR}/step.sh" <<'PY' || exit 1
import sys
import yaml

for job in (yaml.safe_load(open(sys.argv[1], encoding="utf-8")).get("jobs") or {}).values():
    for step in job.get("steps") or []:
        if step.get("name") == "Classify and label the issue":
            open(sys.argv[2], "w", encoding="utf-8").write(step["run"])
            sys.exit(0)
sys.exit("step not found")
PY

# The library under test, with every function the step calls wrapped so that
# a call is recorded in the trace before the real function runs.
cat >"${WORK_DIR}/lib/ai-issue-labeler.sh" <<LIB
# shellcheck disable=SC1090
source "${LIBRARY_FILE}"
for traced in drop_pull_request_only_labels drop_maintainer_set_labels \\
    build_ai_labeler_request describe_api_error describe_api_usage \\
    extract_tool_input apply_label_confidence resolve_labels_to_apply \\
    build_labels_payload neutralize_command_markers; do
    eval "original_\$(declare -f "\${traced}")"
    eval "\${traced}() { echo \"\${traced}\" >>\"\\\${TRACE_FILE}\"; original_\${traced} \"\\\$@\"; }"
done
LIB

# gh serves the label set and the labels of the issue, and records what the
# step writes. Every call is traced with its arguments.
cat >"${WORK_DIR}/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"${TRACE_FILE}"
case "$*" in
    *"/labels"*"-X POST"*) cat >"${POSTED_FILE}" ;;
    *"/labels"*"--paginate"*)
        [ -z "${GH_FETCH_FAILS:-}" ] || exit 1
        cat "${LABELS_FIXTURE}"
        ;;
    *"--jq"*) echo "${ISSUE_LABELS:-[]}" ;;
esac
STUB

# curl records its arguments and answers with the fixed body. Like the real
# call it reads the request from stdin only for `--data-binary @-` and prints
# the status on its own line only for `-w`, so a step that drops either
# argument changes what it sees.
cat >"${WORK_DIR}/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl" >>"${TRACE_FILE}"
printf '%s\n' "$*" >"${ARGV_FILE}"
[ -z "${CURL_FAILS:-}" ] || exit 7
case "$*" in *"--data-binary @-"*) cat >"${REQUEST_FILE}" ;; esac
cat "${RESPONSE_FILE}"
case "$*" in *"-w "*) printf '\n%s' "${RESPONSE_STATUS}" ;; esac
STUB
chmod +x "${WORK_DIR}/bin/gh" "${WORK_DIR}/bin/curl"

cat >"${WORK_DIR}/labels.json" <<'JSON'
[
    {"name": "bug", "description": "Something is broken"},
    {"name": "needs-triage", "description": "Not yet classified"},
    {"name": "dependencies", "description": "Pull requests that update a dependency file"},
    {"name": "status: accepted", "description": "Set by maintainers after triage"}
]
JSON

# Prints a model response with one assign_labels call that grades the label
# "$1" with the confidence "$2".
tool_response() {
    printf '{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"assign_labels","input":{"labels":[{"label":"%s","confidence":%s}]}}],"usage":{"input_tokens":100,"output_tokens":20}}' "$1" "$2"
}

# Runs the step once. "$1" is the HTTP status and "$2" the file that holds the
# response body. The trace, the request, the written payload, the output and
# the exit status are left in ${WORK_DIR}.
run_step() {
    : >"${WORK_DIR}/trace"
    rm -f "${WORK_DIR}/posted.json" "${WORK_DIR}/request.json" "${WORK_DIR}/argv"
    env \
        PATH="${WORK_DIR}/bin:${PATH}" \
        TRACE_FILE="${WORK_DIR}/trace" \
        POSTED_FILE="${WORK_DIR}/posted.json" \
        REQUEST_FILE="${WORK_DIR}/request.json" \
        ARGV_FILE="${WORK_DIR}/argv" \
        RESPONSE_FILE="$2" \
        RESPONSE_STATUS="$1" \
        LABELS_FIXTURE="${LABELS_FIXTURE:-${WORK_DIR}/labels.json}" \
        GH_TOKEN=unused REPO=owner/repo ISSUE_NUMBER=7 \
        ISSUE_TITLE="Crash on start" ISSUE_BODY="It crashes." \
        ANTHROPIC_API_KEY=unused SCRIPT_LIB="${WORK_DIR}/lib" \
        bash "${WORK_DIR}/step.sh" >"${WORK_DIR}/output" 2>&1
    echo "$?" >"${WORK_DIR}/status"
}

# Prints the recorded calls on one line, separated by " | ".
trace() {
    paste -sd'|' "${WORK_DIR}/trace" | sed 's/|/ | /g'
}

output() {
    cat "${WORK_DIR}/output"
}

status() {
    cat "${WORK_DIR}/status"
}

BEFORE_REQUEST='gh api repos/owner/repo/labels --paginate | drop_pull_request_only_labels | drop_maintainer_set_labels | build_ai_labeler_request | curl'

# A successful answer runs every stage in order. The two filters sit before
# the request, the confidence step sits between the answer and the guard and
# the labels are written last.
tool_response bug 0.95 >"${WORK_DIR}/response.json"
run_step 200 "${WORK_DIR}/response.json"
assert_eq "a successful answer runs every stage in order" \
    "${BEFORE_REQUEST} | describe_api_usage | extract_tool_input | gh api repos/owner/repo/issues/7 --jq [.labels[].name] | neutralize_command_markers | neutralize_command_markers | apply_label_confidence | resolve_labels_to_apply | build_labels_payload | gh api repos/owner/repo/issues/7/labels -X POST --input - | neutralize_command_markers" \
    "$(trace)"
assert_eq "a successful answer exits cleanly" "0" "$(status)"
assert_eq "a successful answer writes the chosen label" \
    '{"labels":["bug"]}' "$(jq -c . "${WORK_DIR}/posted.json")"
assert_eq "a successful answer logs no API error" \
    "0" "$(grep -c 'Anthropic API error' "${WORK_DIR}/output")"
assert_eq "the request offers the repository label" \
    "yes" "$(grep -q 'Something is broken' "${WORK_DIR}/request.json" && echo yes || echo no)"
assert_eq "the request call carries its timeouts, the status format and the stdin body" \
    "-sS --connect-timeout 10 --max-time 30 -w \\n%{http_code} https://api.anthropic.com/v1/messages -H Content-Type: application/json -H x-api-key: unused -H anthropic-version: 2023-06-01 --data-binary @-" \
    "$(cat "${WORK_DIR}/argv")"
assert_eq "the request leaves out the pull request label and the maintainer label" \
    "0" "$(grep -c -E 'dependencies|status: accepted' "${WORK_DIR}/request.json")"
assert_eq "a successful answer logs the model answer and the applied label" \
    "2" "$(grep -c -E 'Model answer for issue #7: |Applied labels to issue #7: bug' "${WORK_DIR}/output")"

# A label below its floor does not reach the guard, so the fallback applies.
tool_response bug 0.1 >"${WORK_DIR}/response.json"
run_step 200 "${WORK_DIR}/response.json"
assert_eq "a label below its floor is replaced by the needs-triage fallback" \
    '{"labels":["needs-triage"]}' "$(jq -c . "${WORK_DIR}/posted.json")"

# An answer without a tool call logs the usage and then gives up.
printf '{"stop_reason":"max_tokens","content":[],"usage":{"input_tokens":100,"output_tokens":1024}}' >"${WORK_DIR}/response.json"
run_step 200 "${WORK_DIR}/response.json"
assert_eq "an answer without a tool call stops after reading it" \
    "${BEFORE_REQUEST} | describe_api_usage | extract_tool_input" "$(trace)"
assert_eq "an answer without a tool call exits cleanly" "0" "$(status)"
assert_eq "an answer without a tool call still logs the usage" \
    "1" "$(grep -c 'Usage for issue #7: stop_reason=max_tokens' "${WORK_DIR}/output")"
assert_eq "an answer without a tool call writes no label" \
    "no" "$([ -e "${WORK_DIR}/posted.json" ] && echo yes || echo no)"

# A failed call logs the API error and gives up without reading an answer.
printf '{"type":"error","error":{"type":"api_error","message":"overloaded"}}' >"${WORK_DIR}/response.json"
run_step 500 "${WORK_DIR}/response.json"
assert_eq "a failed call stops after the error log" \
    "${BEFORE_REQUEST} | describe_api_error | neutralize_command_markers" "$(trace)"
assert_eq "a failed call exits cleanly" "0" "$(status)"
assert_eq "a failed call logs the API error once" \
    "1" "$(grep -c 'Anthropic API error for issue #7 (HTTP 500)' "${WORK_DIR}/output")"
assert_eq "a failed call writes no label" \
    "no" "$([ -e "${WORK_DIR}/posted.json" ] && echo yes || echo no)"

# A rejected key fails the job loudly, after the error log.
printf '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}' >"${WORK_DIR}/response.json"
run_step 401 "${WORK_DIR}/response.json"
assert_eq "a rejected key fails the step" "1" "$(status)"
assert_eq "a rejected key logs the API error and the failure" \
    "2" "$(grep -c -E 'Anthropic API error for issue #7 \(HTTP 401\)|::error::Anthropic API rejected' "${WORK_DIR}/output")"
assert_eq "a rejected key stops after the error log" \
    "${BEFORE_REQUEST} | describe_api_error | neutralize_command_markers" "$(trace)"

# Statuses 402 and 403 are standing account problems like 401, any other
# failing status is a transient one that gives up quietly.
for rejected in 402 403; do
    run_step "${rejected}" "${WORK_DIR}/response.json"
    assert_eq "status ${rejected} fails the step" "1" "$(status)"
done
for transient in 429 529; do
    run_step "${transient}" "${WORK_DIR}/response.json"
    assert_eq "status ${transient} exits cleanly" "0" "$(status)"
    assert_eq "status ${transient} logs the API error and gives up" \
        "2" "$(grep -c -E "Anthropic API error for issue #7 \\(HTTP ${transient}\\)|::warning::Anthropic API request failed" "${WORK_DIR}/output")"
    assert_eq "status ${transient} writes no label" \
        "no" "$([ -e "${WORK_DIR}/posted.json" ] && echo yes || echo no)"
done

# A type label the issue already carries is left alone, so the model's own
# type label is dropped and nothing is written.
tool_response bug 0.95 >"${WORK_DIR}/response.json"
ISSUE_LABELS='["enhancement"]' run_step 200 "${WORK_DIR}/response.json"
assert_eq "an issue with a type label gets no second type label" \
    "no" "$([ -e "${WORK_DIR}/posted.json" ] && echo yes || echo no)"
assert_eq "an issue with a type label logs its labels and the empty result" \
    "2" "$(grep -c -E 'existing labels: \["enhancement"\]|No label to apply for issue #7' "${WORK_DIR}/output")"
assert_eq "an issue with a type label exits cleanly" "0" "$(status)"

# Each transient failure gives up with a warning and a clean exit.
CURL_FAILS=1 run_step 200 "${WORK_DIR}/response.json"
assert_eq "a failing curl gives up with a warning" \
    "1" "$(grep -c '::warning::Could not reach the Anthropic API' "${WORK_DIR}/output")"
assert_eq "a failing curl exits cleanly" "0" "$(status)"

GH_FETCH_FAILS=1 run_step 200 "${WORK_DIR}/response.json"
assert_eq "a failing label fetch gives up with a warning" \
    "1" "$(grep -c '::warning::Could not fetch the label set' "${WORK_DIR}/output")"
assert_eq "a failing label fetch sends no request" \
    "no" "$([ -e "${WORK_DIR}/request.json" ] && echo yes || echo no)"
assert_eq "a failing label fetch exits cleanly" "0" "$(status)"

printf '{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"assign_labels","input":{"labels":5}}],"usage":{"input_tokens":1,"output_tokens":1}}' >"${WORK_DIR}/response.json"
run_step 200 "${WORK_DIR}/response.json"
assert_eq "an answer the confidence step cannot read gives up with a warning" \
    "1" "$(grep -c '::warning::Could not apply the confidence threshold' "${WORK_DIR}/output")"
assert_eq "an answer the confidence step cannot read writes no label" \
    "no" "$([ -e "${WORK_DIR}/posted.json" ] && echo yes || echo no)"
assert_eq "an answer the confidence step cannot read exits cleanly" "0" "$(status)"

# A repository whose labels are all filtered out sends no request.
cat >"${WORK_DIR}/filtered.json" <<'JSON'
[
    {"name": "dependencies", "description": "Pull requests that update a dependency file"},
    {"name": "status: accepted", "description": "Set by maintainers after triage"}
]
JSON
LABELS_FIXTURE="${WORK_DIR}/filtered.json" run_step 200 "${WORK_DIR}/response.json"
assert_eq "a repository with no label to choose from sends no request" \
    "${BEFORE_REQUEST%% | build_ai_labeler_request*}" "$(trace)"
assert_eq "a repository with no label to choose from says so" \
    "1" "$(grep -c '::notice::owner/repo has no labels to choose from' "${WORK_DIR}/output")"
assert_eq "a repository with no label to choose from exits cleanly" "0" "$(status)"

report_and_exit "AI issue-labeler step run tests"
