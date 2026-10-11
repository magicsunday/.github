#!/usr/bin/env bash
# Runs the "Classify and label the issue" step of ai-issue-labeler.yml for
# real, with stubs for `gh` and `curl` and a trace around the library
# functions, and asserts what the step did. The text pins in
# test-ai-issue-labeler-step.sh cannot see a call that is still in the text
# but never runs, for example behind `if false; then ... fi`. A run can.
#
# No test here reaches the network or the model. The stub for `curl` answers
# with a fixed response and the stub for `gh` serves fixed labels and records the
# label write.
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

# A knob that is already set in the caller's environment must not steer a run.
KNOBS=(FAIL_FUNCTION POST_FAILS GH_FETCH_FAILS CURL_FAILS ISSUE_READ_FAILS
    STEP_NO_BODY ISSUE_LABELS LABELS_FIXTURE)
unset "${KNOBS[@]}"

WORK_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "${WORK_DIR}"' EXIT

mkdir -p "${WORK_DIR}/bin" "${WORK_DIR}/lib"

# The run script of the "Classify and label the issue" step.
workflow_step_run "${WORKFLOW_FILE}" "Classify and label the issue" >"${WORK_DIR}/step.sh" || exit 1

# The library under test, with every function the step calls wrapped so that
# a call is recorded in the trace before the real function runs. A run can
# force one function to fail by naming it in FAIL_FUNCTION.
cat >"${WORK_DIR}/lib/ai-issue-labeler.sh" <<'LIB'
# shellcheck disable=SC1090
source "${REAL_LIBRARY_FILE}"
for traced in drop_pull_request_only_labels drop_maintainer_set_labels \
    build_ai_labeler_request describe_api_error describe_api_usage \
    extract_tool_input apply_label_confidence resolve_labels_to_apply \
    build_labels_payload neutralize_command_markers; do
    eval "original_$(declare -f "${traced}")"
    eval "${traced}() { echo \"${traced}\" >>\"\${TRACE_FILE}\"; [ \"\${FAIL_FUNCTION:-}\" != \"${traced}\" ] || return 1; original_${traced} \"\$@\"; }"
done
LIB

# gh serves the label set and the labels of the issue, and records what the
# step writes. Every call is traced with its arguments.
cat >"${WORK_DIR}/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"${TRACE_FILE}"
case "$*" in
    *"/labels"*"-X POST"*)
        cat >"${POSTED_FILE}"
        [ -z "${POST_FAILS:-}" ] || exit 1
        echo '[{"name":"POSTECHO"}]'
        ;;
    *"/labels"*"--paginate"*)
        [ -z "${GH_FETCH_FAILS:-}" ] || exit 1
        cat "${LABELS_FIXTURE}"
        ;;
    *"--jq"*)
        if [ -n "${ISSUE_READ_FAILS:-}" ]; then
            echo "gh: stub failure" >&2
            exit 1
        fi
        echo "${ISSUE_LABELS:-[]}"
        ;;
esac
STUB

# curl records its arguments as a JSON array, so the argument boundaries stay
# visible, and answers with the fixed body. Like the real call it reads the
# request from stdin only for `--data-binary @-` and prints the status on its
# own line only for `-w`, so a step that drops either argument changes what it
# sees.
cat >"${WORK_DIR}/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl" >>"${TRACE_FILE}"
jq -n -c '$ARGS.positional' --args -- "$@" >"${ARGV_FILE}"
[ -z "${CURL_FAILS:-}" ] || exit 7
case "$*" in *"--data-binary @-"*) cat >"${REQUEST_FILE}" ;; esac
cat "${RESPONSE_FILE}"
case "$*" in *"-w "*) printf '\n%s' "${RESPONSE_STATUS}" ;; esac
STUB
chmod +x "${WORK_DIR}/bin/gh" "${WORK_DIR}/bin/curl"

