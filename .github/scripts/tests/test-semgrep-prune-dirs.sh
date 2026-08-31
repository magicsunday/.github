#!/usr/bin/env bash
# Cross-checks that find_semgrepignore_files() (semgrepignore-guard.sh) and
# the Run Semgrep step (code-scanning.yml) both read the vendor/node_modules/
# .build list from the single shared semgrep-prune-dirs.sh rather than
# hand-maintaining their own copy again, and that neither carries a literal
# -name/--exclude for a directory on the side.
#
# Issue #79 replaced the original version of this test (named
# test-semgrepignore-prune-matches-excludes.sh), which diffed two
# independently hand-maintained lists for equality. Now there is only one
# list, so a plain string diff has nothing left to compare — the residual
# risk this guards is a call site reverting to its own hardcoded copy
# instead of reading the shared array, which a list-equality check would
# not catch (both sides could still happen to agree by coincidence). This
# checks the SOURCING wiring instead, and that a reverted literal has not
# reappeared. Mirrors the sourcing-wiring shape test-lib-source-cp-drift.sh
# already checks for the cp side of the same dependency.
#
# Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
PRUNE_DIRS_FILE="${REPO_ROOT}/.github/scripts/lib/semgrep-prune-dirs.sh"
GUARD_FILE="${REPO_ROOT}/.github/scripts/lib/semgrepignore-guard.sh"
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/code-scanning.yml"

require_file "${PRUNE_DIRS_FILE}"
require_file "${GUARD_FILE}"
require_file "${WORKFLOW_FILE}"
# failures=0 is set at lib/harness.sh's top level, sourced above.
# shellcheck disable=SC2154
if [ "${failures}" -gt 0 ]; then
    report_and_exit "semgrep prune-dirs sourcing drift-guard test"
fi

# shellcheck source=../lib/semgrep-prune-dirs.sh
source "${PRUNE_DIRS_FILE}"
assert_nonempty "${SEMGREP_PRUNE_DIRS[*]:-}" \
    "SEMGREP_PRUNE_DIRS is empty after sourcing ${PRUNE_DIRS_FILE} - nothing for either consumer to read"
assert_eq "SEMGREP_PRUNE_DIRS names exactly vendor, node_modules and .build" \
    "vendor node_modules .build" "${SEMGREP_PRUNE_DIRS[*]:-}"

# Scoped to each consumer's own body - a grep with no boundary would also
# match a `source`/`--exclude`/`-name` mention sitting in a comment
# elsewhere in either file.
guard_body="$(extract_block 'find_semgrepignore_files() {' '^[[:space:]]*}[[:space:]]*$' "${GUARD_FILE}")"
scan_body="$(extract_block 'attempt_semgrep_scan() {' '^[[:space:]]*}[[:space:]]*$' "${WORKFLOW_FILE}")"
run_semgrep_step="$(extract_block '- name: Run Semgrep' '- name:' "${WORKFLOW_FILE}")"

assert_nonempty "${guard_body}" \
    "extracted no body for find_semgrepignore_files() from ${GUARD_FILE} - function shape changed"
assert_nonempty "${scan_body}" \
    "extracted no body for attempt_semgrep_scan() from ${WORKFLOW_FILE} - function shape changed"
assert_nonempty "${run_semgrep_step}" \
    "extracted no body for the Run Semgrep step from ${WORKFLOW_FILE} - step shape changed"

# Full-line comments stripped first, so a prose mention of the filename or
# the array name (this file's own header included) cannot satisfy a check
# meant to prove the CODE reads it.
strip_comments() {
    grep -vE '^[[:space:]]*#' "$@"
}

guard_code="$(strip_comments "${GUARD_FILE}")"
run_semgrep_code="$(strip_comments <<<"${run_semgrep_step}")"
guard_body_code="$(strip_comments <<<"${guard_body}")"
scan_body_code="$(strip_comments <<<"${scan_body}")"

assert_nonempty "$(grep -E '^[[:space:]]*source ".*/semgrep-prune-dirs\.sh"$' <<<"${guard_code}")" \
    "${GUARD_FILE} has no actual (non-comment) source line for semgrep-prune-dirs.sh"
