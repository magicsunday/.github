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

    # `|| return 1` on both: same reasoning as resolve_labels_to_apply's
    # own comment below in this file - an internal jq failure that is not
    # this function's OWN last command would otherwise return 0 silently
    # (verified: a broken `label_list` alone does not fail the trailing
    # `jq -n` call, because it is interpolated via `--arg`, which accepts
    # an empty string as valid input - only a broken `label_names` happens
    # to be caught today, by `--argjson` rejecting empty input, and only
    # because it is reached last).
    local label_names
    label_names=$(jq '[.[].name]' <<<"${labels_json}") || return 1
    local label_list
    label_list=$(jq -r '.[] | "- \(.name): \(.description)"' <<<"${labels_json}") || return 1

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

# Prints `labels_json` (the `{name, description}` array the request builder
# takes) without the labels that describe themselves as pull-request labels.
# Only a description that OPENS with "Pull requests that" counts, matched
# without regard to case, so a label that merely mentions pull requests stays
# selectable. The caller feeds the result to the request builder and to
# `resolve_labels_to_apply` alike, so the model's choices and the guard's known
# set stay the same.
drop_pull_request_only_labels() {
    local labels_json="$1"

    jq -c '[.[] | select(.description | ascii_downcase | startswith("pull requests that") | not)]' <<<"${labels_json}"
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

# Prints its argument with every `##[` broken up into `## [`. The runner
# recognises its older bracket workflow command syntax anywhere inside a log
# line, so the model answer and the label names that the step logs go through
# this first.
neutralize_command_markers() {
    local text="$1"

    printf '%s\n' "${text//##\[/## [}"
}

# jq definition shared by the exclusive-kind guard and the needs-triage
# fallback in `resolve_labels_to_apply`, so a label counts as a type or a
# priority label in one place only. `kind` is "priority" for a `priority:`
# label, "type" for bug, enhancement or documentation, and null for anything
# else, matched without regard to case. Single-quoted on purpose, the `$` in
# the program belongs to jq and must not expand in the shell. A plain
# assignment rather than `readonly`, so the library can still be sourced twice
# in one shell.
# shellcheck disable=SC2016
AI_LABELER_KIND_JQ_DEF='def kind:
    ascii_downcase as $lowered
    | if ($lowered | startswith("priority:")) then "priority"
    elif ($lowered == "bug" or $lowered == "enhancement" or $lowered == "documentation") then "type"
    else null end;'

# Decides which labels to apply, printed one per line (empty output means
# apply nothing). `tool_input_json` is the object `extract_tool_input`
# printed - `{labels: [...], confident: bool}`. Selected labels are
# re-filtered against `labels_json` (the same set the request was built
# from) rather than trusted as-is: the request-side `enum` is what stops the
# model from inventing a label, this filter is what stops a stale/renamed
# label surviving in the OUTPUT if `labels_json` was refreshed between
# building the request and resolving its response. When nothing survives
# confidently, GH-57 asks for a `needs-triage` fallback where the repository
# has one - never a guess - unless the issue already carries a type or a
# priority label, which means it has been triaged.
#
# The `|| return 1` guards below are load-bearing, not defensive noise: `set -e`
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
#
# Type and priority are read as single values, so the selection is held to
# one label per exclusive kind (GH-146): a `priority:` label, and one of the
# type labels bug/enhancement/documentation, matched without regard to case.
# `existing_labels_json` is a JSON array of the label names the issue already
# carries. A kind the issue has is left alone, and a kind the model answered
# with two labels is dropped entirely rather than guessed. Labels outside
# both kinds pass through, except that a `needs-triage` the model selected
# itself is dropped for an issue that already carries a type or a priority
# label, just like the fallback, and also when its own selection applies one.
# A selection the guard empties applies nothing: the `needs-triage` fallback
# below is for an answer with no confident known label, not for an issue that
# already carries a type or a priority label.
resolve_labels_to_apply() {
    local tool_input_json="$1"
    local labels_json="$2"
    local existing_labels_json="${3:-[]}"

    local confident
    confident=$(jq -r '.confident' <<<"${tool_input_json}") || return 1

    local selected
    selected=$(jq -r --argjson known "${labels_json}" '
        ($known | map(.name)) as $names
        | .labels[]
        | select(. as $label | $names | index($label) != null)
    ' <<<"${tool_input_json}") || return 1

    # An issue that already carries a type or a priority label has been
    # triaged, so neither the fallback nor a needs-triage the model selected
    # itself would be anything but removed by hand again.
    local existing_triaged
    existing_triaged=$(jq -r --argjson existing "${existing_labels_json}" -n "${AI_LABELER_KIND_JQ_DEF}"'
        $existing | map(kind) | any(. != null)
    ') || return 1

    if [ "${confident}" = "true" ] && [ -n "${selected}" ]; then
        local allowed
        allowed=$(jq -Rr --argjson existing "${existing_labels_json}" --argjson existing_triaged "${existing_triaged}" "${AI_LABELER_KIND_JQ_DEF}"'
            ($existing | map(kind)) as $taken
            | [., inputs] | unique as $names
            | ($names | map(select(kind != null) | kind) | group_by(.) | map(select(length > 1) | .[0])) as $conflicting
            | [$names[] | select(kind as $kind | $kind == null or (($taken | index($kind)) == null and ($conflicting | index($kind)) == null))] as $kept
            | ($existing_triaged or ($kept | any(kind != null))) as $triaged
            | $kept[]
            | select(($triaged | not) or . != "needs-triage")
        ' <<<"${selected}") || return 1

        if [ -n "${allowed}" ]; then
            printf '%s\n' "${allowed}"
        fi
        return 0
    fi

    if [ "${existing_triaged}" = "true" ]; then
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
