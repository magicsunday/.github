#!/usr/bin/env bash
# Sourced by code-scanning.yml's "Run Semgrep" step and by
# .github/scripts/tests/test-retry.sh, so the workflow and its test drive the
# same file rather than two copies that can drift apart.

# Runs "$@" up to two times total, stopping at the first success. Sleeps
# RETRY_BACKOFF_SECONDS (default 5, override to 0 in tests) between attempts,
# so a transient outage in whatever "$@" talks to has a moment to clear
# before the next try — never after the last attempt, whether that one
# succeeded or exhausted the budget. Returns the LAST attempt's exit code; a
# caller that wants to know whether a retry happened reads RETRY_ATTEMPTS
# afterwards, since the exit code alone cannot distinguish a single success
# from a success after one retry.
#
# The attempt budget is not configurable: its only value would be a knob
# nothing sets, since every caller here retries at most once. A configurable
# RETRY_MAX_ATTEMPTS also needs its own input validation — a non-integer
# value makes the loop's own `-ge` exit check fail on every iteration, so a
# permanently failing command retries forever — and that validation has no
# reason to exist for a value nothing ever supplies. Hardcoding the budget
# removes the bug class instead of guarding it.
#
# "$@" is invoked directly rather than via a subshell, so a function defined
# in the calling script (e.g. one that deletes stale output before each try)
# is visible to it exactly as it would be to a direct call — no `export -f`
# needed, because this stays in the same shell process throughout.
run_with_retry() {
    local max_attempts=2
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
