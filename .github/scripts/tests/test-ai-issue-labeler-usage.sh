#!/usr/bin/env bash
# Exercises describe_api_usage (.github/scripts/lib/ai-issue-labeler.sh), the
# function ai-issue-labeler.yml calls to log the stop reason and the token
# counts of an API response. Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"
# shellcheck source=../lib/ai-issue-labeler.sh
source "${SCRIPT_DIR}/../lib/ai-issue-labeler.sh"

pass() {
    echo "PASS: $1"
}

fail() {
    echo "FAIL: $1"
    failures=$((failures + 1))
}

# One log line with the stop reason and the token counts of a response, so a
# run shows how much of the output budget the model used.

body='{"stop_reason":"tool_use","usage":{"input_tokens":1586,"output_tokens":72,"output_tokens_details":{"thinking_tokens":0}},"content":[]}'
expected='stop_reason=tool_use input_tokens=1586 output_tokens=72 thinking_tokens=0'
if [ "$(describe_api_usage "${body}")" = "${expected}" ]; then
    pass "describe_api_usage: prints the stop reason and the token counts"
else
    fail "describe_api_usage: got $(describe_api_usage "${body}")"
fi

body='{"stop_reason":"max_tokens","usage":{"input_tokens":1500,"output_tokens":1024,"output_tokens_details":{"thinking_tokens":1024}}}'
expected='stop_reason=max_tokens input_tokens=1500 output_tokens=1024 thinking_tokens=1024'
if [ "$(describe_api_usage "${body}")" = "${expected}" ]; then
    pass "describe_api_usage: shows a response that ran out of output budget"
else
    fail "describe_api_usage: got $(describe_api_usage "${body}")"
fi

# A missing field is reported as unknown instead of being left out, so the
# line keeps one shape for every response.
body='{"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5}}'
expected='stop_reason=tool_use input_tokens=10 output_tokens=5 thinking_tokens=unknown'
if [ "$(describe_api_usage "${body}")" = "${expected}" ]; then
    pass "describe_api_usage: reports a missing count as unknown"
else
    fail "describe_api_usage: got $(describe_api_usage "${body}")"
fi

expected='stop_reason=unknown input_tokens=unknown output_tokens=unknown thinking_tokens=unknown'
for body in '<html>Bad gateway</html>' '' '[]' '"text"' '{"usage":null}'; do
    if [ "$(describe_api_usage "${body}")" = "${expected}" ]; then
        pass "describe_api_usage: reports a body without usage as unknown (${body:-empty})"
    else
        fail "describe_api_usage: got $(describe_api_usage "${body}") for ${body:-empty}"
    fi
done

# The values come from the network, so only a plain count and a plain stop
# reason are printed. Anything else is reported as unknown, which keeps a
# crafted value from putting text or a second line into the log.
body=$(jq -cn '{stop_reason: "tool_use\n::error::x", usage: {input_tokens: "7 ##[x]", output_tokens: -3, output_tokens_details: {thinking_tokens: 1.5}}}')
if [ "$(describe_api_usage "${body}")" = "${expected}" ]; then
    pass "describe_api_usage: prints only plain values"
else
    fail "describe_api_usage: got $(describe_api_usage "${body}")"
fi

# A single trailing line break must not pass for a word, and a count must be a
# plain run of digits, not an exponent, a fraction or a sign.
expected='stop_reason=unknown input_tokens=1 output_tokens=1 thinking_tokens=1'
for stop_reason in '"tool_use\n"' '"Tool_use"' '"tool use"' '"tool_use2"' '""'; do
    body=$(jq -cn --argjson reason "${stop_reason}" '{stop_reason: $reason, usage: {input_tokens: 1, output_tokens: 1, output_tokens_details: {thinking_tokens: 1}}}')
    if [ "$(describe_api_usage "${body}")" = "${expected}" ]; then
        pass "describe_api_usage: rejects the stop reason ${stop_reason}"
    else
        fail "describe_api_usage: got $(describe_api_usage "${body}") for ${stop_reason}"
    fi
done

# Pins the limit of the stop reason with the longest accepted word and the
# shortest rejected one.
accepted=$(printf 'a%.0s' $(seq 1 32))
rejected=$(printf 'a%.0s' $(seq 1 33))
body=$(jq -cn --arg reason "${accepted}" '{stop_reason: $reason, usage: {input_tokens: 1, output_tokens: 1, output_tokens_details: {thinking_tokens: 1}}}')
if [ "$(describe_api_usage "${body}")" = "stop_reason=${accepted} input_tokens=1 output_tokens=1 thinking_tokens=1" ]; then
    pass "describe_api_usage: prints the longest accepted stop reason"
