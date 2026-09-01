#!/usr/bin/env bash
# Exercises find_semgrepignore_files() (.github/scripts/lib/semgrepignore-guard.sh),
# the function code-scanning.yml sources to reject a repository-local
# `.semgrepignore` file anywhere in the caller's checkout (issue #48). Run via
# run-tests.sh.
#
# A root-only check shipped in this workflow once and was found, via live
# reproduction against the pinned semgrep engine, to miss a `.semgrepignore`
# nested one directory down - the exact case the third assertion below pins,
# so this regression cannot ship silently a second time.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"
# shellcheck source=../lib/semgrepignore-guard.sh
source "${SCRIPT_DIR}/../lib/semgrepignore-guard.sh"

work_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "${work_dir}"' EXIT
original_dir="$(pwd)" || exit 1

# assert_matches DESCRIPTION EXPECTED_RELATIVE_PATH...
# Runs find_semgrepignore_files() from inside work_dir and compares its
# sorted output, as one newline-joined string, against the expected relative
# paths (given without their leading `./` - find always prints that prefix,
# added back here rather than at every call site). Plain string comparison
# via assert_eq() sidesteps the empty-array expansion pitfalls a bash `-a`
# comparison would otherwise have to work around.
assert_matches() {
    local description="$1"
    shift

    local want=""
    local p
    for p in "$@"; do
        want="${want}./${p}"$'\n'
    done
    want="$(printf '%s' "${want}" | sort)"

    local got
    got="$(find_semgrepignore_files | sort)"

    assert_eq "${description}" "${want}" "${got}"
}

# Every case gets its OWN fresh directory - `rm -rf dir/*` does not remove
# dotfiles (the glob does not match a leading dot), so reusing one directory
# and globbing it clean between cases would silently leak a `.semgrepignore`
# from one case into the next. `mktemp -d "${work_dir}/case-XXXXXX" || exit 1`
# is inlined at each site rather than wrapped in a helper: a wrapper's `exit`
# would run inside the subshell `$(...)` creates to capture its output,
# never reaching this script - the earlier version of this file carried
# exactly that bug. Guarding the substitution directly, as `work_dir` above
# already does, has no such gap.

case_dir="$(mktemp -d "${work_dir}/case-XXXXXX")" || exit 1
cd "${case_dir}" || exit 1
assert_matches "clean tree: no match"
cd "${original_dir}" || exit 1

case_dir="$(mktemp -d "${work_dir}/case-XXXXXX")" || exit 1
cd "${case_dir}" || exit 1
: > .semgrepignore
assert_matches "root-level file caught" ".semgrepignore"
cd "${original_dir}" || exit 1

# The exact case a root-only `test -e .semgrepignore` shipped once without
# catching (issue #48 round 1) - Semgrepignore v2 honors a `.semgrepignore`
# at any directory level, so the guard has to walk the tree.
case_dir="$(mktemp -d "${work_dir}/case-XXXXXX")" || exit 1
cd "${case_dir}" || exit 1
mkdir -p sub
: > sub/.semgrepignore
assert_matches "nested file under sub/ caught" "sub/.semgrepignore"
cd "${original_dir}" || exit 1

# A dangling symlink is matched by name, not by a successful stat of its
# target - find_semgrepignore_files() relies on that rather than a separate
# code path.
case_dir="$(mktemp -d "${work_dir}/case-XXXXXX")" || exit 1
cd "${case_dir}" || exit 1
ln -s /nonexistent-target .semgrepignore
assert_matches "dangling symlink caught" ".semgrepignore"
cd "${original_dir}" || exit 1

# The Run Semgrep step's own `--exclude vendor`/`--exclude node_modules`/
# `--exclude .build` flags already remove these directories - at any depth -
# from what gets scanned, and `.git` never yields a `git ls-files` target
# either, so a `.semgrepignore` inside any of them cannot affect the result.
# Pruned by name (not by top-level path), so this holds for a NESTED
# instance too, matching those flags' own any-depth reach.
case_dir="$(mktemp -d "${work_dir}/case-XXXXXX")" || exit 1
cd "${case_dir}" || exit 1
mkdir -p .git vendor node_modules .build packages/vendor
: > .git/.semgrepignore
: > vendor/.semgrepignore
: > node_modules/.semgrepignore
: > .build/.semgrepignore
: > packages/vendor/.semgrepignore
assert_matches "pruned dirs (incl. nested vendor/) never match"
cd "${original_dir}" || exit 1

