#!/usr/bin/env bash
# Exercises warn_tracked_archives() (.github/scripts/lib/semgrep-report-check.sh,
# issue #90) - the non-blocking notice for git-tracked archive/container paths
# the pinned Semgrep engine never scans or lists as skipped. Isolated in its
# own file rather than folded into test-semgrep-report-check.sh: that file
# already exercises assert_semgrep_report_complete()'s own repo_root git-case
# machinery at length, and this function shares only the git-repo-per-case
# setup shape, not any of its assertions.
#
# No `set -e`: assert_eq/assert_contains capture failures via the shared
# `failures` counter, and a failing assertion must be counted, not abort the
# run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"
# shellcheck source=../lib/semgrep-report-check.sh
source "${SCRIPT_DIR}/../lib/semgrep-report-check.sh"

work_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "${work_dir}"' EXIT

original_dir="$(pwd)" || exit 1

# The one place that defines the git-case naming scheme, matching
# test-semgrep-report-check.sh's own convention: a fresh directory per case,
# never reused, since a leftover tracked file from an earlier case could
# mask a later one.
git_case_dir() {
    printf '%s' "${work_dir}/git-case-$1"
}

new_git_case() {
    local dir
    dir="$(git_case_dir "$1")"
    mkdir -p "${dir}"
    cd "${dir}" || exit 1
    git init -q
}

# A tracked repo holding no archive-shaped path at all must print nothing and
# return 0 - the common case for the overwhelming majority of repositories,
# and the one this notice must never touch.
git_case_none="$(git_case_dir none)"
new_git_case none
printf 'x' > a.php
printf 'y' > readme.md
finish_git_case "${original_dir}"
none_output="$(warn_tracked_archives "${git_case_none}" 2>&1)"
none_rc=$?
assert_eq "no tracked archive: exits 0" "0" "${none_rc}"
assert_eq "no tracked archive: prints nothing" "" "${none_output}"

# A single tracked .zip is named in a ::notice::, not a ::error:: - this
# function must never fail the job (issue #90's own proposed direction).
git_case_single="$(git_case_dir single)"
new_git_case single
printf 'x' > a.php
printf 'PK' > bundle.zip
finish_git_case "${original_dir}"
single_output="$(warn_tracked_archives "${git_case_single}" 2>&1)"
single_rc=$?
assert_eq "single tracked archive: exits 0" "0" "${single_rc}"
assert_contains "single tracked archive: notice names the archive" \
    "${single_output}" "::notice::" "bundle.zip"
single_error_count="$(printf '%s\n' "${single_output}" | grep -c '^::error::')"
assert_eq "single tracked archive: no ::error:: annotation" "0" "${single_error_count}"

# An ordinary tracked binary asset that is NOT an archive (a .png) must not
# be flagged - this notice is scoped to formats that can bundle or compress
# arbitrary content, not to every git-tracked binary, matching
# assert_semgrep_report_complete()'s own already-accepted media exclusion.
git_case_media="$(git_case_dir media)"
new_git_case media
printf 'x' > a.php
printf '\x89PNG\r\n\x1a\n' > logo.png
finish_git_case "${original_dir}"
media_output="$(warn_tracked_archives "${git_case_media}" 2>&1)"
media_rc=$?
assert_eq "tracked media asset (not an archive): exits 0" "0" "${media_rc}"
assert_eq "tracked media asset (not an archive): prints nothing" "" "${media_output}"

# A git-tracked SYMLINK whose own name ends in a listed extension carries no
# archive content at all - the target is what would need scanning, if
# anything - so it must not be flagged. Without the `-s` mode check this
# reproduces exactly: a caller who already quieted this same symlink via the
# workflow's `excludes` input for the completeness gate above would still
# see this notice fire on it (adversarial-reviewer, GH-90 round 2).
git_case_symlink="$(git_case_dir symlink)"
new_git_case symlink
printf 'x' > target.php
ln -s target.php link.zip
finish_git_case "${original_dir}"
symlink_output="$(warn_tracked_archives "${git_case_symlink}" 2>&1)"
symlink_rc=$?
assert_eq "tracked symlink named like an archive: exits 0" "0" "${symlink_rc}"
assert_eq "tracked symlink named like an archive: prints nothing" "" "${symlink_output}"

# The `120000 | 160000` mode filter has two branches - the symlink case
# above only proves the first. A git-tracked GITLINK (a submodule, mode
# 160000) named like an archive must not be flagged either, proven
# directly rather than assumed from the symlink case (test-quality-reviewer,
# GH-90 push-scope round 1). `--cacheinfo` with the well-known empty-tree
# SHA registers a gitlink entry directly in the index, mirroring
# test-semgrep-report-check.sh's own gitlink fixture - no real submodule is
# needed to stage one.
git_case_gitlink="$(git_case_dir gitlink)"
new_git_case gitlink
printf 'x' > a.php
git add -Af .
git update-index --add --cacheinfo 160000,4b825dc642cb6eb9a060e54bf8d69288fbee4904,vendored.zip
cd "${original_dir}" || exit 1
gitlink_output="$(warn_tracked_archives "${git_case_gitlink}" 2>&1)"
gitlink_rc=$?
assert_eq "tracked gitlink named like an archive: exits 0" "0" "${gitlink_rc}"
assert_eq "tracked gitlink named like an archive: prints nothing" "" "${gitlink_output}"

