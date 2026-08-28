#!/usr/bin/env bash
# Exercises the request-building and response-parsing functions
# (.github/scripts/lib/ai-issue-labeler.sh) that ai-issue-labeler.yml sources
# to classify a newly opened issue. Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ai-issue-labeler.sh
source "${SCRIPT_DIR}/../lib/ai-issue-labeler.sh"

failures=0

pass() {
    echo "PASS: $1"
}

fail() {
    echo "FAIL: $1"
    failures=$((failures + 1))
}

LABELS_JSON='[{"name":"bug","description":"Something is broken"},{"name":"enhancement","description":"New feature or request"},{"name":"needs-triage","description":"Not yet classified"}]'
LABELS_JSON_NO_TRIAGE='[{"name":"bug","description":"Something is broken"},{"name":"enhancement","description":"New feature or request"}]'

# --- build_ai_labeler_request ---

request=$(build_ai_labeler_request "magicsunday/example" "Crash on startup" "It throws a TypeError." "${LABELS_JSON}")

if [ "$(jq -r '.model' <<<"${request}")" = "claude-haiku-4-5" ]; then
    pass "build_ai_labeler_request: uses claude-haiku-4-5"
else
    fail "build_ai_labeler_request: expected model claude-haiku-4-5, got $(jq -r '.model' <<<"${request}")"
fi

if [ "$(jq -r '.tool_choice.name' <<<"${request}")" = "assign_labels" ]; then
    pass "build_ai_labeler_request: forces the assign_labels tool"
else
    fail "build_ai_labeler_request: tool_choice did not force assign_labels"
fi

if [ "$(jq -r '.tools[0].strict' <<<"${request}")" = "true" ]; then
    pass "build_ai_labeler_request: tool is strict"
else
    fail "build_ai_labeler_request: tool was not declared strict"
fi

enum_names=$(jq -c '.tools[0].input_schema.properties.labels.items.enum | sort' <<<"${request}")
if [ "${enum_names}" = '["bug","enhancement","needs-triage"]' ]; then
    pass "build_ai_labeler_request: enum matches the repository's own label set"
else
    fail "build_ai_labeler_request: enum was ${enum_names}, expected the three known labels"
fi

if jq -e '.system | contains("magicsunday/example")' <<<"${request}" >/dev/null; then
    pass "build_ai_labeler_request: system prompt names the repository"
else
    fail "build_ai_labeler_request: system prompt did not name the repository"
fi

if jq -e '.messages[0].content | contains("Crash on startup") and contains("It throws a TypeError.")' <<<"${request}" >/dev/null; then
    pass "build_ai_labeler_request: user message carries the issue title and body"
else
    fail "build_ai_labeler_request: user message missing the issue title or body"
fi

# --- extract_tool_input ---

response_tool_use=$(jq -n '{
    stop_reason: "tool_use",
    content: [
        {type: "text", text: "Let me check."},
        {type: "tool_use", id: "toolu_1", name: "assign_labels", input: {labels: ["bug"], confident: true}}
    ]
}')

if input=$(extract_tool_input "${response_tool_use}"); then
    if [ "$(jq -r '.confident' <<<"${input}")" = "true" ]; then
        pass "extract_tool_input: reads the assign_labels input from a tool_use response"
    else
        fail "extract_tool_input: extracted input did not carry the expected confident flag"
    fi
else
    fail "extract_tool_input: did not extract a tool_use response it should have accepted"
fi

response_end_turn=$(jq -n '{stop_reason: "end_turn", content: [{type: "text", text: "no tool call"}]}')
if extract_tool_input "${response_end_turn}" >/dev/null 2>&1; then
    fail "extract_tool_input: accepted a response with no tool call"
else
    pass "extract_tool_input: rejects a non-tool_use stop reason"
fi

response_other_tool=$(jq -n '{
    stop_reason: "tool_use",
    content: [{type: "tool_use", id: "toolu_2", name: "some_other_tool", input: {}}]
}')
if extract_tool_input "${response_other_tool}" >/dev/null 2>&1; then
    fail "extract_tool_input: accepted a tool_use block for a different tool"
