#!/usr/bin/env bash
# Sourced by zizmor.yml's "Verify .github/zizmor.yml matches the canonical
# copy" step and by .github/scripts/tests/test-canonical-file-guard.sh, so
# the workflow and its test drive the same file rather than two copies that
# can drift apart.

# Compares the caller repository's .github/zizmor.yml (checked out at the
# job's own workspace root) against the canonical copy at
# "$1/.github/zizmor.yml" - a directory the reusable workflow already checks
# out via job.workflow_repository/job.workflow_sha for every consumer, on
# every run. Returns non-zero, with an actionable ::error:: annotation, when
# the caller's .github/zizmor.yml (or its containing .github directory) is
# a symlink, is missing, or differs byte-for-byte.
#
# .github/zizmor.yml declares that first-party reusable workflows track
# @main by policy - without it (or with a stale copy) the unpinned-uses
# zizmor audit falls back to its blanket hash-pin rule and reports every
# reusable-workflow reference as a finding (verified 2026-09-02 against
# https://docs.zizmor.sh/audits/#unpinned-uses - that default has changed
# once already, in zizmor v1.20.0, so re-check the docs rather than
# trusting this comment if it ever looks stale). This happened once
# (issue #38):
# a newly created repository was the only one of 22 without the file, and
# it surfaced only through manual alert triage.
#
# Checked at the GATE that actually depends on the file, not via a separate
# cross-repo sweep: the canonical FILE this function compares against is its
# own manifest - no separate list of "which files are canonical" to keep in
# sync, and no extra token/cross-repo read scope beyond the checkout this
# workflow already performs.
assert_canonical_zizmor_config() {
    local canonical_dir="$1"
    local canonical_url="https://github.com/magicsunday/.github/blob/main/.github/zizmor.yml"

    if [ ! -f "${canonical_dir}/.github/zizmor.yml" ]; then
        echo "::error::Could not verify .github/zizmor.yml against the canonical copy - the checked-out canonical source at '${canonical_dir}/.github/zizmor.yml' does not exist. This is a defect in the reusable workflow's own checkout, not in the calling repository."
        return 1
    fi

    # Rejected before the -f/cmp checks below, which both follow symlinks: a
    # caller could otherwise point .github/zizmor.yml - or the .github
    # directory itself - at "${canonical_dir}/.github" (or a file inside
    # it), making the comparison trivially pass against its own target.
    # [ -L .github/zizmor.yml ] alone would miss the directory-symlink case:
    # lstat only inspects the final path component, so a symlinked .github
    # with a real zizmor.yml file inside it is not itself detected.
    if [ -L .github ] || [ -L .github/zizmor.yml ]; then
        echo "::error file=.github/zizmor.yml::.github/zizmor.yml is a symlink, or the .github directory containing it is. It must be a real file inside a real directory, not a link to the checked-out canonical copy or anywhere else. Replace it with a real copy from ${canonical_url}"
        return 1
    fi

    if [ ! -f .github/zizmor.yml ]; then
        echo "::error file=.github/zizmor.yml::.github/zizmor.yml is missing. Without it, the unpinned-uses zizmor audit falls back to a stricter default that flags every reusable-workflow reference (see this file's own docblock for the anchored claim about what that default is). Copy the canonical file from ${canonical_url}"
        return 1
    fi

    if ! cmp -s .github/zizmor.yml "${canonical_dir}/.github/zizmor.yml"; then
        echo "::error file=.github/zizmor.yml::.github/zizmor.yml differs from the canonical copy in magicsunday/.github. A stale or locally-edited copy can silently change which reusable-workflow references the unpinned-uses zizmor audit flags. Sync it from ${canonical_url}"
        return 1
    fi

    return 0
}
