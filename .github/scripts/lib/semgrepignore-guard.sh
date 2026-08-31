#!/usr/bin/env bash
# Sourced by code-scanning.yml's "Check the repository does not carry a
# .semgrepignore file" step and by
# .github/scripts/tests/test-semgrepignore-guard.sh, so the workflow and its
# test drive the same file rather than two copies that can drift apart.

# Prints every `.semgrepignore` path found in the checkout, one per line,
# except one under `.git`, `vendor`, `node_modules` or `.build`. Those four
# are pruned BY NAME rather than by top-level path, so a nested instance
# (e.g. `packages/vendor/.semgrepignore`) is exempted too, matching the
# any-depth (gitignore-style, unanchored) reach of the sibling Run Semgrep
# step's own `--exclude vendor`/`--exclude node_modules`/`--exclude .build`
# flags — a `.semgrepignore` inside a directory those flags already remove,
# at any depth, from what gets scanned cannot affect the result either way.
# Re-derive the any-depth claim, in a scratch git checkout:
#
#   mkdir -p src/vendor && printf '<?php eval($_GET["x"]);\n' > src/vendor/bad.php
#   git add -Af . && semgrep scan --config p/php --exclude vendor \
#       --json-output=j.json --verbose --metrics off
#   jq -r '.paths.skipped[] | "\(.path): \(.reason)"' j.json
#       # src/vendor/bad.php: cli_exclude_flags_match — nested, still excluded
#
# `.git` is pruned for an unrelated reason: Semgrep enumerates scan targets
# via `git ls-files` in a git checkout, which can never name a path under
# `.git` as a target, so nothing there is a `--exclude` flag's doing.
#
# `find -name` matches a dangling symlink by its own directory-entry name
# without following it, so a broken `.semgrepignore` symlink is caught
# without a separate code path.
find_semgrepignore_files() {
    find . \( -name '.git' -o -name 'vendor' -o -name 'node_modules' -o -name '.build' \) -prune -o -name '.semgrepignore' -print
}

# Neutralizes a string before the caller embeds it into a GitHub Actions
# `::error::` log annotation, closing two independent forgery channels a
# caller-controlled path can carry:
#
# - A raw control byte. As observed 2026-08-31 against a real Actions run,
#   the runner's log reader was .NET-based and `TextReader.ReadLine()`
#   treated a bare CR as a line terminator the same way it treated LF — so
#   an embedded CR, not only LF, can forge what reads as a second,
#   attacker-authored annotation line unless every control byte is folded
#   away. `tr '[:cntrl:]'` alone would map two DIFFERENT control bytes to
#   the same placeholder character and then collapse that placeholder to a
#   space in a second pass — colliding with any literal `?` already in the
#   path (a legal filename character) and silently mangling it the same
#   way. Folding straight to space in one pass has no such collision.
# - A PERCENT-ENCODED control byte. As observed 2026-08-31 against a real
#   Actions run, GitHub Actions' own workflow-command escaping scheme
#   represented a literal `%`, CR or LF inside an annotation MESSAGE as
#   `%25`, `%0D`, `%0A` respectively, and the runner decoded those
#   sequences back on render — it cannot tell an already-escaped sequence
#   from literal `%0D` text that happened to be in the source data. A path
#   literally named `%0D%0A::error::forged` passes `tr '[:cntrl:]'`
#   untouched (no raw control byte in it) and would decode to a real CRLF
#   once the runner renders it. Escaping a literal `%` to `%25` FIRST is
#   what closes this - the identical defense semgrep-report-check.sh
#   already applies to report-derived text (`gsub("%"; "%25")` /
#   `${var//%/%25}`), which this mirrors.
sanitize_for_annotation() {
    printf '%s' "$1" | sed 's/%/%25/g' | tr '[:cntrl:]' ' '
}

# Runs the complete .semgrepignore guard code-scanning.yml's "Check the
# repository does not carry a .semgrepignore file" step wires up, and
# returns non-zero if the repository fails it - fail-closed on the `find`
# itself erroring, and fail-closed on a `.semgrepignore` actually being
# found. Previously this assertion (the command substitution, the `||`
# failure handling and the `-n` check) lived only in the workflow step's
# `run:` block, so test-semgrepignore-guard.sh could exercise
# find_semgrepignore_files() and sanitize_for_annotation() individually but
# never the wiring between them - a later edit that dropped the `||` block
# or reversed the `-n` check would have passed every test while leaving a
# caller's `.semgrepignore` free to affect the scan.
assert_no_semgrepignore() {
    local matches
    # `find` inside find_semgrepignore_files() can itself fail (e.g. an
    # unreadable subtree); degrade to an actionable annotation rather than
    # this function's own raw, unattributed failure - the same
    # degrade-to-a-placeholder-rather-than-abort shape
    # semgrep-report-check.sh's jq call already applies a few steps later in
    # the same job (issues #65, #69).
    matches=$(find_semgrepignore_files) || {
        echo "::error::Could not check the repository for a .semgrepignore file - see this step's own output above for the underlying error."
        return 1
    }

    if [ -n "$matches" ]; then
        local safe_matches
        safe_matches="$(sanitize_for_annotation "$matches")"
        echo "::error::This repository contains a .semgrepignore file (${safe_matches}), which replaces Semgrep's built-in ignore list instead of adding to it and cannot be told apart from the engine defaults in the report - declare exclusions via this workflow's 'excludes' input instead, then delete the file."
        return 1
    fi

    return 0
}
