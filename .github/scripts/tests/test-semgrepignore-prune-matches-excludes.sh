#!/usr/bin/env bash
# Cross-checks that find_semgrepignore_files()'s prune list
# (.github/scripts/lib/semgrepignore-guard.sh) and the Run Semgrep step's
# --exclude flags (.github/workflows/code-scanning.yml) name the same
# directories - vendor, node_modules, .build. Semgrep excludes those from
# the scan, so semgrepignore-guard.sh treats a `.semgrepignore` inside them
# as inert and skips checking for one there (see that file's own comment).
#
# The two lists are hand-maintained in separate files with nothing but a
# comment tying them together. The drift that matters is editing the
# guard's OWN prune tuple (e.g. adding a directory) without also adding a
# matching --exclude flag to the scan step: the guard would then skip a
# directory the scan still reads, and a `.semgrepignore` placed there would
# silently affect scan results again - the exact channel issue #48 closes,
# reopened through a different edit than the one #48 originally fixed.
# (The reverse drift - the scan step excluding a NEW directory the guard
# does not yet prune - only makes the guard over-strict, never reopens the
# bypass, since Semgrep already excludes that directory either way; this
# test still catches it, since any mismatch fails.)
#
# Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
GUARD_FILE="${REPO_ROOT}/.github/scripts/lib/semgrepignore-guard.sh"
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/code-scanning.yml"

for f in "${GUARD_FILE}" "${WORKFLOW_FILE}"; do
    if [ ! -f "${f}" ]; then
        echo "FAIL: expected file not found: ${f}"
        failures=$((failures + 1))
    fi
done
if [ "${failures}" -gt 0 ]; then
    report_and_exit "semgrepignore prune/exclude drift-guard test"
fi

# Every `-name 'X'` in the guard's find expression, minus `.git` (excluded
# for an unrelated reason - git ls-files target enumeration, not a
# --exclude flag - so it has no counterpart on the scan side) and
# `.semgrepignore` itself (the search target, not a pruned directory).
guard_dirs="$(grep -o "\-name '[^']*'" "${GUARD_FILE}" \
    | grep -o "'[^']*'" | tr -d "'" \
    | grep -Ev '^\.git$|^\.semgrepignore$' | sort -u)"

# Every `--exclude X` in the workflow, minus the one glob pattern
# (*.min.js) - it names a file suffix, not a directory, so it has no
# counterpart on the guard side either.
scan_dirs="$(grep -oE -- "--exclude '[^']*'|--exclude [A-Za-z0-9_./*-]+" "${WORKFLOW_FILE}" \
    | sed -E "s/--exclude //; s/'//g" \
    | grep -vx '\*\.min\.js' | sort -u)"

assert_eq "guard's prune list matches the Run Semgrep step's --exclude directories" \
    "${scan_dirs}" "${guard_dirs}"

report_and_exit "semgrepignore prune/exclude drift-guard test"
