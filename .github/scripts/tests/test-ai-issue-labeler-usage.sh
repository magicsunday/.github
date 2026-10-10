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

ALL_UNKNOWN='stop_reason=unknown input_tokens=unknown output_tokens=unknown thinking_tokens=unknown'

# Prints a response body with the stop reason and the token counts, each given
# as JSON, in the places the API puts them.
response_body() {
    printf '{"stop_reason":%s,"usage":{"input_tokens":%s,"output_tokens":%s,"output_tokens_details":{"thinking_tokens":%s}}}' "$1" "$2" "$3" "$4"
}

# One log line with the stop reason and the token counts of a response, so a
# run shows how much of the output budget the model used.
assert_eq "describe_api_usage: prints the stop reason and the token counts" \
    'stop_reason=tool_use input_tokens=1586 output_tokens=72 thinking_tokens=0' \
    "$(describe_api_usage "$(response_body '"tool_use"' 1586 72 0)")"
assert_eq "describe_api_usage: shows a response that ran out of output budget" \
    'stop_reason=max_tokens input_tokens=1500 output_tokens=1024 thinking_tokens=1024' \
    "$(describe_api_usage "$(response_body '"max_tokens"' 1500 1024 1024)")"

# A missing field is reported as unknown instead of being left out, so the
# line keeps one shape for every response.
assert_eq "describe_api_usage: reports a missing count as unknown" \
    'stop_reason=tool_use input_tokens=10 output_tokens=5 thinking_tokens=unknown' \
    "$(describe_api_usage '{"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5}}')"

for body in '<html>Bad gateway</html>' '' '[]' '"text"' '{"usage":null}'; do
    assert_eq "describe_api_usage: reports a body without usage as unknown (${body:-empty})" \
        "${ALL_UNKNOWN}" "$(describe_api_usage "${body}")"
done

# The values come from the network, so only a plain count and a plain stop
# reason are printed. Anything else is reported as unknown, which keeps a
# crafted value from putting text or a second line into the log.
assert_eq "describe_api_usage: prints only plain values" \
    "${ALL_UNKNOWN}" \
    "$(describe_api_usage "$(response_body '"tool_use\n::error::x"' '"7 ##[x]"' -3 1.5)")"

# A single trailing line break must not pass for a word, and a word must be
# lowercase letters and underscores only.
for stop_reason in '"tool_use\n"' '"Tool_use"' '"tool use"' '"tool_use2"' '"tool{use"' '"tool`use"' '"tool-use"' '"tool^use"' '""' 5; do
    assert_eq "describe_api_usage: rejects the stop reason ${stop_reason}" \
        'stop_reason=unknown input_tokens=1 output_tokens=2 thinking_tokens=3' \
        "$(describe_api_usage "$(response_body "${stop_reason}" 1 2 3)")"
done

# Pins the limits of the stop reason: both ends of the letter class, the
# underscore, the longest accepted word and the shortest word that is too long.
assert_eq "describe_api_usage: prints a stop reason with the last letter and the underscore" \
    'stop_reason=z_z input_tokens=1 output_tokens=2 thinking_tokens=3' \
    "$(describe_api_usage "$(response_body '"z_z"' 1 2 3)")"
assert_eq "describe_api_usage: prints the shortest accepted stop reason" \
    'stop_reason=a input_tokens=1 output_tokens=2 thinking_tokens=3' \
    "$(describe_api_usage "$(response_body '"a"' 1 2 3)")"
accepted=$(printf 'a%.0s' $(seq 1 32))
rejected=$(printf 'a%.0s' $(seq 1 33))
assert_eq "describe_api_usage: prints the longest accepted stop reason" \
    "stop_reason=${accepted} input_tokens=1 output_tokens=2 thinking_tokens=3" \
    "$(describe_api_usage "$(response_body "\"${accepted}\"" 1 2 3)")"
assert_eq "describe_api_usage: rejects a stop reason one character too long" \
    'stop_reason=unknown input_tokens=1 output_tokens=2 thinking_tokens=3' \
    "$(describe_api_usage "$(response_body "\"${rejected}\"" 1 2 3)")"

# A count must be a plain run of digits, not an exponent, a fraction, a sign,
# a string or a run that is too long.
for count in 1e300 1.0 -0 -3 100000000000000000000 1000000000000000 '"7"' '"7 ##[x]"'; do
    assert_eq "describe_api_usage: rejects the count ${count}" \
        'stop_reason=tool_use input_tokens=unknown output_tokens=2 thinking_tokens=3' \
        "$(describe_api_usage "$(response_body '"tool_use"' "${count}" 2 3)")"
done
assert_eq "describe_api_usage: prints the longest accepted count" \
    'stop_reason=tool_use input_tokens=999999999999999 output_tokens=2 thinking_tokens=3' \
    "$(describe_api_usage "$(response_body '"tool_use"' 999999999999999 2 3)")"

# Each count is checked on its own, so a bad one does not hide behind the others.
assert_eq "describe_api_usage: rejects a negative output count on its own" \
    'stop_reason=tool_use input_tokens=1 output_tokens=unknown thinking_tokens=3' \
    "$(describe_api_usage "$(response_body '"tool_use"' 1 -2 3)")"
assert_eq "describe_api_usage: rejects a fractional thinking count on its own" \
    'stop_reason=tool_use input_tokens=1 output_tokens=2 thinking_tokens=unknown' \
    "$(describe_api_usage "$(response_body '"tool_use"' 1 2 1.5)")"

# The step runs with errexit and pipefail, so a body that is not JSON must not
# abort it, and the parse error of jq must not reach the log through stderr.
# The call sits in a script of its own, because errexit is ignored inside a
# command that stands left of `||`.
output=$(bash -c 'set -euo pipefail; source "$1"; describe_api_usage "$2"; echo finished' _ "${SCRIPT_DIR}/../lib/ai-issue-labeler.sh" '<html>text from the network</html>' 2>&1)
assert_eq "describe_api_usage: survives errexit and keeps the parse error out of the output" \
    "${ALL_UNKNOWN}"$'\nfinished' "${output}"

# A body that holds several JSON values yields one line, the one of the first value.
several=$(describe_api_usage "$(response_body '"tool_use"' 1 2 3) $(response_body '"end_turn"' 4 5 6)")
assert_eq "describe_api_usage: prints the first value of a body with several JSON values" \
    'stop_reason=tool_use input_tokens=1 output_tokens=2 thinking_tokens=3' "${several}"

report_and_exit "AI issue-labeler usage tests"
