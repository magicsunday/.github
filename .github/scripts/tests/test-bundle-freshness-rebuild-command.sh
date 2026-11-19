#!/usr/bin/env bash
# Runs the rebuild script of bundle-freshness.yml for real, with stand-ins for
# the tools it calls, and checks the command that the failure message prints.
# The job runs the script as root on a runner, where nobody reads the owner of
# the files. A maintainer who runs the printed command locally gets files that
# belong to root unless the command passes the owner and the script hands the
# tree back, also when the build fails halfway.
#
# The script is cut from the step "Rebuild the bundle and assert it is up to
# date", from the line that opens its variable to the line that closes it. The
# printed command is the echo line of the failure summary, run with the same
# variables the step sets.
#
# Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/bundle-freshness.yml"

require_files_or_bail "bundle freshness rebuild command test" "${WORKFLOW_FILE}"

WORK_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "${WORK_DIR}"' EXIT

BUILD_STEP="Rebuild the bundle and assert it is up to date"
workflow_step_run "${WORKFLOW_FILE}" "${BUILD_STEP}" >"${WORK_DIR}/build-step.sh" || exit 1

awk '/^BUILD_SCRIPT=\$\(cat <<.BUILD_SCRIPT_END.$/ {on = 1; next} /^BUILD_SCRIPT_END$/ {on = 0} on' \
    "${WORK_DIR}/build-step.sh" >"${WORK_DIR}/build-script.sh"
grep -F 'echo "docker run --rm' "${WORK_DIR}/build-step.sh" >"${WORK_DIR}/printed-command.sh"
assert_nonempty "$(cat "${WORK_DIR}/build-script.sh")" "rebuild script cut from the step"
assert_nonempty "$(cat "${WORK_DIR}/printed-command.sh")" "printed command cut from the step"

STUB_DIR="${WORK_DIR}/stubs"
mkdir -p "${STUB_DIR}"
for tool in apk git npm chown; do
    cat >"${STUB_DIR}/${tool}" <<'STUB'
#!/bin/sh
echo "$(basename "$0") $*" >>"${STUB_LOG}"
[ -z "${STUB_FAIL:-}" ] || [ "$(basename "$0") $1" != "${STUB_FAIL}" ] || exit 1
STUB
    chmod +x "${STUB_DIR}/${tool}"
done

# Runs the cut script with the stand-ins first on the path. The first
# argument is the owner the printed command would pass, empty for the job's
# own run, and the second names a stand-in call that fails.
run_script() {
    : >"${WORK_DIR}/calls.log"
    PATH="${STUB_DIR}:${PATH}" STUB_LOG="${WORK_DIR}/calls.log" STUB_FAIL="${2:-}" \
        OWNER="$1" sh "${WORK_DIR}/build-script.sh" >/dev/null 2>&1
    rc=$?
    calls="$(cat "${WORK_DIR}/calls.log")"
}

run_script ""
assert_eq "the job's own run: the build succeeds" "0" "${rc}"
assert_contains "the job's own run: the tools are called" "${calls}" "npm ci" "npm run prepare"
case "${calls}" in
    *chown*) _harness_fail "the job's own run: the owner stays as it is" "${calls}" ;;
    *) echo "PASS: the job's own run: the owner stays as it is" ;;
esac

run_script "1000:1000"
assert_eq "a local run with an owner: the build succeeds" "0" "${rc}"
assert_contains_in_order "a local run with an owner: the tree is handed back after the build" \
    "${calls}" "npm run prepare" "chown -R 1000:1000 /app"

run_script "1000:1000" "npm run"
assert_eq "a local run whose build fails: the failure is kept" "1" "${rc}"
assert_contains "a local run whose build fails: the tree is still handed back" "${calls}" "chown -R 1000:1000 /app"

# The printed command is run with the variables of the step, so what the
# maintainer sees is what is tested. The job's own run keeps its form.
printed="$(NODE_IMAGE=example/node:1 BUILD_SCRIPT="set -e" bash "${WORK_DIR}/printed-command.sh")"
assert_contains_in_order "the printed command passes the owner of the caller before the mount" \
    "${printed}" 'docker run --rm' '-e OWNER="$(id -u):$(id -g)"' '-v "$PWD":/app' "example/node:1"
assert_contains "the job's own run passes no owner" "$(cat "${WORK_DIR}/build-step.sh")" \
    'docker run --rm -v "$PWD":/app -w /app "$NODE_IMAGE" sh -c "$BUILD_SCRIPT"'

report_and_exit "bundle freshness rebuild command tests"