assert_nonempty "$(grep -o 'SEMGREP_PRUNE_DIRS' <<<"${guard_body_code}")" \
    "find_semgrepignore_files() in ${GUARD_FILE} does not read SEMGREP_PRUNE_DIRS in actual code"
assert_nonempty "$(grep -E '^[[:space:]]*source ".*/semgrep-prune-dirs\.sh"$' <<<"${run_semgrep_code}")" \
    "the Run Semgrep step in ${WORKFLOW_FILE} has no actual (non-comment) source line for semgrep-prune-dirs.sh"
assert_nonempty "$(grep -o 'SEMGREP_PRUNE_DIRS' <<<"${scan_body_code}${run_semgrep_code}")" \
    "neither attempt_semgrep_scan() nor the Run Semgrep step in ${WORKFLOW_FILE} reads SEMGREP_PRUNE_DIRS in actual code"

# Every -name literal (single- OR double-quoted, but not a "${dir}"-style
# expansion) that appears on a line assigning or appending to prune_names,
# besides '.git' (pruned for its own unrelated reason, not from the shared
# array - see that function's comment). Scoped to prune_names' own
# construction lines rather than the whole function body: the function's
# closing `find` invocation also contains a legitimate, unrelated
# `-name '.semgrepignore'` (the search target, not a pruned directory) -
# a name-based exclusion for that literal would also swallow a MALICIOUS
# `-o -name '.semgrepignore'` slipped into prune_names itself (which would
# silently make the guard treat any .semgrepignore-named path as prune-
# worthy and skip checking it). Scoping by line role, not by literal value,
# closes that hole. A hardcoded literal reappearing here - e.g. a
# maintainer adding `-o -name 'cache'` or `-o -name "cache"` alongside the
# array-driven loop - would silently reopen the exact drift this file
# exists to close, and neither of the two sourcing checks above would
# catch it (both only prove the array IS read, not that nothing ELSE was
# also added). An empty remainder is the proof; `-name "${dir}"` from the
# loop itself does not match either quoted-literal pattern (the character
# class excludes `$`), so the loop's own generated names never trip this
# check.
#
# Deliberately out of scope: an unquoted bareword `-name secret_dir` and a
# construction split across more than one `prune_names+=` line (the
# single-line grep below only matches lines that themselves contain the
# assignment). Both are real gaps against a
# maintainer trying to actively EVADE this test, but that is not this
# test's threat model - a maintainer willing to hand-craft an unquoted or
# multi-line literal specifically to dodge this check could edit the test
# itself just as easily. The threat model this test defends is the
# ordinary case: a careless duplicate re-introduced in the codebase's own
# established, single-line, quoted style.
guard_prune_build_lines="$(grep -E 'prune_names(\+)?=' <<<"${guard_body_code}")"
guard_literal_names="$(grep -oE -- "-name '[^']*'|-name \"[^\"\$]*\"" <<<"${guard_prune_build_lines}" \
    | sed -E "s/-name //; s/[\"']//g" | grep -vx '\.git' | sort -u)"
assert_eq "find_semgrepignore_files() builds prune_names from no literal beyond '.git'" \
    "" "${guard_literal_names}"

# Same shape on the scan side: every literal --exclude flag (either quote
# style) in attempt_semgrep_scan(), besides '*.min.js' (a file-suffix glob,
# not a directory name - see semgrep-prune-dirs.sh's own comment for why it
# has no counterpart in the shared array). There is no scan-side analogue
# of the guard's position-dependent '.semgrepignore' target, so scanning
# the whole function body (rather than a construction-line subset) is
# sufficient here: after the fix, everything SEMGREP_PRUNE_DIRS names
# reaches the scan only via "${extra[@]}"; any literal --exclude beyond
# '*.min.js' found anywhere in this function is a reintroduced hardcoded copy.
scan_literal_excludes="$(grep -oE -- "--exclude '[^']*'|--exclude \"[^\"\$]*\"|--exclude [A-Za-z0-9_./*-]+" <<<"${scan_body_code}" \
    | sed -E 's/--exclude //; s/["'"'"']//g' | grep -vx '\*\.min\.js' | sort -u)"
assert_eq "attempt_semgrep_scan() hardcodes no --exclude literal beyond '*.min.js'" \
    "" "${scan_literal_excludes}"

report_and_exit "semgrep prune-dirs sourcing drift-guard test"