# One array per page, the way `gh api --paginate` prints them.
cat >"${WORK_DIR}/labels.json" <<'JSON'
[
    {"name": "bug", "description": "Something is broken"},
    {"name": "needs-triage", "description": "Not yet classified"},
    {"name": "question", "description": null}
]
[
    {"name": "help wanted", "description": "Extra attention"},
    {"name": "##[notice]odd", "description": "A name the runner would read as a command"},
    {"name": "dependencies", "description": "Pull requests that update a dependency file"},
    {"name": "status: accepted", "description": "Set by maintainers after triage"}
]
JSON

# Prints a model response with one assign_labels call that grades the label
# "$1" with the confidence "$2".
tool_response() {
    printf '{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"assign_labels","input":{"labels":[{"label":"%s","confidence":%s}]}}],"usage":{"input_tokens":100,"output_tokens":20}}' "$1" "$2"
}

# Runs the step once with the HTTP status "$1" and the response body that
# ${WORK_DIR}/response.json holds. The trace, the request, the written payload,
# the output and the exit status are left in ${WORK_DIR}.
run_step() {
    : >"${WORK_DIR}/trace"
    rm -f "${WORK_DIR}/posted.json" "${WORK_DIR}/request.json" "${WORK_DIR}/argv"
    local body_args=(ISSUE_BODY="It crashes.")
    [ -z "${STEP_NO_BODY:-}" ] || body_args=()
    # The step sees only what is passed here, plus the knobs a case has set.
    local knob_args=() name
    for name in "${KNOBS[@]}"; do
        [ -z "${!name+x}" ] || knob_args+=("${name}=${!name}")
    done
    env -i \
        PATH="${WORK_DIR}/bin:${PATH}" HOME="${WORK_DIR}" TMPDIR="${WORK_DIR}" \
        TRACE_FILE="${WORK_DIR}/trace" \
        POSTED_FILE="${WORK_DIR}/posted.json" \
        REAL_LIBRARY_FILE="${LIBRARY_FILE}" \
        REQUEST_FILE="${WORK_DIR}/request.json" \
        ARGV_FILE="${WORK_DIR}/argv" \
        RESPONSE_FILE="${WORK_DIR}/response.json" \
        RESPONSE_STATUS="$1" \
        LABELS_FIXTURE="${LABELS_FIXTURE:-${WORK_DIR}/labels.json}" \
        GH_TOKEN=token-gh REPO=owner/repo ISSUE_NUMBER=7 \
        ISSUE_TITLE="Crash on start" "${body_args[@]+"${body_args[@]}"}" \
        ANTHROPIC_API_KEY=key-anthropic SCRIPT_LIB="${WORK_DIR}/lib" \
        "${knob_args[@]+"${knob_args[@]}"}" \
        bash "${WORK_DIR}/step.sh" </dev/null >"${WORK_DIR}/output" 2>"${WORK_DIR}/errput"
    echo "$?" >"${WORK_DIR}/status"
}

# Prints the recorded calls on one line, separated by " | ".
trace() {
    paste -sd'|' "${WORK_DIR}/trace" | sed 's/|/ | /g'
}

# Prints how many lines of the step output on stdout match the extended regex
# "$1". The step writes its log lines and workflow commands to stdout, so the
# tests look for them there.
logged() {
    grep -c -E "$1" "${WORK_DIR}/output"
}

# Prints yes when the step wrote nothing to stderr, otherwise no.
quiet_stderr() {
    [ -s "${WORK_DIR}/errput" ] && echo no || echo yes
}

# Prints how many lines of the step output equal "$1" exactly.
logged_line() {
    grep -c -F -x -- "$1" "${WORK_DIR}/output"
}

# Prints yes when the file "$2" of the last run holds the text "$1".
has_text() {
    grep -q -F -- "$1" "${WORK_DIR}/$2" && echo yes || echo no
}

