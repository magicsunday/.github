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

assert_args "newline-separated" "$(printf 'a\nb\nc')" --exclude a --exclude b --exclude c
assert_args "empty input"  ''

# A git-tracked path containing a literal space could not previously be
# expressed as a single --exclude pattern, since the space itself was a
# split point (issue #89) - a space no longer splits, so the whole line
# survives as one pattern.
assert_args "a pattern with a literal space stays one pattern, not two" 'my link.php' --exclude 'my link.php'
assert_args "a pattern with a literal tab stays one pattern, not two" "$(printf 'my\tlink.php')" --exclude "$(printf 'my\tlink.php')"
assert_args "space-separated input is NOT split (only newline is a delimiter now)" 'a b c' --exclude 'a b c'
assert_args "tab-separated input is NOT split (only newline is a delimiter now)" "$(printf 'a\tb\tc')" --exclude "$(printf 'a\tb\tc')"

# The old whitespace-IFS split absorbed a line holding ONLY spaces/tabs for
# free (it was itself all-delimiter). The newline-only split does not, so a
# stray blank-looking line in a hand-typed YAML block scalar - unlike a
# genuinely empty line, which still collapses via newline-adjacency - would
# otherwise survive as a literal `--exclude '   '` argument whose effect on
# Semgrep is unverified here (shell-script-reviewer, GH-89).
assert_args "a whitespace-only line is skipped, not passed through as a pattern" "$(printf 'a\n   \nb')" --exclude a --exclude b
assert_args "a pattern that is non-empty only because of trailing whitespace still passes trimmed-but-original" 'a  ' --exclude 'a  '

# The function is sourced rather than run in a subshell, so it must not
# trust the CALLER's shell state: a caller with IFS set to space (e.g. a
# word-splitting context) must still get this library's own newline-only
# split, not one silently widened to the caller's IFS.
IFS=' ' assert_args "newline-separated input unaffected by a caller's space IFS" "$(printf 'a\nb\nc')" --exclude a --exclude b --exclude c

# The mirror of the noglob-restoration check below: this file is SOURCED
# (per its own header comment), not run in a subshell, so a dropped `local`
# on `IFS=$'\n'` would leak the function's own IFS into the caller's shell
# after it returns - every existing assertion above still passes even with
# `local` removed, since the function unconditionally re-sets IFS on ENTRY
# regardless of the caller's own value, masking the leak during the call
# itself (test-quality-reviewer, mutation-confirmed, GH-89). Only checking
# the caller's IFS AFTER the call, once the function has returned, catches
# it.
IFS=' '
extra=()
build_semgrep_exclude_args "$(printf 'a\nb')"
if [ "$IFS" = ' ' ]; then
    echo "PASS: caller's IFS is restored after the call, not left at the function's own value"
else
    echo "FAIL: caller's IFS leaked to '${IFS}' after the call"
    failures=$((failures + 1))
fi
IFS=$' \t\n'

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
