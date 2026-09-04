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
# (annotation-sanitize.sh) before printing: a git-tracked filename may
# legally carry a raw control byte OR a percent-encoded one (`%0D%0A`,
# which the Actions runner decodes back to a real CRLF at render time),
# and this value is later interpolated into a `::error::` workflow-command
# annotation by the caller - either channel, left open, would let an
# attacker-chosen filename inject a second, attacker-controlled workflow
# command into that job's own log stream. Folding here (rather than only
# at the point of annotation) also keeps this function's one-name-per-line
# output contract intact for its own caller below, which reads it back
# with `read` - a raw embedded newline would otherwise split one name
# across two lines.
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
# find_workflow_call_targets() is documented as its own catalog-table row
# in readme_file ($2) - a line BEGINNING with the backtick-wrapped name,
# never a bare substring match anywhere in the file. A substring match
# would also be satisfied by a free-standing prose mention (this
# repository's own README already has several, e.g. the pip-exclusion
# paragraph's `auto-merge-deps.yml` reference) with no Purpose/Permissions
# ever documented for that workflow - exactly the drift this check exists
# to catch. Matched via a `case` glob rather than grep -E: the interpolated
# name can contain a literal `.` (every caller here ends in `.yml`), which
# `grep -E` would treat as "any character" instead of a literal dot -
# `case` compares it as a literal string with no such widening.
assert_readme_catalog_complete() {
    local workflows_dir="$1"
    local readme_file="$2"
    local name line found failed=0

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
        done < "${readme_file}"

        if [ "${found}" -eq 0 ]; then
            echo "::error::${name} declares workflow_call: but is not listed in README.md's workflow catalog - add it (see issue #101)."
            failed=1
        fi
    done < <(find_workflow_call_targets "${workflows_dir}")

    return "${failed}"
}