# Prints yes when the file "$1" of the last run exists, otherwise no.
exists() {
    [ -e "${WORK_DIR}/$1" ] && echo yes || echo no
}

status() {
    cat "${WORK_DIR}/status"
}

BEFORE_REQUEST='gh api repos/owner/repo/labels --paginate | drop_pull_request_only_labels | drop_maintainer_set_labels | build_ai_labeler_request | curl'

# A successful answer runs every stage in order. The filters sit before
# the request, the confidence step sits between the answer and the guard and
# the labels are written last.
tool_response bug 0.95 >"${WORK_DIR}/response.json"
run_step 200
assert_eq "a successful answer runs every stage in order" \
    "${BEFORE_REQUEST} | describe_api_usage | extract_tool_input | gh api repos/owner/repo/issues/7 --jq [.labels[].name] | neutralize_command_markers | neutralize_command_markers | apply_label_confidence | resolve_labels_to_apply | build_labels_payload | gh api repos/owner/repo/issues/7/labels -X POST --input - | neutralize_command_markers" \
    "$(trace)"
assert_eq "a successful answer exits cleanly" "0" "$(status)"
assert_eq "a successful answer writes the chosen label" \
    '{"labels":["bug"]}' "$(jq -c . "${WORK_DIR}/posted.json")"
assert_eq "the request call carries its timeouts, the status format and the stdin body" \
    '["-sS","--connect-timeout","10","--max-time","30","-w","\\n%{http_code}","https://api.anthropic.com/v1/messages","-H","Content-Type: application/json","-H","x-api-key: key-anthropic","-H","anthropic-version: 2023-06-01","--data-binary","@-"]' \
    "$(cat "${WORK_DIR}/argv")"
assert_eq "the request offers a label that has no description" \
    "yes" "$(has_text 'question' request.json)"
assert_eq "the request names the repository" \
    "yes" "$(has_text 'for the repository owner/repo. The issue title' request.json)"
assert_eq "the request offers neither the pull request label nor the maintainer label" \
    "[]" "$(jq -c '[.. | strings | select(. == "dependencies" or . == "status: accepted")]' "${WORK_DIR}/request.json")"
assert_eq "a successful answer logs the model answer and the existing labels" \
    "1" "$(logged_line 'Model answer for issue #7: {"labels":[{"label":"bug","confidence":0.95}]} | existing labels: []')"
assert_eq "a successful answer writes nothing to stderr" \
    "yes" "$(quiet_stderr)"
assert_eq "a successful answer logs the applied label" \
    "1" "$(logged 'Applied labels to issue #7: bug')"
assert_eq "a successful answer keeps the output of the label write out of the log" \
    "0" "$(logged 'POSTECHO')"
assert_eq "the request offers a label from the second page of labels" \
    "yes" "$(has_text 'help wanted' request.json)"
assert_eq "the request carries the issue text as the user message" \
    $'Issue title:\nCrash on start\n\nIssue body:\nIt crashes.' \
    "$(jq -r '.messages[0].content' "${WORK_DIR}/request.json")"

# A label below its floor does not reach the guard, so the fallback applies.
tool_response bug 0.1 >"${WORK_DIR}/response.json"
run_step 200
assert_eq "a label below its floor is replaced by the needs-triage fallback" \
    '{"labels":["needs-triage"]}' "$(jq -c . "${WORK_DIR}/posted.json")"

# An answer without a tool call logs the usage and then gives up.
printf '{"stop_reason":"max_tokens","content":[],"usage":{"input_tokens":100,"output_tokens":1024}}' >"${WORK_DIR}/response.json"
run_step 200
assert_eq "an answer without a tool call stops after reading it" \
    "${BEFORE_REQUEST} | describe_api_usage | extract_tool_input" "$(trace)"
assert_eq "an answer without a tool call exits cleanly" "0" "$(status)"
assert_eq "an answer without a tool call gives up with a warning" \
    "1" "$(logged '::warning::Anthropic response for issue #7 carried no assign_labels tool call')"
