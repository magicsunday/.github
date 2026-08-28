#!/usr/bin/env bash
# Exercises build_semgrep_exclude_args() (.github/scripts/lib/semgrep-excludes.sh),
# the function code-scanning.yml sources to turn its `excludes` input into
# Semgrep `--exclude` arguments. Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"
# shellcheck source=../lib/semgrep-excludes.sh
source "${SCRIPT_DIR}/../lib/semgrep-excludes.sh"

assert_args() {
    local description="$1"
    local input="$2"
    shift 2
    local -a expected=("$@")

    local -a extra=()
    build_semgrep_exclude_args "$input"

    if [ "${#extra[@]}" -ne "${#expected[@]}" ]; then
        echo "FAIL: ${description}: expected ${#expected[@]} arg(s), got ${#extra[@]} (${extra[*]:-})"
        failures=$((failures + 1))
        return
    fi

    local i
    for ((i = 0; i < ${#expected[@]}; i++)); do
        if [ "${extra[$i]}" != "${expected[$i]}" ]; then
            echo "FAIL: ${description}: arg ${i} expected '${expected[$i]}', got '${extra[$i]}'"
            failures=$((failures + 1))
            return
        fi
    done

    echo "PASS: ${description}"
}

# A pattern stays literal even in a tree where it WOULD glob: three matching
# files exist relative to the current directory, and the pattern must still
# reach the array unexpanded and singular. cd (not a subshell) so a failure
# still increments the shared `failures` counter.
work_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "${work_dir}"' EXIT
# Every setup command is guarded rather than relying on `set -e` (which this
# script deliberately doesn't set - see the file header): under plain
# `set -uo pipefail`, a failed `mkdir`/redirect here would leave no matching
# file behind, and the pattern would then pass "literal" only because there
# was nothing left for it to glob against, not because it was kept literal.
mkdir -p "${work_dir}/docs/sub" || exit 1
: > "${work_dir}/docs/a.pdf" || exit 1
: > "${work_dir}/docs/b.pdf" || exit 1
: > "${work_dir}/docs/sub/c.pdf" || exit 1

original_dir="$(pwd)"
cd "${work_dir}" || exit 1
assert_args "glob pattern kept literal in a tree that would glob it" 'docs/*.pdf' --exclude 'docs/*.pdf'
cd "${original_dir}" || exit 1

assert_args "space-separated" 'a b c' --exclude a --exclude b --exclude c
assert_args "newline-separated" "$(printf 'a\nb\nc')" --exclude a --exclude b --exclude c
assert_args "tab-separated" "$(printf 'a\tb\tc')" --exclude a --exclude b --exclude c
assert_args "empty input"  ''

# The function is sourced rather than run in a subshell, so it must not
# trust the CALLER's shell state: a caller with IFS set to newline-only
# (e.g. a line-reading loop) must still get this library's own
# whitespace split, not one silently narrowed to the caller's IFS.
IFS=$'\n' assert_args "space-separated input unaffected by a caller's newline-only IFS" 'a b c' --exclude a --exclude b --exclude c

# A caller that already runs under `set -f` (noglob enabled) must find
# noglob still enabled on return - the pre-call state is restored rather
# than unconditionally cleared, so a caller relying on its own noglob
# does not have it silently switched off by a function it merely sourced.
set -f
extra=()
build_semgrep_exclude_args 'x'
case $- in
    *f*)
        echo "PASS: noglob preserved for a caller that had set -f before calling"
        ;;
    *)
        echo "FAIL: noglob was cleared even though the caller had set -f before calling"
        failures=$((failures + 1))
        ;;
esac
set +f

report_and_exit "exclude-argument tests"
