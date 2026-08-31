#!/usr/bin/env bash
# Sourced by code-scanning.yml's "Check the repository does not carry a
# .semgrepignore file" step and by
# .github/scripts/tests/test-semgrepignore-guard.sh, so the workflow and its
# test drive the same file rather than two copies that can drift apart.

# shellcheck source=annotation-sanitize.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/annotation-sanitize.sh"

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

# Runs the complete .semgrepignore guard code-scanning.yml's "Check the
# repository does not carry a .semgrepignore file" step wires up, and
# returns non-zero if the repository fails it - fail-closed on the `find`
# itself erroring, and fail-closed on a `.semgrepignore` actually being
# found. Previously this assertion (the command substitution, the `||`
# failure handling and the `-n` check) lived only in the workflow step's
# `run:` block, so test-semgrepignore-guard.sh could exercise
# find_semgrepignore_files() individually but never the wiring between it
# and sanitize_for_annotation() (annotation-sanitize.sh, its own individual
# tests live in test-annotation-sanitize.sh) - a later edit that dropped the
# `||` block or reversed the `-n` check would have passed every test while
# leaving a caller's `.semgrepignore` free to affect the scan.
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