# sanitize_for_annotation() itself (annotation-sanitize.sh) is exercised by
# test-annotation-sanitize.sh, not here - this suite only needs it as the
# collaborator assert_no_semgrepignore() calls below.

# assert_no_semgrepignore() is the exact wiring code-scanning.yml's guard
# step calls - see that function's own comment (semgrepignore-guard.sh) for
# why this exercises the wiring itself, not just its two constituent
# functions.
case_dir="$(mktemp -d "${work_dir}/case-XXXXXX")" || exit 1
cd "${case_dir}" || exit 1
output="$(assert_no_semgrepignore 2>&1)"
rc=$?
assert_eq "assert_no_semgrepignore: clean tree returns success" "0" "${rc}"
assert_eq "assert_no_semgrepignore: clean tree prints nothing" "" "${output}"
cd "${original_dir}" || exit 1

case_dir="$(mktemp -d "${work_dir}/case-XXXXXX")" || exit 1
cd "${case_dir}" || exit 1
: > .semgrepignore
output="$(assert_no_semgrepignore 2>&1)"
rc=$?
assert_eq "assert_no_semgrepignore: existing file fails closed" "1" "${rc}"
assert_eq "assert_no_semgrepignore: existing file emits the found annotation" \
    "::error::This repository contains a .semgrepignore file (./.semgrepignore), which replaces Semgrep's built-in ignore list instead of adding to it and cannot be told apart from the engine defaults in the report - declare exclusions via this workflow's 'excludes' input instead, then delete the file." \
    "${output}"
cd "${original_dir}" || exit 1

# Simulates sanitize_for_annotation() itself failing (e.g. jq missing or
# crashing - a real possibility since issue #80 made it jq-backed) to pin
# the fail-closed fallback around the "local safe_matches" assignment in
# assert_no_semgrepignore() (semgrepignore-guard.sh): unguarded, this would
# abort the whole step under set -e before ever
# printing the found-file annotation below (round-1 correctness finding,
# GH-80). Restored to the real implementation immediately after via a
# fresh source, since a case added later in this file must not silently
# run against the stub.
case_dir="$(mktemp -d "${work_dir}/case-XXXXXX")" || exit 1
cd "${case_dir}" || exit 1
: > .semgrepignore
sanitize_for_annotation() { return 1; }
output="$(assert_no_semgrepignore 2>&1)"
rc=$?
# shellcheck source=../lib/annotation-sanitize.sh
source "${SCRIPT_DIR}/../lib/annotation-sanitize.sh"
assert_eq "assert_no_semgrepignore: a sanitize_for_annotation failure still fails closed" "1" "${rc}"
assert_eq "assert_no_semgrepignore: a sanitize_for_annotation failure still emits the found annotation, with a placeholder" \
    "::error::This repository contains a .semgrepignore file ((unavailable)), which replaces Semgrep's built-in ignore list instead of adding to it and cannot be told apart from the engine defaults in the report - declare exclusions via this workflow's 'excludes' input instead, then delete the file." \
    "${output}"
cd "${original_dir}" || exit 1

# Simulates find_semgrepignore_files() itself failing (e.g. an unreadable
# subtree) by overriding it for the rest of this script - safe only because
# this is the LAST case that needs the real function; a case added after
# this one would silently run against the stub instead.
find_semgrepignore_files() { return 1; }
output="$(assert_no_semgrepignore 2>&1)"
rc=$?
assert_eq "assert_no_semgrepignore: a find failure fails closed" "1" "${rc}"
assert_eq "assert_no_semgrepignore: a find failure emits the could-not-check annotation" \
    "::error::Could not check the repository for a .semgrepignore file - see this step's own output above for the underlying error." \
    "${output}"

report_and_exit "semgrepignore-guard tests"
