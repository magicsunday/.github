#!/usr/bin/env bash
# Exercises build_semgrep_exclude_args() (.github/scripts/lib/semgrep-excludes.sh),
# the function code-scanning.yml sources to turn its `excludes` input into
# Semgrep `--exclude` arguments. Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/semgrep-excludes.sh
source "${SCRIPT_DIR}/../lib/semgrep-excludes.sh"

failures=0

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
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
mkdir -p "${work_dir}/docs/sub"
: > "${work_dir}/docs/a.pdf"
: > "${work_dir}/docs/b.pdf"
: > "${work_dir}/docs/sub/c.pdf"

original_dir="$(pwd)"
cd "${work_dir}" || exit 1
assert_args "glob pattern kept literal in a tree that would glob it" 'docs/*.pdf' --exclude 'docs/*.pdf'
cd "${original_dir}" || exit 1

assert_args "space-separated" 'a b c' --exclude a --exclude b --exclude c
assert_args "newline-separated" "$(printf 'a\nb\nc')" --exclude a --exclude b --exclude c
assert_args "tab-separated" "$(printf 'a\tb\tc')" --exclude a --exclude b --exclude c
assert_args "empty input"  ''

if [ "${failures}" -gt 0 ]; then
    echo "${failures} failure(s)."
    exit 1
fi

echo "All exclude-argument tests passed."
