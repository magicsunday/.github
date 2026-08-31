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
original_dir="$(pwd)"

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
# from one case into the next.
fresh_case_dir() {
    local dir="${work_dir}/case-$$-${RANDOM}"
    mkdir -p "${dir}" || exit 1
    printf '%s' "${dir}"
}

case_dir="$(fresh_case_dir)"
cd "${case_dir}" || exit 1
assert_matches "clean tree: no match"
cd "${original_dir}" || exit 1

case_dir="$(fresh_case_dir)"
cd "${case_dir}" || exit 1
: > .semgrepignore
assert_matches "root-level file caught" ".semgrepignore"
cd "${original_dir}" || exit 1

# The exact case a root-only `test -e .semgrepignore` shipped once without
# catching (issue #48 round 1) - Semgrepignore v2 honors a `.semgrepignore`
# at any directory level, so the guard has to walk the tree.
case_dir="$(fresh_case_dir)"
cd "${case_dir}" || exit 1
mkdir -p sub
: > sub/.semgrepignore
assert_matches "nested file under sub/ caught" "sub/.semgrepignore"
cd "${original_dir}" || exit 1

# A dangling symlink is matched by name, not by a successful stat of its
# target - find_semgrepignore_files() relies on that rather than a separate
# code path.
case_dir="$(fresh_case_dir)"
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
case_dir="$(fresh_case_dir)"
cd "${case_dir}" || exit 1
mkdir -p .git vendor node_modules .build packages/vendor
: > .git/.semgrepignore
: > vendor/.semgrepignore
: > node_modules/.semgrepignore
: > .build/.semgrepignore
: > packages/vendor/.semgrepignore
assert_matches "pruned dirs (incl. nested vendor/) never match"
cd "${original_dir}" || exit 1

report_and_exit "semgrepignore-guard tests"
