#!/usr/bin/env bash
# Sourced by lint.yml's "readme-catalog-fresh" job and by
# .github/scripts/tests/test-readme-catalog-check.sh, so the workflow and its
# test drive the same file rather than two copies that can drift apart
# (issue #101).

# shellcheck source=annotation-sanitize.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/annotation-sanitize.sh"

# Prints, one per line, the basename of every *.yml file under
# workflows_dir ($1) whose `on:` block declares a real workflow_call
# trigger - anchored to this house style's own 4-space trigger-key
# indentation rather than a bare substring match, since a file could
# mention the trigger name inside a comment without that line being the
# trigger itself. Routed through sanitize_for_annotation()
# (annotation-sanitize.sh) before printing - a git-tracked filename could
# otherwise carry either forgery channel that function's own header dates
# and explains - which also keeps this function's one-name-per-line output
# contract intact for its own caller below, which reads it back with
# `read`: a raw embedded newline would otherwise split one name across two
# lines.
find_workflow_call_targets() {
    local workflows_dir="$1"
    local workflow_file name
    for workflow_file in "${workflows_dir}"/*.yml; do
        if grep -qE '^ {4}workflow_call:' "${workflow_file}"; then
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
# `| \`name\` | ... |` row shape (re-derive: `grep -n '| \`.*\.yml\` |'
# README.md` and check which headings the hits fall under) - without this
# scoping, a workflow documented in one of THOSE (e.g. the "Inputs"
# sub-table) or mentioned in free-standing prose would satisfy the check
# without ever having a Purpose/Permissions row of its own - exactly the
# drift this function exists to catch, just relocated instead of fixed.
# Matched via a `case` glob rather than grep -E: the interpolated name can
# contain a literal `.` (every caller here ends in `.yml`), which `grep -E`
# would treat as "any character" instead of a literal dot - `case` compares
# it as a literal string with no such widening.
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
