#!/usr/bin/env bash
# Exercises .github/scripts/eval/run-one.sh with a stub for curl: the label
# names it offers and the one line it prints for each way a call can end. No
# test here reaches the network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

RUN_ONE="${SCRIPT_DIR}/../eval/run-one.sh"
require_files_or_bail "labeler eval run-one test" "${RUN_ONE}"

WORK_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "${WORK_DIR}"' EXIT
mkdir -p "${WORK_DIR}/bin"

cat >"${WORK_DIR}/bin/curl" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
[ -z "${CURL_FAILS:-}" ] || exit 7
cat "${RESPONSE_FILE}"
printf '\n%s' "${RESPONSE_STATUS}"
STUB
chmod +x "${WORK_DIR}/bin/curl"

cat >"${WORK_DIR}/labels.json" <<'JSON'
[
    {"name": "bug", "description": "Something is broken"},
    {"name": "needs-triage", "description": "Not yet classified"},
    {"name": "i18n", "description": ""},
    {"name": "dependencies", "description": "Pull requests that update a dependency file"},
    {"name": "status: accepted", "description": "Set by maintainers after triage"}
]
JSON
printf 'A title' >"${WORK_DIR}/title"
printf 'A body' >"${WORK_DIR}/body"

# Runs classify with the HTTP status "$1" and the response in ${WORK_DIR}/response.
classify() {
    env PATH="${WORK_DIR}/bin:${PATH}" ANTHROPIC_API_KEY=key-test \
        RESPONSE_FILE="${WORK_DIR}/response" RESPONSE_STATUS="$1" CURL_FAILS="${CURL_FAILS:-}" \
        bash "${RUN_ONE}" classify o/r "${WORK_DIR}/title" "${WORK_DIR}/body" "${WORK_DIR}/labels.json"
}

# Prints a model response with one assign_labels call that grades the label
# "$1" with the confidence "$2".
tool_response() {
    printf '{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"assign_labels","input":{"labels":[{"label":"%s","confidence":%s}]}}],"usage":{"input_tokens":10,"output_tokens":5}}' "$1" "$2"
}

assert_eq "offered drops the pull request label and the maintainer label" \
    '["bug","needs-triage","i18n"]' "$(bash "${RUN_ONE}" offered "${WORK_DIR}/labels.json")"

tool_response bug 0.95 >"${WORK_DIR}/response"
assert_eq "a confident answer gives its label and the usage" \
    '{"status":"ok","labels":["bug"],"usage":"stop_reason=tool_use input_tokens=10 output_tokens=5 thinking_tokens=unknown"}' \
    "$(classify 200)"

tool_response bug 0.1 >"${WORK_DIR}/response"
assert_eq "a label below its floor gives the fallback label" \
    '["needs-triage"]' "$(classify 200 | jq -c .labels)"

tool_response i18n 0.95 >"${WORK_DIR}/response"
assert_eq "a topic label is passed on" '["i18n"]' "$(classify 200 | jq -c .labels)"

printf '{"type":"error","error":{"type":"api_error","message":"overloaded"}}' >"${WORK_DIR}/response"
assert_eq "a failing status is reported with its code" '{"status":"error","http":529}' "$(classify 529)"

printf '{"stop_reason":"max_tokens","content":[],"usage":{"input_tokens":10,"output_tokens":1024}}' >"${WORK_DIR}/response"
assert_eq "an answer without a tool call is reported with the usage" \
    '{"status":"no_tool_call","usage":"stop_reason=max_tokens input_tokens=10 output_tokens=1024 thinking_tokens=unknown"}' \
    "$(classify 200)"

printf '{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"assign_labels","input":{"labels":5}}],"usage":{"input_tokens":1,"output_tokens":1}}' >"${WORK_DIR}/response"
assert_eq "an unreadable answer is reported" "unreadable_answer" "$(classify 200 | jq -r .status)"

assert_eq "a failing curl is reported as an error without a status" \
    '{"status":"error","http":0}' "$(CURL_FAILS=1 classify 200)"

assert_eq "an unknown mode fails with status 2" "2" "$(bash "${RUN_ONE}" nonsense >/dev/null 2>&1; echo $?)"

report_and_exit "labeler eval run-one tests"
