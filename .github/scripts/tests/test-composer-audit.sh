#!/usr/bin/env bash
# Exercises composer_audit_run() (.github/scripts/lib/composer-audit.sh), the
# function composer-audit.yml sources to decide which Composer commands audit
# a repository. Run via run-tests.sh.
#
# `composer` is replaced by a bash function that records its arguments, so no
# network and no Composer install is needed. A function takes precedence over
# the PATH binary of the same name, and the library calls `composer`
# unqualified. What the real Composer does with the audit settings of a
# composer.json is Composer's own behaviour, so the test pins the other half:
# the library passes no ignore option of its own and leaves the settings to
# the command it runs.
#
# No `set -e`: assertions capture exit codes themselves, and a failing
# assertion must be counted, not abort the run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"
# shellcheck source=../lib/composer-audit.sh
source "${SCRIPT_DIR}/../lib/composer-audit.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
CALL_LOG="${WORK_DIR}/calls.log"

# Exit status of the stubbed subcommands, set per case.
STUB_UPDATE_STATUS=0
STUB_AUDIT_STATUS=0

composer() {
    echo "$*" >> "${CALL_LOG}"
    case "$1" in
        update) return "${STUB_UPDATE_STATUS}" ;;
        audit) return "${STUB_AUDIT_STATUS}" ;;
    esac
    return 99
}

# Runs composer_audit_run in a fresh empty directory prepared by the function
# named in "$1" (it receives the directory as its argument). Sets
# `case_status`, `case_output` and `case_calls`.
run_case() {
    local prepare="$1"
    local case_dir
    case_dir="$(mktemp -d "${WORK_DIR}/case.XXXXXX")"
    : > "${CALL_LOG}"
    "${prepare}" "${case_dir}"
    case_status=0
    case_output="$(cd "${case_dir}" && composer_audit_run 2>&1)" || case_status=$?
    case_calls="$(cat "${CALL_LOG}")"
}

prepare_no_composer_json() {
    : # the directory stays empty
}

prepare_json_only() {
    echo '{}' > "$1/composer.json"
}

prepare_json_and_lock() {
    echo '{}' > "$1/composer.json"
    echo '{"packages": []}' > "$1/composer.lock"
}

prepare_json_and_empty_lock() {
    echo '{}' > "$1/composer.json"
    : > "$1/composer.lock"
}

prepare_json_and_symlinked_lock() {
    echo '{}' > "$1/composer.json"
    echo '{"packages": []}' > "$1/real.lock"
    ln -s real.lock "$1/composer.lock"
}

prepare_json_and_dangling_lock() {
    echo '{}' > "$1/composer.json"
    ln -s missing.lock "$1/composer.lock"
}

prepare_json_and_lock_directory() {
    echo '{}' > "$1/composer.json"
    mkdir "$1/composer.lock"
}

prepare_json_and_unreadable_lock() {
    echo '{}' > "$1/composer.json"
    echo '{"packages": []}' > "$1/composer.lock"
    chmod 000 "$1/composer.lock"
}

prepare_json_with_ignore_settings() {
    cat > "$1/composer.json" << 'JSON'
{
    "config": {
        "audit": {"ignore": ["CVE-2000-0001"]},
        "policy": {"advisories": {"ignore-id": ["PKSA-aaaa-bbbb-cccc"]}}
    }
}
JSON
    echo '{"packages": []}' > "$1/composer.lock"
}

prepare_dangling_json() {
    ln -s missing.json "$1/composer.json"
}

STUB_UPDATE_STATUS=0
STUB_AUDIT_STATUS=0

run_case prepare_no_composer_json
assert_eq 'no composer.json passes' '0' "${case_status}"
assert_eq 'no composer.json runs no composer command' '' "${case_calls}"
assert_contains 'no composer.json says there is nothing to audit' "${case_output}" 'nothing to audit'

run_case prepare_json_and_lock
assert_eq 'a committed lock file passes when the audit passes' '0' "${case_status}"
assert_eq 'a committed lock file is audited as locked and not resolved' 'audit --locked --no-scripts --no-plugins --no-interaction' "${case_calls}"

# The audit of the repository must not run its own composer scripts or plugins,
# on either path, because the job reads a repository that is not trusted. The
# exact command lines of the cases around this comment pin both flags.
run_case prepare_json_only
assert_eq 'no lock file passes when the audit passes' '0' "${case_status}"
assert_eq 'no lock file resolves without installing, then audits the lock' \
    $'update --no-install --no-scripts --no-plugins --no-interaction --no-progress --ignore-platform-reqs\naudit --locked --no-scripts --no-plugins --no-interaction' \
    "${case_calls}"