else
    pass "extract_tool_input: rejects a tool_use block that is not assign_labels"
fi

# --- resolve_labels_to_apply ---

confident_known=$(jq -n '{labels: ["bug", "enhancement"], confident: true}')
result=$(resolve_labels_to_apply "${confident_known}" "${LABELS_JSON}")
if [ "$(printf '%s\n' "${result}" | sort | tr '\n' ',')" = "bug,enhancement," ]; then
    pass "resolve_labels_to_apply: applies a confident selection of known labels"
else
    fail "resolve_labels_to_apply: expected bug,enhancement - got ${result}"
fi

confident_with_unknown=$(jq -n '{labels: ["bug", "invented-label"], confident: true}')
result=$(resolve_labels_to_apply "${confident_with_unknown}" "${LABELS_JSON}")
if [ "${result}" = "bug" ]; then
    pass "resolve_labels_to_apply: filters out a label absent from the known set"
else
    fail "resolve_labels_to_apply: expected only bug - got ${result}"
fi

not_confident=$(jq -n '{labels: [], confident: false}')
result=$(resolve_labels_to_apply "${not_confident}" "${LABELS_JSON}")
if [ "${result}" = "needs-triage" ]; then
    pass "resolve_labels_to_apply: falls back to needs-triage when not confident"
else
    fail "resolve_labels_to_apply: expected needs-triage fallback - got '${result}'"
fi

not_confident_no_fallback=$(jq -n '{labels: [], confident: false}')
result=$(resolve_labels_to_apply "${not_confident_no_fallback}" "${LABELS_JSON_NO_TRIAGE}")
if [ -z "${result}" ]; then
    pass "resolve_labels_to_apply: applies nothing when not confident and no needs-triage exists"
else
    fail "resolve_labels_to_apply: expected no output - got '${result}'"
fi

confident_but_empty=$(jq -n '{labels: [], confident: true}')
result=$(resolve_labels_to_apply "${confident_but_empty}" "${LABELS_JSON}")
if [ "${result}" = "needs-triage" ]; then
    pass "resolve_labels_to_apply: confident with an empty selection still falls back"
else
    fail "resolve_labels_to_apply: expected needs-triage fallback - got '${result}'"
fi

# A malformed argument must make the function itself return non-zero -
# the caller relies on this (`x=$(resolve_labels_to_apply ...) ||
# warn_and_skip ...`) to distinguish "internal error" from "legitimately
# not confident", and `set -e` alone does not surface an internal jq
# failure through a command substitution sitting inside a tested context
# (see the function's own comment for the re-derive command this pins).
valid_tool_input=$(jq -n '{labels: ["bug"], confident: true}')
if resolve_labels_to_apply "${valid_tool_input}" "not-json" >/dev/null 2>&1; then
    fail "resolve_labels_to_apply: returned success despite malformed labels_json"
else
    pass "resolve_labels_to_apply: returns non-zero when labels_json is malformed"
fi

# --- build_labels_payload ---

payload=$(build_labels_payload "$(printf '%s\n' "bug" "needs-triage")")
expected=$(jq -n '{labels: ["bug", "needs-triage"]}')
if [ "$(jq -c -S . <<<"${payload}")" = "$(jq -c -S . <<<"${expected}")" ]; then
    pass "build_labels_payload: builds a JSON array from a newline-separated list"
else
    fail "build_labels_payload: expected ${expected} - got ${payload}"
fi

# A label name containing a comma must survive as ONE atomic array entry -
# gh issue edit --add-label would instead split it into two labels (its
# own --help example shows "bug,help wanted" -> two labels), which is
# exactly why the REST payload is built here instead.
payload=$(build_labels_payload "$(printf '%s\n' "docs,api")")
if [ "$(jq -c '.labels' <<<"${payload}")" = '["docs,api"]' ]; then
    pass "build_labels_payload: keeps a comma-containing label name atomic"
else
    fail "build_labels_payload: comma-containing label was split - got $(jq -c '.labels' <<<"${payload}")"
fi

if [ "${failures}" -gt 0 ]; then
    echo "${failures} failure(s)."
    exit 1
fi

echo "All AI issue-labeler tests passed."