assert_eq "an answer without a tool call still logs the usage" \
    "1" "$(logged 'Usage for issue #7: stop_reason=max_tokens')"
assert_eq "an answer without a tool call writes no label" \
    "no" "$(exists posted.json)"

# A failed call logs the API error and gives up without reading an answer.
printf '{"type":"error","error":{"type":"api_error","message":"overloaded"}}' >"${WORK_DIR}/response.json"
run_step 500
assert_eq "a failed call stops after the error log" \
    "${BEFORE_REQUEST} | describe_api_error | neutralize_command_markers" "$(trace)"
assert_eq "a failed call exits cleanly" "0" "$(status)"
assert_eq "a failed call logs the API error with the reason the API gave" \
    "1" "$(logged_line 'Anthropic API error for issue #7 (HTTP 500): api_error: overloaded')"
assert_eq "a failed call gives up with a warning" \
    "1" "$(logged '::warning::Anthropic API request failed')"
assert_eq "a failed call writes no label" \
    "no" "$(exists posted.json)"

# A rejected key (401) and the account problems 402 and 403 fail the job
# loudly, after the error log and with the reason the API gave. Any other
# status that is not 200 gives up with a warning and a clean exit.
printf '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}' >"${WORK_DIR}/response.json"
for rejected in 401 402 403; do
    run_step "${rejected}"
    assert_eq "status ${rejected} fails the step" "1" "$(status)"
    assert_eq "status ${rejected} logs the API error with the reason the API gave" \
        "1" "$(logged_line "Anthropic API error for issue #7 (HTTP ${rejected}): authentication_error: invalid x-api-key")"
    assert_eq "status ${rejected} logs the failure" \
        "1" "$(logged '::error::Anthropic API rejected')"
    assert_eq "status ${rejected} stops after the error log" \
        "${BEFORE_REQUEST} | describe_api_error | neutralize_command_markers" "$(trace)"
done
for other in 400 404 429 529; do
    run_step "${other}"
    assert_eq "status ${other} exits cleanly" "0" "$(status)"
    assert_eq "status ${other} logs the API error" \
        "1" "$(logged "Anthropic API error for issue #7 \\(HTTP ${other}\\)")"
    assert_eq "status ${other} gives up with a warning" \
        "1" "$(logged '::warning::Anthropic API request failed')"
    assert_eq "status ${other} writes no label" \
        "no" "$(exists posted.json)"
done

# A success status other than 200 is no success for the step either.
tool_response bug 0.95 >"${WORK_DIR}/response.json"
run_step 201
assert_eq "status 201 exits cleanly" "0" "$(status)"
assert_eq "status 201 logs the API error" \
    "1" "$(logged 'Anthropic API error for issue #7 \(HTTP 201\)')"
assert_eq "status 201 gives up with a warning" \
    "1" "$(logged '::warning::Anthropic API request failed')"
assert_eq "status 201 writes no label" "no" "$(exists posted.json)"

# A type label the issue already carries is left alone, so the model's own
# type label is dropped and nothing is written.
tool_response bug 0.95 >"${WORK_DIR}/response.json"
ISSUE_LABELS='["enhancement"]' run_step 200
assert_eq "an issue with a type label gets no second type label" \
    "no" "$(exists posted.json)"
assert_eq "an issue with a type label logs its labels" \
    "1" "$(logged 'existing labels: \["enhancement"\]')"
assert_eq "an issue with a type label logs the empty result" \
    "1" "$(logged 'No label to apply for issue #7')"
assert_eq "an issue with a type label exits cleanly" "0" "$(status)"

# Another label on the issue does not stop the type label from being written.
ISSUE_LABELS='["help wanted"]' run_step 200
assert_eq "an issue with only another label still gets the type label" \
    '{"labels":["bug"]}' "$(jq -c . "${WORK_DIR}/posted.json")"