else
    fail "describe_api_usage: got $(describe_api_usage "${body}") for the longest accepted stop reason"
fi
body=$(jq -cn --arg reason "${rejected}" '{stop_reason: $reason, usage: {input_tokens: 1, output_tokens: 1, output_tokens_details: {thinking_tokens: 1}}}')
if [ "$(describe_api_usage "${body}")" = "${expected}" ]; then
    pass "describe_api_usage: rejects a stop reason one character too long"
else
    fail "describe_api_usage: got $(describe_api_usage "${body}") for a stop reason one character too long"
fi

for count in 1e300 1.0 -0 -3 100000000000000000000 1000000000000000 999999999999999; do
    body=$(printf '{"stop_reason":"tool_use","usage":{"input_tokens":%s,"output_tokens":2,"output_tokens_details":{"thinking_tokens":3}}}' "${count}")
    case "${count}" in
        999999999999999) want='input_tokens=999999999999999' ;;
        *) want='input_tokens=unknown' ;;
    esac
    if [ "$(describe_api_usage "${body}")" = "stop_reason=tool_use ${want} output_tokens=2 thinking_tokens=3" ]; then
        pass "describe_api_usage: handles the count ${count}"
    else
        fail "describe_api_usage: got $(describe_api_usage "${body}") for the count ${count}"
    fi
done

# One bad field at a time with the others valid, so that each guard is pinned
# by itself and not hidden behind the fallback for the whole body.
while IFS='|' read -r label body_template want; do
    body=$(printf "${body_template}")
    if [ "$(describe_api_usage "${body}")" = "${want}" ]; then
        pass "describe_api_usage: ${label}"
    else
        fail "describe_api_usage: got $(describe_api_usage "${body}") for ${label}"
    fi
done <<'CASES'
a stop reason that is not a string|{"stop_reason":5,"usage":{"input_tokens":1,"output_tokens":2,"output_tokens_details":{"thinking_tokens":3}}}|stop_reason=unknown input_tokens=1 output_tokens=2 thinking_tokens=3
a count given as a string of digits|{"stop_reason":"tool_use","usage":{"input_tokens":"7","output_tokens":2,"output_tokens_details":{"thinking_tokens":3}}}|stop_reason=tool_use input_tokens=unknown output_tokens=2 thinking_tokens=3
a count given as text with a marker|{"stop_reason":"tool_use","usage":{"input_tokens":"7 ##[x]","output_tokens":2,"output_tokens_details":{"thinking_tokens":3}}}|stop_reason=tool_use input_tokens=unknown output_tokens=2 thinking_tokens=3
a negative output count|{"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":-2,"output_tokens_details":{"thinking_tokens":3}}}|stop_reason=tool_use input_tokens=1 output_tokens=unknown thinking_tokens=3
a fractional thinking count|{"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":2,"output_tokens_details":{"thinking_tokens":1.5}}}|stop_reason=tool_use input_tokens=1 output_tokens=2 thinking_tokens=unknown
CASES

# The step runs with errexit and pipefail, so a body that is not JSON must not
# abort it, and the parse error of jq must not reach the log through stderr.
expected='stop_reason=unknown input_tokens=unknown output_tokens=unknown thinking_tokens=unknown'
# The call sits in a script of its own, because errexit is ignored inside a
# command that stands left of `||`.
output=$(bash -c 'set -euo pipefail; source "$1"; describe_api_usage "$2"; echo finished' _ "${SCRIPT_DIR}/../lib/ai-issue-labeler.sh" '<html>text from the network</html>' 2>&1)
if [ "${output}" = "${expected}"$'\nfinished' ]; then
    pass "describe_api_usage: survives errexit and keeps the parse error out of the output"
else
    fail "describe_api_usage: got ${output} under errexit"
fi

# A body that holds several JSON values still yields one line.
body='{"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":2,"output_tokens_details":{"thinking_tokens":3}}} {"stop_reason":"end_turn"}'
if [ "$(describe_api_usage "${body}" | wc -l)" = "1" ]; then
    pass "describe_api_usage: prints one line for a body with several JSON values"
else
    fail "describe_api_usage: printed more than one line for a body with several JSON values"
fi

report_and_exit "AI issue-labeler usage tests"
