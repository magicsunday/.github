#!/usr/bin/env bash
# Exercises run_with_retry() (.github/scripts/lib/retry.sh), the function
# code-scanning.yml sources to retry the Semgrep invocation once on a
# transient registry-fetch failure without conflating it with a genuine scan
# error (see issue #44 for why the two cannot be told apart by exit code).
# Run via run-tests.sh.
#
# No `set -e`: assertions capture exit codes themselves, and a failing
# assertion must be counted, not abort the run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/retry.sh
source "${SCRIPT_DIR}/../lib/retry.sh"

failures=0

# Overrides the real `sleep` so a test that forces several retries runs
# instantly instead of actually waiting — a bash function takes precedence
# over the PATH binary of the same name, and run_with_retry calls `sleep`
# unqualified, so this reaches it without any change to the library itself.
sleep_calls=()
sleep() {
    sleep_calls+=("$1")
}

# Fails on every invocation before the calls_before_success-th one, then
# succeeds — or fails on every invocation when calls_before_success is 0.
# Tracks its own call count in CALLS, independent of RETRY_ATTEMPTS, so a
# test can assert the underlying command actually stopped being retried
# rather than looping forever.
CALLS=0
flaky() {
    local calls_before_success="$1"
    CALLS=$((CALLS + 1))

    if [ "${calls_before_success}" -eq 0 ]; then
        return 9
    fi

    if [ "${CALLS}" -ge "${calls_before_success}" ]; then
        return 0
    fi

    return 3
}

reset() {
    CALLS=0
    sleep_calls=()
}

assert_eq() {
    local description="$1"
    local expected="$2"
    local actual="$3"

    if [ "${expected}" != "${actual}" ]; then
        echo "FAIL: ${description}: expected '${expected}', got '${actual}'"
        failures=$((failures + 1))
        return
    fi

    echo "PASS: ${description}"
}

reset
export RETRY_BACKOFF_SECONDS=0
rc=0
run_with_retry flaky 1 || rc=$?
assert_eq "succeeds first try: exit code" 0 "${rc}"
assert_eq "succeeds first try: RETRY_ATTEMPTS" 1 "${RETRY_ATTEMPTS}"
assert_eq "succeeds first try: underlying command ran once" 1 "${CALLS}"
assert_eq "succeeds first try: no sleep" 0 "${#sleep_calls[@]}"

reset
export RETRY_BACKOFF_SECONDS=0
rc=0
run_with_retry flaky 2 || rc=$?
assert_eq "fails once then succeeds: exit code" 0 "${rc}"
assert_eq "fails once then succeeds: RETRY_ATTEMPTS" 2 "${RETRY_ATTEMPTS}"
assert_eq "fails once then succeeds: underlying command ran twice" 2 "${CALLS}"
assert_eq "fails once then succeeds: slept exactly once" 1 "${#sleep_calls[@]}"

reset
export RETRY_BACKOFF_SECONDS=0
rc=0
run_with_retry flaky 0 || rc=$?
assert_eq "fails every time: exit code is the last attempt's" 9 "${rc}"
assert_eq "fails every time: RETRY_ATTEMPTS stops at the two-attempt budget" 2 "${RETRY_ATTEMPTS}"
assert_eq "fails every time: underlying command ran twice, not endlessly" 2 "${CALLS}"
assert_eq "fails every time: slept once, not after the exhausted final attempt" 1 "${#sleep_calls[@]}"

# The default backoff (5s) is asserted through the stubbed `sleep`'s recorded
# argument rather than a real wait, so this stays as fast as every other case
# here while still pinning the actual default value.
reset
unset RETRY_BACKOFF_SECONDS
rc=0
run_with_retry flaky 2 || rc=$?
assert_eq "default backoff used when RETRY_BACKOFF_SECONDS is unset: exit code" 0 "${rc}"
assert_eq "default backoff used when RETRY_BACKOFF_SECONDS is unset: sleep argument" 5 "${sleep_calls[0]}"

if [ "${failures}" -gt 0 ]; then
    echo "${failures} failure(s)."
    exit 1
fi

echo "All retry tests passed."
