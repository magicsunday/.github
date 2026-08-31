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
# - A raw control byte. The runner's log reader is .NET-based and
#   `TextReader.ReadLine()` treats a bare CR as a line terminator the same
#   way it treats LF (verified 2026-08-31 against a real Actions run) — so
#   an embedded CR, not only LF, can forge what reads as a second,
#   attacker-authored annotation line unless every control byte is folded
#   away. `tr '[:cntrl:]'` alone would map two DIFFERENT control bytes to
#   the same placeholder character and then collapse that placeholder to a
#   space in a second pass — colliding with any literal `?` already in the
#   path (a legal filename character) and silently mangling it the same
#   way. Folding straight to space in one pass has no such collision.
# - A PERCENT-ENCODED control byte. GitHub Actions' own workflow-command
#   escaping scheme represents a literal `%`, CR or LF inside an
#   annotation MESSAGE as `%25`, `%0D`, `%0A` respectively, and the runner
#   decodes those sequences back on render — it cannot tell an
#   already-escaped sequence from literal `%0D` text that happened to be
#   in the source data. A path literally named `%0D%0A::error::forged`
#   passes `tr '[:cntrl:]'` untouched (no raw control byte in it) and
#   would decode to a real CRLF once the runner renders it. Escaping a
#   literal `%` to `%25` FIRST is what closes this - the identical
#   defense semgrep-report-check.sh already applies to report-derived
#   text (`gsub("%"; "%25")` / `${var//%/%25}`), which this mirrors.
sanitize_for_annotation() {
    printf '%s' "$1" | sed 's/%/%25/g' | tr '[:cntrl:]' ' '
}
