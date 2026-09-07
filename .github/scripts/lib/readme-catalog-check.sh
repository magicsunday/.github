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
# YAML parse rather than pattern-matching the raw text. See that script's
# own header for exactly which sed/grep-heuristic trigger-shape gaps this
# closes and how; see its _has_workflow_call_trigger() for the "Norway
# problem" boolean-key resolution GitHub Actions' own bare `on:`
# convention runs into.
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
# the file - and, the reverse direction (issue #116), unless every row of
# that table still names one of those targets: a row whose file was removed,
# renamed or stopped declaring workflow_call: fails the same way. Scoped to
# the block from that table's own header line through
# the next blank line: README.md has other sections using the identical
# `| \`name\` | ... |` row shape (re-derive: `grep -n -E '\| \`.*\.ya?ml\`
# \|' README.md` and check which headings the hits fall under) - without this
# scoping, a workflow documented in one of THOSE (e.g. the "Inputs"
# sub-table) or mentioned in free-standing prose would satisfy the check
# without ever having a Purpose/Permissions row of its own - exactly the
# drift this function exists to catch, just relocated instead of fixed.
# Matched via an anchored `[[ =~ ]]` regex, not a bare `case` glob: the
# interpolated name sits inside its own double quotes in the pattern
# (`` `"${name}"` ``), which - the same as a quoted expansion inside a
# case pattern - is matched as a literal string regardless of its
# content, not as regex syntax. An earlier version of this fix instead
# hand-escaped only the name's literal `.` (a workflow filename's
# extension separator, the one metacharacter every fixture exercised)
# and left every other ERE metacharacter live; three independent lanes
# reproduced both directions of the resulting regression live - a
# genuinely documented target containing `+`/`*`/`?`/`[`/`]` etc. was
# reported as "not listed" (the pattern no longer matched its own,
# correct row), and an UNDOCUMENTED target containing `[`/`*`/`+` could
# silently match an unrelated row instead, defeating this function's own
# fail-closed guarantee. Quoting the whole name instead of hand-escaping
# one character restores the same content-independent literal match the
# original `case` glob had, while still gaining the trailing
# `[[:space:]]*` tolerance the reverse walk's own row regex already
# accepts: a plain `case "${line}" in "| \`${name}\` |"*)` literal
# required exactly one space there, so a real, correctly-documented
# target whose row happens to have zero spaces before the pipe (a
# plausible GFM-table reformat) was silently reported as "not listed"
# even though the reverse walk already accepted the identical row as
# well-formed (live-reproduced: a zero-space `` `real.yml`| `` row
# failed here before this fix, while assert_readme_catalog_complete()'s
# own reverse walk passed it).
#
# Known limitation (issue #101): the table's end boundary is the next BLANK
# line, not a heading. Removing the blank line before an identically-shaped
# table would silently widen extraction into it - and, since the reverse walk
# below, report that table's non-target rows as stale. A header-line wording
# change instead fails closed (an empty catalog_table reports every target
# as missing, a loud CI failure) rather than silently.
#
# Known limitation (issue #116): the reverse walk's name-capture class
# excludes both a backtick and a pipe, so a well-formed row whose name
# LITERALLY contains `|` gets the "not a single backtick-quoted name"
# diagnostic instead of a genuine "is missing" verdict - the row still
# fails closed either way. Not fixed, because a GitHub Actions workflow
# filename cannot contain `|` in practice.
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
    local name line row message found failed=0
    local catalog_table names rc=0 after_header=0

    catalog_table="$(sed -n '/^| Workflow | Purpose | Permissions/,/^$/p' "${readme_file}")"

    # A plain command substitution, not a temp file: by the time this
    # capture runs, find_workflow_call_targets()'s own stdout is already
    # one sanitize_for_annotation()-folded name per line (embedded raw
    # newlines already turned into spaces there) - the NUL-safety a temp
    # file would buy belongs only to THAT function's own inner capture of
    # the Python producer's NUL-delimited multi-record stream, not to this
    # already-line-safe output. `|| rc=$?` on a plain (non-`local`)
    # assignment still captures the real command's exit status, the same
    # split-declaration pattern already used above for `catalog_table`
    # (declared without a value, then assigned separately, so `|| rc=$?`
    # is never masked the way a combined `local x=$(cmd)` would mask it).
    names="$(find_workflow_call_targets "${workflows_dir}")" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        echo "::error::find_workflow_call_targets failed (exit ${rc}) - see the log above for the underlying error."
        return 1
    fi

    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        found=0
        while IFS= read -r line; do
            if [[ "${line}" =~ ^\|\ \`"${name}"\`[[:space:]]*\| ]]; then
                found=1
                break
            fi
        done <<< "${catalog_table}"

        if [ "${found}" -eq 0 ]; then
            echo "::error::${name} declares workflow_call: but is not listed in README.md's workflow catalog - add it (see issue #101)."
            failed=1
        fi
    done <<< "${names}"

    # The reverse direction. Two kinds of furniture line precede the data
    # rows: the header ("| Workflow | ... |", the sed range's own start
    # pattern) and the GFM alignment separator ("| --- | ... |", or its
    # colon-alignment variants). The header is recognised by its own exact
    # text, at ANY position - a duplicated header line inside the table body
    # can never be mistaken for a data row, since a real catalog row always
    # needs a backtick-quoted name. The separator is recognised only on the
    # line immediately after a recognised header (a state flag, not a
    # table-wide position count), and only when every cell matches genuine
    # GFM alignment syntax (`:?-+:?` - at least one contiguous dash per
    # cell, optionally colon-bounded), not merely "made up of |, -, : and
    # whitespace somewhere in the line", and only when there are EXACTLY
    # three such cells - the same fixed column count as the header literal
    # this file already anchors on everywhere else, so a 1-, 2- or 4+-cell
    # line is a malformed row, not a genuine (if oddly-shaped) separator.
    # Neither position alone, nor table position alone, nor a looser
    # punctuation-only or cell-count-agnostic shape check, is sufficient on
    # its own: each, tried in turn, let some malformed row (a missing
    # separator, a blanked-out `| | | |` row, punctuation that contains a
    # dash without forming a real alignment cell, or a separator with the
    # wrong number of columns) silently pass as furniture instead of
    # failing closed as malformed - see this file's git history and issue
    # #116 for the exact shapes that broke each earlier attempt.
    #
    # A well-formed data row is matched in one step: the leading pipe and
    # exactly one space precede `` ` ``, which starts the name; `[^\`|]*` is the
    # name itself (excluding backtick and pipe, so it can never cross into a
    # later cell or absorb a later cell's own backtick); a second `` ` ``
    # closes it, then optional spaces and the column pipe. This one pattern is
    # what earlier rounds built as three separate, accumulating guards (a
    # row-shape case, a swallowed-pipe case, an empty-cell check) and still
    # missed: a row's OWN closing backtick immediately followed by the
    # column pipe is the only shape the membership test below should ever
    # see, so requiring it in the match itself - rather than trying to rule
    # out each way of not having it - cannot mis-extract into a later
    # cell's Purpose-column backticks (the `[^\`|]*` class stops there,
    # well-formed or not) and covers a name cell with no backtick at all,
    # or with any amount of surrounding whitespace, the same way: the
    # pattern fails to match, so the row goes to the malformed-row branch.
    # The membership test still runs on the RAW captured name, deliberately:
    # names already holds the sanitize_for_annotation()-folded form of each
    # filename, and the forward loop above accepts a row only when it
    # carries that same form - so a row that matches a target only after
    # being sanitised itself would be a row the forward direction never
    # accepted either. Sanitising happens for the printed annotation alone,
    # because the row text is README-controlled input into a ::error::
    # line, the same forgery channel the filesystem-side names go through.
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        case "${line}" in
            "| Workflow | Purpose | Permissions"*)
                after_header=1
                continue
                ;;
        esac
        if [ "${after_header}" -eq 1 ]; then
            after_header=0
            if [[ "${line}" =~ ^\|([[:space:]]*:?-+:?[[:space:]]*\|){3}$ ]]; then
                continue
            fi
        fi
        if [[ "${line}" =~ ^\|\ \`([^\`\|]*)\`[[:space:]]*\| ]]; then
            row="${BASH_REMATCH[1]}"
        else
            echo "::error::a catalog row's name cell in README.md is not a single backtick-quoted name immediately followed by the column separator - fix the row (see issue #116)."
            failed=1
            continue
        fi
        if [ -z "${row}" ]; then
            echo "::error::an empty backtick cell in README.md's workflow catalog names no workflow - remove the row (see issue #116)."
            failed=1
            continue
        fi
        if ! grep -qxF -- "${row}" <<< "${names}"; then
            if [ -f "${workflows_dir}/${row}" ]; then
                message="the file exists and declares no workflow_call: trigger the parser could read - remove the row or restore the trigger"
            else
                message="the file is missing under ${workflows_dir} - remove the row or restore the file"
            fi
            echo "::error::$(sanitize_for_annotation "${row}") is listed in README.md's workflow catalog, but ${message} (see issue #116)."
            failed=1
        fi
    done <<< "${catalog_table}"

    return "${failed}"
}
