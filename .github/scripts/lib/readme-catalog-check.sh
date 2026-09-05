#!/usr/bin/env bash
# Sourced by lint.yml's "readme-catalog-fresh" job and by
# .github/scripts/tests/test-readme-catalog-check.sh, so the workflow and its
# test drive the same file rather than two copies that can drift apart
# (issue #101).

# shellcheck source=annotation-sanitize.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/annotation-sanitize.sh"

# Prints, one per line, the basename of every *.yml/*.yaml file under
# workflows_dir ($1) whose `on:` trigger declares workflow_call - shelling
# out to find_workflow_call_targets.py (issue #118) for a real, structural
# YAML parse rather than pattern-matching the raw text. That closes, by
# construction, every trigger-shape gap the old sed/grep heuristic's own
# history had to patch one at a time: the scalar/flow-sequence shorthand
# (`on: workflow_call` / `on: [push, workflow_call]`), a byte-inexact `on:`
# line (a quoted `'on':` key), and the workflow_call-named-JOB collision -
# see that script's own header for the YAML-parser specifics (including the
# "Norway problem" boolean-key resolution GitHub Actions' own bare `on:`
# convention runs into).
#
# Captured via a temp FILE, not `$(...)`: the Python script's own output is
# NUL-terminated, one raw (unsanitised) basename per record, and bash
# command substitution silently truncates a captured string at the first
# embedded NUL byte - reading from a file instead preserves every byte,
# matching semgrep-report-check.sh's own established
# _git_tracked_entries_tempfile() idiom for the same NUL-safety reason.
# Sanitising happens HERE, once per record, straight off the temp file -
# not inside the Python script (a second, independently-drifting
# implementation of the same escape-then-fold strategy issue #91 already
# centralised into sanitize_for_annotation() once) and not via a
# newline-based `read` (which would let an embedded raw newline in a
# filename already split the record in two before sanitize_for_annotation()
# ever saw it whole).
find_workflow_call_targets() {
    local workflows_dir="$1"
    local script_dir tmp_file rc=0 name

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    tmp_file="$(mktemp)" || return 1
    python3 "${script_dir}/find_workflow_call_targets.py" "${workflows_dir}" > "${tmp_file}" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        rm -f "${tmp_file}" || true
        return "${rc}"
    fi

    while IFS= read -r -d '' name; do
        printf '%s\n' "$(sanitize_for_annotation "${name}")"
    done < "${tmp_file}"
    rm -f "${tmp_file}" || true
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
#
# find_workflow_call_targets() is captured via a plain command
# substitution (`names="$(find_workflow_call_targets ...)" || rc=$?`),
# never through `done < <(find_workflow_call_targets ...)`: bash does not
# propagate a process substitution's exit status into the shell that
# started it, so a crashed producer (its own non-zero return, e.g. from
# find_workflow_call_targets.py exiting uncaught) would otherwise look
# identical to "legitimately found zero targets" - the `while read` loop
# simply sees an empty stream, `failed` stays 0, and this function reports
# success for a scan that never actually ran. Verified live before this fix
# (issue #118 audit): forcing find_workflow_call_targets() to fail left this
# function returning 0 with no ::error:: even though a genuine,
# undocumented workflow_call target existed in workflows_dir.
assert_readme_catalog_complete() {
    local workflows_dir="$1"
    local readme_file="$2"
    local name line found failed=0
    local catalog_table names rc=0

    catalog_table="$(sed -n '/^| Workflow | Purpose | Permissions/,/^$/p' "${readme_file}")"

    # A plain command substitution, not a temp file: by the time this
    # capture runs, find_workflow_call_targets()'s own stdout is already
    # one sanitize_for_annotation()-folded name per line (embedded raw
    # newlines already turned into spaces there) - the NUL-safety a temp
    # file would buy belongs only to THAT function's own inner capture of
    # the Python producer's NUL-delimited multi-record stream, not to this
    # already-line-safe output. `|| rc=$?` on a plain (non-`local`)
    # assignment still captures the real command's exit status, the same
    # split-declaration pattern `catalog_table` already uses two lines up.
    names="$(find_workflow_call_targets "${workflows_dir}")" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        echo "::error::find_workflow_call_targets failed (exit ${rc}) - see the log above for the underlying error."
        return 1
    fi

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
    done <<< "${names}"

    return "${failed}"
}