# A filename merely ENDING in the letters of an extension, without the
# leading dot, must not false-positive (e.g. "quizzip" ends in "zip" but
# names no archive) - proves the match is anchored on the dotted suffix, not
# a bare substring search.
git_case_lookalike="$(git_case_dir lookalike)"
new_git_case lookalike
printf 'x' > quizzip
finish_git_case "${original_dir}"
lookalike_output="$(warn_tracked_archives "${git_case_lookalike}" 2>&1)"
lookalike_rc=$?
assert_eq "dotless extension lookalike: exits 0" "0" "${lookalike_rc}"
assert_eq "dotless extension lookalike: prints nothing" "" "${lookalike_output}"

# The extension match is case-insensitive - a `.ZIP` upload from a
# case-preserving tool must be caught the same as a lowercase one.
git_case_upper="$(git_case_dir upper)"
new_git_case upper
printf 'PK' > BUNDLE.ZIP
finish_git_case "${original_dir}"
upper_output="$(warn_tracked_archives "${git_case_upper}" 2>&1)"
assert_contains "uppercase extension: still detected case-insensitively" \
    "${upper_output}" "::notice::" "BUNDLE.ZIP"

# A compound suffix (.tgz) that does NOT also end in a shorter listed suffix
# (it doesn't end in ".gz" - the character before "gz" is "t", not ".") needs
# its own list entry, proven directly rather than assumed from the .zip case
# above.
git_case_tgz="$(git_case_dir tgz)"
new_git_case tgz
printf 'x' > bundle.tgz
finish_git_case "${original_dir}"
tgz_output="$(warn_tracked_archives "${git_case_tgz}" 2>&1)"
assert_contains "compound suffix .tgz is matched on its own, not via a shorter suffix" \
    "${tgz_output}" "::notice::" "bundle.tgz"

# `git ls-files -s` emits one line per (mode, object, stage), not one per
# path - an unresolved merge conflict on a tracked archive produces THREE
# stage-1/2/3 lines for the same path, which must be named exactly once in
# the notice, not three times. Mirrors test-semgrep-report-check.sh's own
# conflicted-stage fixture for the analogous case in
# assert_semgrep_report_complete() (shell-script-reviewer, GH-90 push-scope
# round 1). `--index-info` stages the conflict directly, without a real
# merge.
git_case_conflict="$(git_case_dir conflict)"
new_git_case conflict
blob1="$(printf 'a' | git hash-object -w --stdin)"
blob2="$(printf 'b' | git hash-object -w --stdin)"
blob3="$(printf 'c' | git hash-object -w --stdin)"
printf '100644 %s 1\tbundle.zip\n100644 %s 2\tbundle.zip\n100644 %s 3\tbundle.zip\n' \
    "${blob1}" "${blob2}" "${blob3}" | git update-index --index-info
cd "${original_dir}" || exit 1
conflict_output="$(warn_tracked_archives "${git_case_conflict}" 2>&1)"
conflict_occurrences="$(printf '%s' "${conflict_output}" | grep -o 'bundle.zip' | wc -l)"
assert_eq "a conflicted-stage archive is named exactly once, not once per stage" "1" "${conflict_occurrences}"

# Two simultaneously tracked archives are both named, joined by exactly one
# %0A - proving the loop visits every hit, not just the first.
git_case_multi="$(git_case_dir multi)"
new_git_case multi
printf 'PK' > a.zip
printf 'PK' > b.jar
finish_git_case "${original_dir}"
multi_output="$(warn_tracked_archives "${git_case_multi}" 2>&1)"
assert_contains_in_order "two tracked archives: both named, in git ls-files order" \
    "${multi_output}" "a.zip%0Ab.jar"

# A raw newline in a tracked path must not split the notice into a second,
# unattributed log line - the same forgery class assert_semgrep_report_complete()
# guards against, via the same shared sanitize_for_annotation() helper.
git_case_newline="$(git_case_dir newline)"
new_git_case newline
newline_name="$(printf 'evil\nname.zip')"
printf 'PK' > "${newline_name}"
finish_git_case "${original_dir}"
newline_output="$(warn_tracked_archives "${git_case_newline}" 2>&1)"
newline_line_count="$(printf '%s\n' "${newline_output}" | wc -l)"
assert_eq "a raw newline in a tracked archive's path stays one notice line" "1" "${newline_line_count}"
assert_contains "a raw newline in a tracked archive's path is folded, not dropped" \
    "${newline_output}" "::notice::" "evil name.zip"

