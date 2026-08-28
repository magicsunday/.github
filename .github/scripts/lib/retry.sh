#!/usr/bin/env bash
# Sourced by code-scanning.yml's "Run Semgrep" step and by
# .github/scripts/tests/test-retry.sh, so the workflow and its test drive the
# same file rather than two copies that can drift apart.

# Runs "$@" up to RETRY_MAX_ATTEMPTS times (default 2), stopping at the first
# success. Sleeps RETRY_BACKOFF_SECONDS (default 5, override to 0 in tests)
# between attempts, so a transient outage in whatever "$@" talks to has a
# moment to clear before the next try — never after the last attempt, whether
# that one succeeded or exhausted the budget. Returns the LAST attempt's exit
# code; a caller that wants to know whether a retry happened reads
# RETRY_ATTEMPTS afterwards, since the exit code alone cannot distinguish a
# single success from a success after one retry.
#
# "$@" is invoked directly rather than via a subshell, so a function defined
# in the calling script (e.g. one that deletes stale output before each try)
# is visible to it exactly as it would be to a direct call — no `export -f`
# needed, because this stays in the same shell process throughout.
run_with_retry() {
    local max_attempts="${RETRY_MAX_ATTEMPTS:-2}"
    local backoff="${RETRY_BACKOFF_SECONDS:-5}"
    local rc=0

    RETRY_ATTEMPTS=1
    while :; do
        rc=0
        "$@" || rc=$?

        if [ "$rc" -eq 0 ] || [ "$RETRY_ATTEMPTS" -ge "$max_attempts" ]; then
            return "$rc"
        fi

        RETRY_ATTEMPTS=$((RETRY_ATTEMPTS + 1))
        sleep "$backoff"
    done
}
