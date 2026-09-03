#!/usr/bin/env bash
# Sourced by code-scanning.yml's "Run Semgrep" step and by
# .github/scripts/tests/test-semgrep-excludes.sh, so the workflow and its
# test drive the same file rather than two copies that can drift apart.

# Appends `--exclude <pattern>` pairs to the caller's `extra` array (declared
# and empty before this is sourced) from a NEWLINE-separated pattern list -
# one pattern per line, so a pattern MAY itself contain a space or a tab
# (issue #89: a git-tracked path with a literal space could not previously
# be expressed as a single --exclude pattern at all, since space was also a
# split point). The caller's list is consumed as a plain argument rather
# than inlined into a command, so a value cannot inject shell. It is split
# WITHOUT pathname expansion: an unquoted expansion would also glob, and
# glob is the wrong matcher here, because it resolves the pattern against
# the runner's checkout instead of handing it to Semgrep. The divergence is
# a SLASH-FREE pattern: measured on the pinned engine, `--exclude '*.pdf'`
# skips a PDF at any depth, while the shell expands it against the working
# directory only and leaves a nested one to be read — which then fails this
# gate and is reported as undeclared. A pattern WITH a slash is anchored one
# level either way, so it is the wrong example to reason from. Re-derive:
#
# Read `.paths.skipped`, not `.paths.scanned`: no language claims a PDF, so
# it is absent from BOTH inventories when unexcluded, and a scanned-side
# check would read as confirmation even if the pattern had stopped matching
# at depth.
#
#   semgrep scan --config p/php --exclude '*.pdf' \
#       --json-output=j.json --verbose --metrics off
#   jq -r '.paths.skipped[]
#       | select(.reason == "cli_exclude_flags_match")
#       | .path' j.json   # the nested PDF is listed too
#
# Globbing is switched off around the loop rather than the split being
# hand-rolled: a function-local `IFS=$'\n'` splits ONLY on newline, which is
# what a caller writing the YAML block scalar form (one pattern per line)
# sends — `local IFS` rather than trusting whatever the CALLER's IFS happens
# to be, since this is sourced rather than run in a subshell: a caller with
# `IFS=' '` would otherwise turn a single space-containing pattern into two.
# Newline is still one of bash's IFS-whitespace characters even alone, so a
# blank line (two consecutive newlines) collapses rather than producing a
# spurious empty pattern - verified live (`build_semgrep_exclude_args
# "$(printf 'a\n\nb')"` yields exactly two patterns, `a` and `b`, not three).
# A line holding ONLY spaces/tabs is a different case the old whitespace-IFS
# split absorbed for free but this one does not, since space/tab are no
# longer delimiters: skip a pattern that is empty once its own leading and
# trailing whitespace is stripped, rather than passing a bare `--exclude '
# '`-shaped argument through to Semgrep whose behaviour on it is unverified
# in this environment - shell-script-reviewer, GH-89. A pattern that is
# non-empty ONLY because of internal whitespace (the actual issue #89 case,
# e.g. `'my link.php'`) is untouched by this check, since trimming only its
# ends leaves it non-empty.
# The pre-call noglob state is restored rather than unconditionally cleared,
# since a caller that itself runs under `set -f` would otherwise have
# pathname expansion silently re-enabled on return.
build_semgrep_exclude_args() {
    local patterns="${1:-}"
    local IFS=$'\n'
    local had_noglob=0
    case $- in *f*) had_noglob=1 ;; esac

    set -f
    # shellcheck disable=SC2086
    for pattern in ${patterns}; do
        local trimmed="${pattern#"${pattern%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        [ -n "$trimmed" ] || continue
        extra+=(--exclude "$pattern")
    done
    [ "$had_noglob" -eq 1 ] || set +f
}
