#!/usr/bin/env bash
# Sourced by ai-issue-labeler.yml's "Classify and label the issue" step and by
# .github/scripts/tests/test-ai-issue-labeler.sh, so the workflow and its test
# drive the same file rather than two copies that can drift apart.

# Builds the Anthropic Messages API request body for classifying one issue.
# `labels_json` is a JSON array of `{name, description}` objects (the calling
# repository's OWN label set, fetched live by the workflow) and must be
# non-empty - the caller guards that before sourcing this, so an empty
# `enum` here is not a case this function has to handle. The tool's
# `input_schema` constrains `labels` to an `enum` of exactly those names and
# is declared `strict: true`, so the API itself rejects any label the model
# might otherwise invent - this is the "tool call constrained to an enum"
# from GH-57, not a Structured Outputs `output_config.format`, because the
# constraint has to reach into an array's `items`, and Structured Outputs
# only became able to do that after the strict tool-use guarantee already
# covered it.
build_ai_labeler_request() {
    local repo="$1"
    local title="$2"
    local body="$3"
    local labels_json="$4"

    local label_names
    label_names=$(jq '[.[].name]' <<<"${labels_json}")
    local label_list
    label_list=$(jq -r '.[] | "- \(.name): \(.description)"' <<<"${labels_json}")

    jq -n \
        --arg repo "${repo}" \
        --arg title "${title}" \
        --arg body "${body}" \
        --arg label_list "${label_list}" \
        --argjson label_names "${label_names}" \
        '
        {
            model: "claude-haiku-4-5",
            max_tokens: 1024,
            system: ("You triage newly opened GitHub issues for the repository " + $repo + ". Choose the labels that apply to the issue below, using ONLY the labels listed here - never invent a new label:\n\n" + $label_list + "\n\nIf you are not confident any of these labels apply, return an empty labels array and set confident to false."),
            tools: [
                {
                    name: "assign_labels",
                    description: "Select the labels that apply to this issue, chosen only from the existing label set for this repository.",
                    strict: true,
                    input_schema: {
                        type: "object",
                        properties: {
                            labels: {
                                type: "array",
                                items: {type: "string", enum: $label_names},
                                description: "Existing label names that apply to this issue. Empty if none confidently apply."
                            },
                            confident: {
                                type: "boolean",
                                description: "True only if at least one selected label is a confident match."
                            }
                        },
                        required: ["labels", "confident"],
                        additionalProperties: false
                    }
                }
            ],
            tool_choice: {type: "tool", name: "assign_labels"},
            messages: [
                {
                    role: "user",
                    content: ("Issue title:\n" + $title + "\n\nIssue body:\n" + $body)
                }
            ]
        }
        '
}

# Prints the `assign_labels` tool call's `input` object from an Anthropic
# Messages API response, or returns 1 with no output when the response
# carries no such call (a non-`tool_use` stop reason, a refusal, an API
# error body, or - unreachable given `tool_choice` above, but a response
# shape this function does not trust its own request to have produced -
# a `tool_use` block for a different tool). The caller treats a 1 return as
# "leave the issue's labels untouched", never as a hard failure.
extract_tool_input() {
    local response_json="$1"

    local stop_reason
    stop_reason=$(jq -r '.stop_reason // empty' <<<"${response_json}")
    if [ "${stop_reason}" != "tool_use" ]; then
        return 1
    fi

    local tool_input
    tool_input=$(jq -c '[.content[]? | select(.type == "tool_use" and .name == "assign_labels")][0].input // empty' <<<"${response_json}")
    if [ -z "${tool_input}" ]; then
        return 1
    fi

    echo "${tool_input}"
}

# Decides which labels to apply, printed one per line (empty output means
# apply nothing). `tool_input_json` is the object `extract_tool_input`
# printed - `{labels: [...], confident: bool}`. Selected labels are
# re-filtered against `labels_json` (the same set the request was built
# from) rather than trusted as-is: the request-side `enum` is what stops the
# model from inventing a label, this filter is what stops a stale/renamed
# label surviving in the OUTPUT if `labels_json` was refreshed between
# building the request and resolving its response. When nothing survives
# confidently, GH-57 asks for a `needs-triage` fallback where the repository
# has one - never a guess.
#
# The two `|| return 1` below are load-bearing, not defensive noise: `set -e`
# does NOT propagate into a command substitution by default (and does not
# even with `shopt -s inherit_errexit` once the substitution sits inside a
# tested context like the caller's `x=$(resolve_labels_to_apply ...) ||
# warn_and_skip ...`), so without them a malformed argument here would
# silently continue with an empty `confident`/`selected` and this function
# would still return 0 - reported by the caller as "not confident" rather
# than "internal error". Re-derive: run either jq assignment against
# `--argjson known "not-json"` with and without the `||`, under `set -e`,
# called as `x=$(that_function ...) || echo caught` - only the guarded
# version reports `caught`.
resolve_labels_to_apply() {
    local tool_input_json="$1"
    local labels_json="$2"

    local confident
    confident=$(jq -r '.confident' <<<"${tool_input_json}") || return 1

    local selected
    selected=$(jq -r --argjson known "${labels_json}" '
        ($known | map(.name)) as $names
        | .labels[]
        | select(. as $label | $names | index($label) != null)
    ' <<<"${tool_input_json}") || return 1

    if [ "${confident}" = "true" ] && [ -n "${selected}" ]; then
        printf '%s\n' "${selected}"
        return 0
    fi

    if jq -e 'map(.name) | index("needs-triage") != null' <<<"${labels_json}" >/dev/null; then
        echo "needs-triage"
    fi

    return 0
}

# Builds the JSON body for `POST /repos/{owner}/{repo}/issues/{n}/labels`
# from a newline-separated label list (`resolve_labels_to_apply`'s output).
# Deliberately NOT `gh issue edit --add-label`: that flag is a pflag
# StringSlice, and its own `--help` example ("bug,help wanted") shows a
# comma splitting ONE flag value into two labels, regardless of how many
# times the flag is repeated - so a repository label whose own name
# contains a comma would silently split into the wrong labels. A JSON
# array has no such delimiter; a comma in a string is just a character.
build_labels_payload() {
    local labels="$1"
    jq -R . <<<"${labels}" | jq -s '{labels: .}'
}