# Each of these failures gives up with a warning and a clean exit.
CURL_FAILS=1 run_step 200
assert_eq "a failing curl gives up with a warning" \
    "1" "$(logged '::warning::Could not reach the Anthropic API')"
assert_eq "a failing curl exits cleanly" "0" "$(status)"
assert_eq "a failing curl writes no label" "no" "$(exists posted.json)"

GH_FETCH_FAILS=1 run_step 200
assert_eq "a failing label fetch gives up with a warning" \
    "1" "$(logged '::warning::Could not fetch the label set')"
assert_eq "a failing label fetch sends no request" \
    "no" "$(exists request.json)"
assert_eq "a failing label fetch exits cleanly" "0" "$(status)"

printf '{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"assign_labels","input":{"labels":5}}],"usage":{"input_tokens":1,"output_tokens":1}}' >"${WORK_DIR}/response.json"
run_step 200
assert_eq "an answer the confidence step cannot read gives up with a warning" \
    "1" "$(logged '::warning::Could not apply the confidence threshold')"
assert_eq "an answer the confidence step cannot read writes no label" \
    "no" "$(exists posted.json)"
assert_eq "an answer the confidence step cannot read exits cleanly" "0" "$(status)"

# A failure of the live label read, of the request builder or of the guard
# gives up with a warning, and a failing label write fails the step.
tool_response bug 0.95 >"${WORK_DIR}/response.json"
ISSUE_READ_FAILS=1 run_step 200
assert_eq "a failing read of the issue labels gives up with a warning" \
    "1" "$(logged '::warning::Could not read the current labels')"
assert_eq "a failing read of the issue labels writes no label" "no" "$(exists posted.json)"
assert_eq "a failing read of the issue labels keeps the error text of gh" \
    "yes" "$(has_text 'gh: stub failure' errput)"
assert_eq "a failing read of the issue labels exits cleanly" "0" "$(status)"

FAIL_FUNCTION=build_ai_labeler_request run_step 200
assert_eq "a failing request builder gives up with a warning" \
    "1" "$(logged '::warning::Could not build the classification request')"
assert_eq "a failing request builder sends no request" "no" "$(exists request.json)"
assert_eq "a failing request builder exits cleanly" "0" "$(status)"

FAIL_FUNCTION=resolve_labels_to_apply run_step 200
assert_eq "a failing guard gives up with a warning" \
    "1" "$(logged '::warning::Could not resolve which labels to apply')"
assert_eq "a failing guard writes no label" "no" "$(exists posted.json)"
assert_eq "a failing guard exits cleanly" "0" "$(status)"

# A failing label filter or a failing payload builder fails the step, because
# the step cannot go on without their result.
for failing in drop_pull_request_only_labels drop_maintainer_set_labels build_labels_payload; do
    FAIL_FUNCTION="${failing}" run_step 200
    assert_eq "a failing ${failing} fails the step" "1" "$(status)"
    assert_eq "a failing ${failing} gives up without a warning" "0" "$(logged '::warning::')"
    assert_eq "a failing ${failing} writes no label" "no" "$(exists posted.json)"
    assert_eq "a failing ${failing} does not log the labels as applied" \
        "0" "$(logged 'Applied labels to issue')"
done

POST_FAILS=1 run_step 200
assert_eq "a failing label write fails the step" "1" "$(status)"
assert_eq "a failing label write is the last call of the step" \
    "yes" "$(case "$(trace)" in *"-X POST --input -") echo yes ;; *) echo no ;; esac)"
assert_eq "a failing label write does not give up with a warning" \
    "0" "$(logged '::warning::')"
assert_eq "a failing label write does not log the labels as applied" \
    "0" "$(logged 'Applied labels to issue')"

# The step still runs when the issue has no body.
STEP_NO_BODY=1 run_step 200
assert_eq "an issue without a body still gets its label" \
    '{"labels":["bug"]}' "$(jq -c . "${WORK_DIR}/posted.json")"
