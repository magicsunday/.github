#!/usr/bin/env bash
# Sourced by lint.yml's "readme-catalog-fresh" job and by
# .github/scripts/tests/test-readme-catalog-check.sh, so the workflow and its
# test drive the same file rather than two copies that can drift apart
# (issue #101).

# shellcheck source=annotation-sanitize.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/annotation-sanitize.sh"

# Prints, one per line, the basename of every *.yml/*.yaml file under
# workflows_dir ($1) whose top-level `on:` block declares a real
# workflow_call trigger - scoped to the block from the bare `on:` line
# through the next column-0 line (the same sed-range-then-grep technique
# assert_readme_catalog_complete() below uses to scope its own table
# extraction), since `workflow_call` is also a legal JOB id: a job section
# named `workflow_call:` at the same 4-space depth as a real trigger key
# previously false-positived under a plain whole-file grep (CodeRabbit,
# GH-101 PR #117) - scoping the search to the `on:` block excludes a
# `jobs:` section entirely, since the range ends at (and does not extend
# past) the first line that starts back at column 0. sed's output is
# captured into a variable and grepped via a here-string rather than piped
# directly into `grep -q` - under this caller's `set -o pipefail` (lint.yml)
# a short-circuiting `grep -q` can SIGPIPE a still-writing sed on a large
# enough `on:` block, and pipefail would then surface that as the whole
# pipeline failing, silently skipping a real match (shell-script-reviewer,
# GH-101 round 9). Routed through sanitize_for_annotation()
# (annotation-sanitize.sh) before printing - a git-tracked filename could
# otherwise carry either forgery channel that function's own header dates
# and explains - which also keeps this function's one-name-per-line output
# contract intact for its own caller below, which reads it back with
# `read`: a raw embedded newline would otherwise split one name across two
# lines.
#
# Known limitation (issue #101): only the block form (`on:` followed by an
# indented `workflow_call:` key) is detected. GitHub Actions also accepts a
# scalar or flow-sequence trigger shorthand (`on: workflow_call` / `on:
# [push, workflow_call]`) - a file using either is silently invisible to
# this function (nothing prints, so assert_readme_catalog_complete() below
# never flags it missing either), the OPPOSITE of that function's normal
# fail-closed behaviour. Every workflow in this repository currently uses
# the block form (re-derive: `grep -n "^on:" .github/workflows/*.yml
# .github/workflows/*.yaml 2>/dev/null` and check none has trailing content
# on the `on:` line itself), so this has not manifested; widen the pattern
# if that ever changes. The same silent-miss applies to any `on:` line the
# sed range's own opening pattern doesn't match byte-for-byte (a CRLF line
# ending, a quoted `'on':` key, or trailing content/whitespace) - re-derive
# both the absence of CRLF (`grep -lP '\r' .github/workflows/*.yml
# .github/workflows/*.yaml 2>/dev/null`, expect no output) and the
# exact-`on:` claim above together, since either drifting reopens this gap.
# (The `2>/dev/null` on both commands is load-bearing, not decoration: with
# no *.yaml file under .github/workflows/ yet, bash passes that glob
# through literally, and grep reports it as a missing file on stderr with a
# non-zero exit - shell-script-reviewer, GH-101 round 8.)
#
# Verified, NOT a gap: a column-0 COMMENT line inside the `on:` block does
# NOT end the range early - the sed end pattern only matches a column-0
# line that is not itself a comment.
find_workflow_call_targets() {
    local workflows_dir="$1"
    local workflow_file name on_block
    for workflow_file in "${workflows_dir}"/*.yml "${workflows_dir}"/*.yaml; do
        [ -e "${workflow_file}" ] || continue
        on_block="$(sed -n '/^on:$/,/^[^ #]/p' "${workflow_file}")"
        if grep -qE '^ {4}workflow_call:' <<< "${on_block}"; then
            name="$(sanitize_for_annotation "$(basename "${workflow_file}")")"
            printf '%s\n' "${name}"
        fi
    done
}

# Fails closed (returns 1, one ::error:: per miss) unless every name from
# find_workflow_call_targets() is documented as its own row in readme_file
# ($2)'s MAIN workflow catalog table specifically - not merely somewhere in
# the file. Scoped to the block from that table's own header line through
# the next blank line: README.md has other sections using the identical
# `| \`name\` | ... |` row shape (re-derive: `grep -n -E '\| \`.*\.ya?ml\`
# \|' README.md` and check which headings the hits fall under) - without this
# scoping, a workflow documented in one of THOSE (e.g. the "Inputs"
# sub-table) or mentioned in free-standing prose would satisfy the check
# without ever having a Purpose/Permissions row of its own - exactly the
# drift this function exists to catch, just relocated instead of fixed.
# Matched via a `case` glob rather than grep -E: the interpolated name can
# contain a literal `.` (a workflow filename's extension separator), which
# `grep -E` would treat as "any character" instead of a literal dot -
# `case` compares it as a literal string with no such widening.
#
# Known limitation (issue #101): the table's end boundary is the next BLANK
# line, not a heading. Removing the blank line before an identically-shaped
# table would silently widen extraction into it. A header-line wording
# change instead fails closed (an empty catalog_table reports every target
# as missing, a loud CI failure) rather than silently.
assert_readme_catalog_complete() {
    local workflows_dir="$1"
    local readme_file="$2"
    local name line found failed=0
    local catalog_table

    catalog_table="$(sed -n '/^| Workflow | Purpose | Permissions/,/^$/p' "${readme_file}")"

    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        found=0
        while IFS= read -r line; do
            case "${line}" in
                "| \`${name}\` |"*)
                    found=1
                    break
                    ;;
            esac
        done <<< "${catalog_table}"

        if [ "${found}" -eq 0 ]; then
            echo "::error::${name} declares workflow_call: but is not listed in README.md's workflow catalog - add it (see issue #101)."
            failed=1
        fi
    done < <(find_workflow_call_targets "${workflows_dir}")

    return "${failed}"
}
