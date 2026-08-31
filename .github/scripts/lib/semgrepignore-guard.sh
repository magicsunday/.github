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