assert_eq "an issue without a body sends an empty body in the request" \
    $'Issue title:\nCrash on start\n\nIssue body:' \
    "$(jq -r '.messages[0].content' "${WORK_DIR}/request.json")"

# Several labels reach the payload and the log together.
printf '{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"assign_labels","input":{"labels":[{"label":"help wanted","confidence":0.9},{"label":"question","confidence":0.9}]}}],"usage":{"input_tokens":1,"output_tokens":1}}' >"${WORK_DIR}/response.json"
run_step 200
assert_eq "two labels are written together" \
    '{"labels":["help wanted","question"]}' "$(jq -c . "${WORK_DIR}/posted.json")"
assert_eq "two labels are logged together" \
    "1" "$(logged 'Applied labels to issue #7: help wanted question')"

# Text that the runner would read as a command never reaches the log as such,
# neither in the model answer, nor in the issue labels, nor in the applied labels.
tool_response '##[notice]odd' 0.95 >"${WORK_DIR}/response.json"
ISSUE_LABELS='["##[group]x"]' run_step 200
assert_eq "no command marker reaches the log" \
    "0" "$(logged '##\[')"
assert_eq "the model answer and the applied labels are logged neutralised" \
    "2" "$(logged '## \[notice\]odd')"
assert_eq "the issue labels are logged neutralised" \
    "1" "$(logged 'existing labels: \["## \[group\]x"\]')"

# The jq error of the confidence step quotes the model answer, so it must not
# reach the log. The answer itself appears once, in the line that logs it.
printf '{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"assign_labels","input":{"labels":"LEAKCHECK"}}],"usage":{"input_tokens":1,"output_tokens":1}}' >"${WORK_DIR}/response.json"
run_step 200
assert_eq "the model answer is logged once" \
    "1" "$(logged 'LEAKCHECK')"
assert_eq "the error text of the confidence step stays out of the log" \
    "yes" "$(quiet_stderr)"

# A repository with exactly one usable label still sends a request.
cat >"${WORK_DIR}/single.json" <<'JSON'
[{"name": "bug", "description": "Something is broken"}]
JSON
tool_response bug 0.95 >"${WORK_DIR}/response.json"
LABELS_FIXTURE="${WORK_DIR}/single.json" run_step 200
assert_eq "a repository with one label sends a request" "yes" "$(exists request.json)"
assert_eq "a repository with one label gets its label" \
    '{"labels":["bug"]}' "$(jq -c . "${WORK_DIR}/posted.json")"

# An error body that is not JSON is logged as it is, an empty one as a
# placeholder.
printf '<html>Bad gateway</html>' >"${WORK_DIR}/response.json"
run_step 502
assert_eq "an error body that is not JSON is logged" \
    "1" "$(logged_line 'Anthropic API error for issue #7 (HTTP 502): <html>Bad gateway</html>')"
: >"${WORK_DIR}/response.json"
run_step 503
assert_eq "an empty error body is logged" \
    "1" "$(logged_line 'Anthropic API error for issue #7 (HTTP 503): (empty response body)')"

# A repository whose labels are all filtered out sends no request.
cat >"${WORK_DIR}/filtered.json" <<'JSON'
[
    {"name": "dependencies", "description": "Pull requests that update a dependency file"},
    {"name": "status: accepted", "description": "Set by maintainers after triage"}
]
JSON
LABELS_FIXTURE="${WORK_DIR}/filtered.json" run_step 200
assert_eq "a repository with no label to choose from sends no request" \
    "${BEFORE_REQUEST%% | build_ai_labeler_request*}" "$(trace)"
assert_eq "a repository with no label to choose from says so" \
    "1" "$(logged '::notice::owner/repo has no labels to choose from')"
assert_eq "a repository with no label to choose from exits cleanly" "0" "$(status)"

report_and_exit "AI issue-labeler step run tests"
