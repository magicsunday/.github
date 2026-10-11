#!/usr/bin/env bash
# Runs the AI issue labeler pipeline for one issue, the way the workflow step
# does it, and prints one JSON line. labeler_eval.py calls it.
#
#   run-one.sh offered  LABELS_FILE
#       prints the names the labeler is offered after its two label filters
#   run-one.sh classify REPO TITLE_FILE BODY_FILE LABELS_FILE
#       prints {"status":"ok","labels":[...],"usage":"..."}, or a status of
#       "error" with the HTTP status, or "no_tool_call" with the usage line
#
# LABELS_FILE holds the {name, description} array of the repository labels.
# classify needs ANTHROPIC_API_KEY in the environment. The issue starts with no
# labels of its own, so the type and priority guard has nothing to leave alone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ai-issue-labeler.sh
source "${SCRIPT_DIR}/../lib/ai-issue-labeler.sh"

filtered_labels() {
    local labels_json
    labels_json=$(cat "$1")
    labels_json=$(drop_pull_request_only_labels "$labels_json")
    drop_maintainer_set_labels "$labels_json"
}

mode="${1:?mode}"
case "${mode}" in
    offered)
        filtered_labels "${2:?labels file}" | jq -c '[.[].name]'
        ;;
    classify)
        repo="${2:?repo}"
        title=$(cat "${3:?title file}")
        body=$(cat "${4:?body file}")
        labels_json=$(filtered_labels "${5:?labels file}")

        request_body=$(build_ai_labeler_request "${repo}" "${title}" "${body}" "${labels_json}")
        http_response=$(curl -sS --connect-timeout 10 --max-time 60 -w '\n%{http_code}' \
            https://api.anthropic.com/v1/messages \
            -H "Content-Type: application/json" \
            -H "x-api-key: ${ANTHROPIC_API_KEY}" \
            -H "anthropic-version: 2023-06-01" \
            --data-binary @- <<<"${request_body}") \
            || { jq -cn '{status: "error", http: 0}'; exit 0; }
        http_status=$(tail -n1 <<<"${http_response}")
        response_body=$(sed '$d' <<<"${http_response}")

        if [ "${http_status}" != "200" ]; then
            jq -cn --argjson http "${http_status}" '{status: "error", http: $http}'
            exit 0
        fi

        usage=$(describe_api_usage "${response_body}")
        if ! tool_input=$(extract_tool_input "${response_body}"); then
            jq -cn --arg usage "${usage}" '{status: "no_tool_call", usage: $usage}'
            exit 0
        fi

        tool_input=$(apply_label_confidence "${tool_input}" 2>/dev/null) \
            || { jq -cn --arg usage "${usage}" '{status: "unreadable_answer", usage: $usage}'; exit 0; }
        selected=$(resolve_labels_to_apply "${tool_input}" "${labels_json}" "[]") \
            || { jq -cn --arg usage "${usage}" '{status: "guard_failed", usage: $usage}'; exit 0; }

        if [ -n "${selected}" ]; then
            labels=$(jq -R . <<<"${selected}" | jq -cs .)
        else
            labels='[]'
        fi
        jq -cn --argjson labels "${labels}" --arg usage "${usage}" \
            '{status: "ok", labels: $labels, usage: $usage}'
        ;;
    *)
        echo "unknown mode: ${mode}" >&2
        exit 2
        ;;
esac