run_case prepare_dangling_json
assert_eq 'a dangling composer.json symlink counts as present and is not skipped' \
    $'update --no-install --no-scripts --no-plugins --no-interaction --no-progress --ignore-platform-reqs\naudit --locked --no-scripts --no-plugins --no-interaction' \
    "${case_calls}"

run_case prepare_json_and_empty_lock
assert_eq 'an empty lock file fails' '1' "${case_status}"
assert_eq 'an empty lock file runs no composer command' '' "${case_calls}"
assert_contains 'an empty lock file names composer.lock' "${case_output}" '::error::composer.lock is not a regular'

run_case prepare_json_and_symlinked_lock
assert_eq 'a symlinked lock file fails' '1' "${case_status}"
assert_eq 'a symlinked lock file runs no composer command' '' "${case_calls}"

run_case prepare_json_and_dangling_lock
assert_eq 'a dangling lock symlink fails' '1' "${case_status}"
assert_eq 'a dangling lock symlink runs no composer command' '' "${case_calls}"

run_case prepare_json_and_lock_directory
assert_eq 'a directory named composer.lock fails' '1' "${case_status}"
assert_eq 'a directory named composer.lock runs no composer command' '' "${case_calls}"

# A root user reads a mode 000 file, so the unreadable case only means
# something for any other user.
if [ "$(id -u)" -ne 0 ]; then
    run_case prepare_json_and_unreadable_lock
    assert_eq 'an unreadable lock file fails' '1' "${case_status}"
    assert_eq 'an unreadable lock file runs no composer command' '' "${case_calls}"
else
    echo 'SKIP: an unreadable lock file (running as root)'
fi

STUB_AUDIT_STATUS=1
run_case prepare_json_and_lock
assert_eq 'a failing audit of a committed lock file fails the check' '1' "${case_status}"

run_case prepare_json_only
assert_eq 'a failing audit of a fresh resolution fails the check' '1' "${case_status}"

STUB_AUDIT_STATUS=0
STUB_UPDATE_STATUS=2
run_case prepare_json_only
assert_eq 'a failing resolution fails the check with its status' '2' "${case_status}"
assert_eq 'a failing resolution never reaches the audit' \
    'update --no-install --no-scripts --no-plugins --no-interaction --no-progress --ignore-platform-reqs' "${case_calls}"

STUB_UPDATE_STATUS=0
run_case prepare_json_with_ignore_settings
assert_eq 'a repository with audit and policy ignore settings is audited unchanged' \
    'audit --locked --no-scripts --no-plugins --no-interaction' "${case_calls}"

# The default PHP version of the audit workflow is the first version of the
# build matrix of php-quality.yml, as the README says, so the audit runs on the
# version that every consumer's build runs first.
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
# Prints the audit default and the first matrix entry, space separated. It
# exits non-zero when either file or key cannot be read, so the caller can tell
# an unreadable input from two equal values.
workflow_php_defaults() {
    python3 -I - "$1" "$2" << 'PY'
import json
import sys
import yaml

def inputs(path):
    document = yaml.safe_load(open(path, encoding="utf-8"))
    # PyYAML reads the bare key `on` as the boolean True.
    return (document.get("on") or document.get(True))["workflow_call"]["inputs"]

audit = inputs(sys.argv[1])["php-version"]["default"]
matrix = json.loads(inputs(sys.argv[2])["php-versions"]["default"])[0]
# A null or empty default would print as text and still compare equal.
for value in (audit, matrix):
    if not isinstance(value, str) or not value:
        sys.exit("not a PHP version: %r" % (value,))
print(audit, matrix)
PY
}

audit_workflow="${REPO_ROOT}/.github/workflows/composer-audit.yml"
quality_workflow="${REPO_ROOT}/.github/workflows/php-quality.yml"

pair_status=0
pair="$(workflow_php_defaults "${audit_workflow}" "${quality_workflow}" 2> /dev/null)" || pair_status=$?
assert_eq 'the php-version defaults of both workflows can be read' '0' "${pair_status}"
read -r audit_default matrix_first <<< "${pair}"
assert_nonempty "${audit_default}" 'the php-version default of composer-audit.yml was read'
assert_nonempty "${matrix_first}" 'the first php-quality.yml matrix entry was read'
assert_eq 'the php-version default of composer-audit.yml is the first php-quality.yml matrix entry' \
    "${matrix_first}" "${audit_default}"

# An unreadable workflow must be reported and not read as two empty values.
missing_status=0
workflow_php_defaults "${WORK_DIR}/absent.yml" "${quality_workflow}" > /dev/null 2>&1 || missing_status=$?
assert_eq 'a missing workflow file makes the reader fail' '1' "${missing_status}"

report_and_exit 'composer-audit tests'