# `repo_root` pointing at a directory that is not a git repository at all
# degrades to a ::warning:: and still returns 0 - this check must never turn
# an environment problem into a failed job.
git_case_not_a_repo="$(git_case_dir not-a-repo)"
mkdir -p "${git_case_not_a_repo}"
not_a_repo_output="$(warn_tracked_archives "${git_case_not_a_repo}" 2>&1)"
not_a_repo_rc=$?
assert_eq "non-git repo_root: exits 0 rather than failing the job" "0" "${not_a_repo_rc}"
assert_contains "non-git repo_root: prints a ::warning::, not a ::notice:: or ::error::" \
    "${not_a_repo_output}" "::warning::" "git ls-files"

# mktemp failing closed still returns 0 with its own ::warning:: - mirrors
# test-semgrep-report-check.sh's identical shadowed-mktemp technique for
# assert_semgrep_report_complete()'s own first mktemp call.
mktemp() {
    return 1
}
mktemp_failure_output="$(warn_tracked_archives "${git_case_none}" 2>&1)"
mktemp_failure_rc=$?
unset -f mktemp
assert_eq "mktemp failure: exits 0 rather than failing the job" "0" "${mktemp_failure_rc}"
assert_contains "mktemp failure: prints its own ::warning::" \
    "${mktemp_failure_output}" "::warning::" "temp file"

# warn_tracked_archives() has one `rm -f ... || true` guard of its own (the
# success continuation right after `hits` is built; re-derive with
# `awk '/^warn_tracked_archives\(\)/,/^}/' ../lib/semgrep-report-check.sh |
# grep -c 'rm -f .*|| true'` -> 1) plus the one inside the shared
# _git_tracked_entries_tempfile() helper it calls (the git-ls-files-failure
# branch, shared with assert_semgrep_report_complete() - already exercised
# from that side by test-semgrep-report-check.sh's own rm-shadow cases, but
# proven again here from THIS function's own call perspective, since a
# regression in how warn_tracked_archives() propagates the helper's failure
# would not be caught by the sibling suite at all). Both are untested by
# every case above: each drives the function via `$(...)` capture in a
# script that never sets `-e`, which cannot exercise either guard - command
# substitution does not propagate errexit into itself, so an unguarded `rm`
# failure there wouldn't abort anything even without `|| true`. The real
# production caller (code-scanning.yml) invokes the function as a bare
# statement under `set -euo pipefail`. Mutation-confirmed: removing either
# `|| true` left every case above green while a real `set -e` caller
# aborted silently before its own diagnostic ever printed - drives the
# shared run_under_shadowed_rm() from lib/harness.sh, the same helper
# test-semgrep-report-check.sh uses for assert_semgrep_report_complete()'s
# analogous guards (generalised across files per simplicity-reviewer,
# GH-90).
LIB_FILE="${SCRIPT_DIR}/../lib/semgrep-report-check.sh"

rm_guard_failure_output="$(run_under_shadowed_rm "${LIB_FILE}" warn_tracked_archives "${git_case_not_a_repo}")"
rm_guard_failure_rc=$?
assert_eq "git_ls_files_file rm -f failure on the git-ls-files-failed branch still exits 0 under a real set -e caller" \
    "0" "${rm_guard_failure_rc}"
assert_contains "git_ls_files_file rm -f failure on the git-ls-files-failed branch still prints its own ::warning:: under a real set -e caller" \
    "${rm_guard_failure_output}" "::warning::" "git ls-files"

rm_guard_success_output="$(run_under_shadowed_rm "${LIB_FILE}" warn_tracked_archives "${git_case_single}")"
rm_guard_success_rc=$?
assert_eq "git_ls_files_file rm -f failure on the success continuation still exits 0 under a real set -e caller" \
    "0" "${rm_guard_success_rc}"
assert_contains "git_ls_files_file rm -f failure on the success continuation still prints the notice under a real set -e caller" \
    "${rm_guard_success_output}" "::notice::" "bundle.zip"

# The rm-guard tests above only prove the `rm -f "$git_ls_files_file" || true`
# line survives an `rm` FAILURE, not that it runs at all on a genuinely
# successful call - deleting the whole line (not just its `|| true`) would
# leak a temp file on every run and leave every case in this file green
# (test-quality-reviewer, GH-90 round 4). Mirrors
# test-semgrep-report-check.sh's own assert_no_tmp_leak() coverage for the
# analogous line in assert_semgrep_report_complete(); the shared helper and
# its TMPDIR-scoped scan-directory rationale live in lib/harness.sh.
tmp_scan_dir="${work_dir}/tmp-scan"
mkdir -p "${tmp_scan_dir}"
assert_no_tmp_leak "${tmp_scan_dir}" "git_ls_files_file does not survive a successful warn_tracked_archives call" \
    warn_tracked_archives "${git_case_single}"

report_and_exit "warn_tracked_archives suite"
