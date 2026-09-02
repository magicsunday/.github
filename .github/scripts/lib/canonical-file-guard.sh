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
# the caller's copy is missing or differs byte-for-byte.
#
# .github/zizmor.yml declares that first-party reusable workflows track
# @main by policy - without it (or with a stale copy) the unpinned-uses
# zizmor audit falls back to its blanket hash-pin rule and reports every
# reusable-workflow reference as a finding. This happened once (issue #38):
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

    if [ ! -f "${canonical_dir}/.github/zizmor.yml" ]; then
        echo "::error::Could not verify .github/zizmor.yml against the canonical copy - the checked-out canonical source at '${canonical_dir}/.github/zizmor.yml' does not exist. This is a defect in the reusable workflow's own checkout, not in the calling repository."
        return 1
    fi

    if [ ! -f .github/zizmor.yml ]; then
        echo "::error file=.github/zizmor.yml::.github/zizmor.yml is missing. It declares that first-party reusable workflows track @main by policy - without it, the unpinned-uses zizmor audit falls back to its blanket hash-pin rule and reports every reusable-workflow reference as a finding. Copy the canonical file from https://github.com/magicsunday/.github/blob/main/.github/zizmor.yml"
        return 1
    fi

    if ! cmp -s .github/zizmor.yml "${canonical_dir}/.github/zizmor.yml"; then
        echo "::error file=.github/zizmor.yml::.github/zizmor.yml differs from the canonical copy in magicsunday/.github. A stale or locally-edited copy can silently change which reusable-workflow references the unpinned-uses zizmor audit flags. Sync it from https://github.com/magicsunday/.github/blob/main/.github/zizmor.yml"
        return 1
    fi

    return 0
}
