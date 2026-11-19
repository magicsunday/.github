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
CWD_LOG="${WORK_DIR}/cwds.log"
ENV_LOG="${WORK_DIR}/envs.log"

# Exit status of the stubbed subcommands, set per case.
STUB_UPDATE_STATUS=0
STUB_AUDIT_STATUS=0

composer() {
    echo "$*" >> "${CALL_LOG}"
    pwd -P >> "${CWD_LOG}"
    echo "${COMPOSER-unset}" >> "${ENV_LOG}"
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

# The workflow passes its `working-directory` input to the function through an
# environment variable and not by splicing it into the script text. A caller
# that leaves the input out audits the repository root.
wiring_status=0
# shellcheck disable=SC2016
wiring="$(python3 -I - "${audit_workflow}" << 'PY' 2> /dev/null
import sys
import yaml

document = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
declared = (document.get("on") or document.get(True))["workflow_call"]["inputs"]["working-directory"]
steps = document["jobs"]["composer-audit"]["steps"]
step = [s for s in steps if s.get("name") == "Audit the Composer dependencies"][0]
call_wired = 'composer_audit_run "${AUDIT_DIRECTORY}"' in step["run"]
spliced = "inputs.working-directory" in step["run"]
print(declared["type"], declared["required"], declared["default"], step["env"]["AUDIT_DIRECTORY"], call_wired, spliced)
PY
)" || wiring_status=$?
assert_eq 'the working-directory input of the workflow can be read' '0' "${wiring_status}"
# shellcheck disable=SC2016
assert_eq 'the input is optional, defaults to the root and reaches the function through the environment' \
    'string False . ${{ inputs.working-directory }} True False' "${wiring}"

# The step runs with the input in its environment, sources the library from the
# shared checkout, removes that checkout and then calls the function with the
# input. A stand-in library records the argument, so a step that never reaches
# the call, or reaches it without the input, is seen.
step_script="${WORK_DIR}/audit-step.sh"
step_status=0
python3 -I - "${audit_workflow}" > "${step_script}" 2> /dev/null << 'PY' || step_status=$?
import sys
import yaml

document = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = document["jobs"]["composer-audit"]["steps"]
print([s for s in steps if s.get("name") == "Audit the Composer dependencies"][0]["run"])
PY
assert_eq 'the audit step of the workflow can be read' '0' "${step_status}"

run_step() {
    local directory="$1" manifest="${2-composer.json}" step_dir
    step_dir="$(mktemp -d "${WORK_DIR}/step.XXXXXX")"
    mkdir -p "${step_dir}/.magicsunday-shared/.github/scripts/lib"
    # The stand-in function is written literally, its variables expand when the step calls it.
    # shellcheck disable=SC2016
    printf '%s\n' 'composer_audit_run() { printf "%s" "$1" > "${STEP_ARGUMENT_FILE}"; printf "%s" "$2" > "${STEP_ARGUMENT_FILE}.manifest"; if [ -e "${STEP_ARGUMENT_FILE%/*}/.magicsunday-shared" ]; then echo yes; else echo no; fi > "${STEP_ARGUMENT_FILE}.shared"; }' \
        > "${step_dir}/.magicsunday-shared/.github/scripts/lib/composer-audit.sh"
    step_status=0
    (cd "${step_dir}" && AUDIT_DIRECTORY="${directory}" AUDIT_FILE="${manifest}" STEP_ARGUMENT_FILE="${step_dir}/argument" bash "${step_script}" > /dev/null 2>&1) || step_status=$?
    step_argument="$(cat "${step_dir}/argument" 2> /dev/null || echo 'NOT CALLED')"
    step_manifest="$(cat "${step_dir}/argument.manifest" 2> /dev/null || echo 'NOT CALLED')"
    step_shared_left="$([ -e "${step_dir}/.magicsunday-shared" ] && echo yes || echo no)"
    step_shared_at_call="$(cat "${step_dir}/argument.shared" 2> /dev/null || echo 'NOT CALLED')"
}

run_step "setup/release"
assert_eq 'the audit step passes' '0' "${step_status}"
assert_eq 'the audit step hands the input to the function' 'setup/release' "${step_argument}"
assert_eq 'the audit step removes the shared checkout before the audit' 'no' "${step_shared_left}"
assert_eq 'the shared checkout is already gone when the audit function runs' 'no' "${step_shared_at_call}"

run_step "."
assert_eq 'the audit step hands the default to the function' '.' "${step_argument}"
assert_eq 'the audit step hands the default manifest to the function' 'composer.json' "${step_manifest}"

run_step "setup" "composer-core-2.2.json"
assert_eq 'the audit step hands the manifest file to the function' 'composer-core-2.2.json' "${step_manifest}"
assert_eq 'the audit step hands the folder next to the manifest file to the function' 'setup' "${step_argument}"

# --- The directory to audit ---

# Like run_case, but the function gets the directory to audit as its argument.
# Also sets `case_cwds` (the directories the stubbed composer ran in, one per
# line without duplicates), `case_root` (the resolved case directory) and
# `case_after` (the directory the caller stood in after the call).
run_directory_case() {
    local prepare="$1" directory="$2"
    local case_dir
    case_dir="$(mktemp -d "${WORK_DIR}/case.XXXXXX")"
    : > "${CALL_LOG}"
    : > "${CWD_LOG}"
    "${prepare}" "${case_dir}"
    case_root="$(cd "${case_dir}" && pwd -P)"
    case_status=0
    case_output="$(cd "${case_dir}" && if [ -n "${CASE_CDPATH_SUB:-}" ]; then export CDPATH="${case_dir}/${CASE_CDPATH_SUB}"; fi && composer_audit_run "${directory}" 2>&1)" || case_status=$?
    case_calls="$(cat "${CALL_LOG}")"
    case_cwds="$(sort -u "${CWD_LOG}")"
    # The call runs in the current shell, so the directory afterwards is the
    # one the function leaves behind.
    case_after="$(cd "${case_dir}" && { composer_audit_run "${directory}" > /dev/null 2>&1 || true; pwd -P; })"
}

prepare_folder_with_lock() {
    mkdir -p "$1/setup/release"
    echo '{}' > "$1/setup/release/composer.json"
    echo '{"packages": []}' > "$1/setup/release/composer.lock"
}

prepare_folder_without_manifest() {
    mkdir -p "$1/setup/release"
}

prepare_root_and_folder_manifests() {
    echo '{}' > "$1/composer.json"
    echo '{"packages": []}' > "$1/composer.lock"
    mkdir -p "$1/setup"
    echo '{}' > "$1/setup/composer.json"
}

prepare_folder_that_is_a_file() {
    : > "$1/setup"
}

prepare_folder_symlinked_outside() {
    local outside
    outside="$(mktemp -d "${WORK_DIR}/outside.XXXXXX")"
    echo '{}' > "${outside}/composer.json"
    echo '{"packages": []}' > "${outside}/composer.lock"
    ln -s "${outside}" "$1/setup"
}

prepare_folder_with_leading_dash() {
    mkdir -p "$1/-x"
    echo '{}' > "$1/-x/composer.json"
    echo '{"packages": []}' > "$1/-x/composer.lock"
}

# A directory whose name ends in a line break, next to a link of the same name
# without it that leads out of the repository. Such a name is refused, because
# a path that lost the line break would name the link.
prepare_folder_next_to_outside_link() {
    local outside
    outside="$(mktemp -d "${WORK_DIR}/outside.XXXXXX")"
    echo '{}' > "${outside}/composer.json"
    echo '{"packages": []}' > "${outside}/composer.lock"
    mkdir "$1/"$'real\n'
    echo '{}' > "$1/"$'real\n'/composer.json
    echo '{"packages": []}' > "$1/"$'real\n'/composer.lock
    ln -s "${outside}" "$1/real"
    ln -s $'real\n' "$1/setup"
}

# The same folder name below the repository and below a directory that a
# CDPATH names, which `cd` would search first.
prepare_folder_in_repository_and_cdpath() {
    local folder
    for folder in "$1/setup" "$1/alternate/setup"; do
        mkdir -p "${folder}"
        echo '{}' > "${folder}/composer.json"
        echo '{"packages": []}' > "${folder}/composer.lock"
    done
}

# A link to a directory next to the repository whose name starts with the name
# of the repository.
prepare_folder_symlinked_to_sibling() {
    mkdir -p "$1"2
    echo '{}' > "$1"2/composer.json
    echo '{"packages": []}' > "$1"2/composer.lock
    ln -s "$1"2 "$1/setup"
}

# A link to a directory below the repository whose name holds an accented
# letter, which a range of letters accepts in some locales.
prepare_folder_symlinked_to_accented_directory() {
    mkdir -p "$1/real/é"
    echo '{}' > "$1/real/é/composer.json"
    echo '{"packages": []}' > "$1/real/é/composer.lock"
    ln -s real/é "$1/setup"
}

prepare_folder_that_cannot_be_entered() {
    mkdir -p "$1/setup"
    echo '{}' > "$1/setup/composer.json"
    chmod 000 "$1/setup"
}

prepare_folder_symlinked_inside() {
    mkdir -p "$1/real"
    echo '{}' > "$1/real/composer.json"
    echo '{"packages": []}' > "$1/real/composer.lock"
    ln -s real "$1/setup"
}

run_directory_case prepare_folder_with_lock "setup/release"
assert_eq 'a folder with a lock file passes when the audit passes' '0' "${case_status}"
assert_eq 'the folder is audited as locked' 'audit --locked --no-scripts --no-plugins --no-interaction' "${case_calls}"
assert_eq 'composer runs inside the folder' "${case_root}/setup/release" "${case_cwds}"
assert_eq 'the caller stays in its own directory' "${case_root}" "${case_after}"

run_directory_case prepare_folder_with_lock "setup/release/"
assert_eq 'a trailing slash names the same folder' "${case_root}/setup/release" "${case_cwds}"

run_directory_case prepare_root_and_folder_manifests "setup"
assert_eq 'the manifest of the folder is audited and not the one at the root' "${case_root}/setup" "${case_cwds}"
assert_eq 'a folder without a lock file is resolved fresh' \
    $'update --no-install --no-scripts --no-plugins --no-interaction --no-progress --ignore-platform-reqs\naudit --locked --no-scripts --no-plugins --no-interaction' \
    "${case_calls}"

run_directory_case prepare_root_and_folder_manifests ""
assert_eq 'an empty folder names the repository root' "${case_root}" "${case_cwds}"

run_directory_case prepare_root_and_folder_manifests "."
assert_eq 'a dot names the repository root' "${case_root}" "${case_cwds}"

run_directory_case prepare_folder_without_manifest "setup/release"
assert_eq 'a folder without a composer.json fails' '1' "${case_status}"
assert_contains 'a folder without a composer.json names the folder' "${case_output}" 'setup/release'
assert_contains 'a folder without a composer.json is reported as an error' "${case_output}" 'holds no composer.json'
assert_eq 'a folder without a composer.json runs no composer command' '' "${case_calls}"

run_directory_case prepare_no_composer_json "does/not/exist"
assert_eq 'a folder that does not exist fails' '1' "${case_status}"
assert_contains 'a folder that does not exist is reported as an error' "${case_output}" '::error::'
assert_eq 'a folder that does not exist runs no composer command' '' "${case_calls}"

run_directory_case prepare_folder_that_is_a_file "setup"
assert_eq 'a folder that is a file fails' '1' "${case_status}"
assert_contains 'a folder that is a file is refused as no directory' "${case_output}" 'not a directory'
assert_eq 'a folder that is a file runs no composer command' '' "${case_calls}"

run_directory_case prepare_folder_with_lock "/etc"
assert_eq 'an absolute folder fails' '1' "${case_status}"
assert_contains 'an absolute folder is refused as no plain folder name' "${case_output}" 'may only use'
assert_eq 'an absolute folder runs no composer command' '' "${case_calls}"

run_directory_case prepare_folder_with_lock $'setup\n::warning::injected'
assert_eq 'a folder with a line break fails' '1' "${case_status}"
assert_contains 'a folder with a line break is refused as no plain folder name' "${case_output}" 'may only use'
assert_eq 'a folder with a line break never reaches the log' '0' "$(grep -c 'injected' <<<"${case_output}" || true)"
assert_eq 'a folder with a line break runs no composer command' '' "${case_calls}"

run_directory_case prepare_folder_with_lock "setup/../setup/release"
assert_eq 'a folder with a parent segment fails' '1' "${case_status}"
assert_contains 'a folder with a parent segment is refused for the segment' "${case_output}" 'parent segment'
assert_eq 'a folder with a parent segment runs no composer command' '' "${case_calls}"

run_directory_case prepare_folder_with_lock ".."
assert_eq 'the parent folder fails' '1' "${case_status}"
assert_contains 'the parent folder is refused for the segment' "${case_output}" 'parent segment'
assert_eq 'the parent folder runs no composer command' '' "${case_calls}"

run_directory_case prepare_folder_symlinked_outside "setup"
assert_eq 'a folder that is a link to a place outside the repository fails' '1' "${case_status}"
assert_contains 'a folder that is a link to a place outside the repository is refused for leaving it' "${case_output}" 'leads out of the repository'
assert_eq 'a folder that is a link to a place outside the repository runs no composer command' '' "${case_calls}"

run_directory_case prepare_folder_with_leading_dash "-x"
assert_eq 'a folder that starts with a dash is refused' '1' "${case_status}"
assert_contains 'a folder that starts with a dash is refused as no plain folder name' "${case_output}" 'may only use'
assert_eq 'a folder that starts with a dash runs no composer command' '' "${case_calls}"

run_directory_case prepare_folder_with_lock "setup release"
assert_eq 'a folder with a space is refused' '1' "${case_status}"
assert_contains 'a folder with a space is refused as no plain folder name' "${case_output}" 'may only use'
assert_eq 'a folder with a space runs no composer command' '' "${case_calls}"

run_directory_case prepare_folder_next_to_outside_link "setup"
assert_eq 'a folder that leads to a name with a line break fails' '1' "${case_status}"
assert_contains 'a folder that leads to a name with a line break is refused for the name' "${case_output}" 'outside the supported characters'
assert_eq 'a folder that leads to a name with a line break runs no composer command' '' "${case_calls}"

# A root user enters a mode 000 directory, so this case only means something
# for any other user.
if [ "$(id -u)" -ne 0 ]; then
    run_directory_case prepare_folder_that_cannot_be_entered "setup"
    chmod 755 "${case_root}/setup" 2> /dev/null || true
    assert_eq 'a folder that cannot be entered fails' '1' "${case_status}"
    assert_contains 'a folder that cannot be entered is reported as an error' "${case_output}" '::error::The folder to audit cannot be entered.'
    assert_eq 'a folder that cannot be entered runs no composer command' '' "${case_calls}"
else
    echo 'SKIP: a folder that cannot be entered (running as root)'
fi

CASE_CDPATH_SUB=alternate run_directory_case prepare_folder_in_repository_and_cdpath "setup"
assert_eq 'a folder is looked up in the repository and not through CDPATH' "${case_root}/setup" "${case_cwds}"

run_directory_case prepare_folder_symlinked_to_sibling "setup"
assert_eq 'a link to a sibling whose name starts with the repository name fails' '1' "${case_status}"
assert_contains 'a link to such a sibling is refused for leaving the repository' "${case_output}" 'leads out of the repository'

LC_ALL=en_US.UTF-8 run_directory_case prepare_folder_symlinked_to_accented_directory "setup"
assert_eq 'a link to an accented directory is refused in any locale' '1' "${case_status}"
assert_contains 'a link to an accented directory is refused for the name' "${case_output}" 'outside the supported characters'

LC_ALL=en_US.UTF-8 run_directory_case prepare_folder_with_lock "é"
assert_eq 'a folder with an accented letter is refused in any locale' '1' "${case_status}"
assert_contains 'a folder with an accented letter is refused as no plain folder name' "${case_output}" 'may only use'

run_directory_case prepare_folder_symlinked_inside "setup"
assert_eq 'a folder that is a link inside the repository is audited' '0' "${case_status}"
assert_eq 'a link inside the repository is followed to its target' "${case_root}/real" "${case_cwds}"

STUB_AUDIT_STATUS=1
run_directory_case prepare_folder_with_lock "setup/release"
assert_eq 'a failing audit of a folder fails the check' '1' "${case_status}"
STUB_AUDIT_STATUS=0

# A caller whose working directory is reached through a link still audits a
# valid folder. The function resolves the workspace physically, so the
# containment check compares physical paths on both sides.
linked_case_dir="$(mktemp -d "${WORK_DIR}/linked.XXXXXX")"
prepare_folder_with_lock "${linked_case_dir}"
ln -s "${linked_case_dir}" "${WORK_DIR}/work-link"
: > "${CALL_LOG}"
: > "${CWD_LOG}"
linked_status=0
(cd "${WORK_DIR}/work-link" && composer_audit_run "setup/release" > /dev/null 2>&1) || linked_status=$?
linked_cwds="$(sort -u "${CWD_LOG}")"
assert_eq 'a folder is audited when the working directory is reached through a link' '0' "${linked_status}"
assert_eq 'composer runs inside the folder of a working directory reached through a link' \
    "$(cd "${linked_case_dir}" && pwd -P)/setup/release" "${linked_cwds}"

# A dot with a slash names the repository root like a folder, so it needs a
# composer.json, while a dot or an empty input tolerates a root without one.
run_directory_case prepare_root_and_folder_manifests "./"
assert_eq 'a dot with a slash names the repository root' "${case_root}" "${case_cwds}"

run_directory_case prepare_folder_without_manifest "./"
assert_eq 'a dot with a slash needs a composer.json at the root' '1' "${case_status}"
assert_contains 'a dot with a slash without a composer.json is reported as an error' "${case_output}" 'holds no composer.json'

# --- The manifest file to audit ---

# The input `composer-file` is optional, a string and defaults to composer.json,
# and it reaches the function through the environment like the folder does.
file_wiring_status=0
# shellcheck disable=SC2016
file_wiring="$(python3 -I - "${audit_workflow}" << 'PY' 2> /dev/null
import sys
import yaml

document = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
declared = (document.get("on") or document.get(True))["workflow_call"]["inputs"]["composer-file"]
steps = document["jobs"]["composer-audit"]["steps"]
step = [s for s in steps if s.get("name") == "Audit the Composer dependencies"][0]
call_wired = 'composer_audit_run "${AUDIT_DIRECTORY}" "${AUDIT_FILE}"' in step["run"]
spliced = "inputs.composer-file" in step["run"]
print(declared["type"], declared["required"], declared["default"], step["env"]["AUDIT_FILE"], call_wired, spliced)
PY
)" || file_wiring_status=$?
assert_eq 'the composer-file input of the workflow can be read' '0' "${file_wiring_status}"
# shellcheck disable=SC2016
assert_eq 'the input is optional, defaults to composer.json and reaches the function through the environment' \
    'string False composer.json ${{ inputs.composer-file }} True False' "${file_wiring}"

# Like run_directory_case, but the function also gets the manifest file name.
# Sets `case_envs` too, the manifest settings of Composer that the stubbed
# composer saw, one per line without duplicates.
run_manifest_case() {
    local prepare="$1" directory="$2" manifest="$3"
    local case_dir
    case_dir="$(mktemp -d "${WORK_DIR}/case.XXXXXX")"
    : > "${CALL_LOG}"
    : > "${CWD_LOG}"
    : > "${ENV_LOG}"
    "${prepare}" "${case_dir}"
    case_root="$(cd "${case_dir}" && pwd -P)"
    case_status=0
    case_output="$(cd "${case_dir}" && composer_audit_run "${directory}" "${manifest}" 2>&1)" || case_status=$?
    case_calls="$(cat "${CALL_LOG}")"
    case_cwds="$(sort -u "${CWD_LOG}")"
    case_envs="$(sort -u "${ENV_LOG}")"
}

prepare_named_manifest() {
    mkdir -p "$1/setup"
    echo '{}' > "$1/setup/composer-core-2.2.json"
}

prepare_named_manifest_with_lock() {
    prepare_named_manifest "$1"
    echo '{"packages": []}' > "$1/setup/composer-core-2.2.lock"
}

prepare_named_manifest_with_the_default_lock() {
    prepare_named_manifest "$1"
    echo '{"packages": []}' > "$1/setup/composer.lock"
}

prepare_named_manifest_with_symlinked_lock() {
    prepare_named_manifest "$1"
    echo '{"packages": []}' > "$1/setup/real.lock"
    ln -s real.lock "$1/setup/composer-core-2.2.lock"
}

prepare_named_manifest_with_underscore() {
    mkdir -p "$1/setup"
    echo '{}' > "$1/setup/_composer.json"
}

prepare_named_manifest_at_the_root() {
    echo '{}' > "$1/composer-core-2.2.json"
}

prepare_default_manifest_only() {
    mkdir -p "$1/setup"
    echo '{}' > "$1/setup/composer.json"
}

fresh_calls='update --no-install --no-scripts --no-plugins --no-interaction --no-progress --ignore-platform-reqs
audit --locked --no-scripts --no-plugins --no-interaction'
locked_calls='audit --locked --no-scripts --no-plugins --no-interaction'

run_manifest_case prepare_named_manifest "setup" "composer-core-2.2.json"
assert_eq 'a named manifest without a lock file is resolved fresh and audited' '0' "${case_status}"
assert_eq 'the fresh resolution of a named manifest runs the same commands as for composer.json' "${fresh_calls}" "${case_calls}"
assert_eq 'every Composer command of a named manifest reads that file' 'composer-core-2.2.json' "${case_envs}"
assert_eq 'a named manifest is audited in its folder' "${case_root}/setup" "${case_cwds}"

run_manifest_case prepare_named_manifest_with_lock "setup" "composer-core-2.2.json"
assert_eq 'a named manifest with a committed lock file passes' '0' "${case_status}"
assert_eq 'the lock file that belongs to the named manifest is audited as it is' "${locked_calls}" "${case_calls}"
assert_eq 'the audit of the lock file of a named manifest reads that manifest' 'composer-core-2.2.json' "${case_envs}"

run_manifest_case prepare_named_manifest_with_the_default_lock "setup" "composer-core-2.2.json"
assert_eq 'the lock file of composer.json does not belong to a named manifest' "${fresh_calls}" "${case_calls}"

run_manifest_case prepare_named_manifest_with_symlinked_lock "setup" "composer-core-2.2.json"
assert_eq 'a symlinked lock file of a named manifest fails' '1' "${case_status}"
assert_eq 'a symlinked lock file of a named manifest runs no composer command' '' "${case_calls}"

run_manifest_case prepare_named_manifest_at_the_root "." "composer-core-2.2.json"
assert_eq 'a named manifest at the repository root is audited' '0' "${case_status}"
assert_eq 'a named manifest at the repository root reads that file' 'composer-core-2.2.json' "${case_envs}"

run_manifest_case prepare_default_manifest_only "setup" "composer-core-2.2.json"
assert_eq 'a named manifest that does not exist fails' '1' "${case_status}"
assert_eq 'a missing named manifest runs no composer command' '' "${case_calls}"
assert_contains 'a missing named manifest is reported as an error' "${case_output}" 'holds no manifest file of that name'

run_manifest_case prepare_named_manifest_at_the_root "." "composer.json"
assert_eq 'the default manifest name at a root without composer.json still passes' '0' "${case_status}"
assert_contains 'the default manifest name at a root without composer.json says there is nothing to audit' "${case_output}" 'nothing to audit'

run_manifest_case prepare_default_manifest_only "setup" ""
assert_eq 'an empty manifest name means composer.json' '0' "${case_status}"
assert_eq 'an empty manifest name audits composer.json' 'composer.json' "${case_envs}"

# Only a plain file name is supported. Every other name is refused before any
# Composer command runs, and the message does not name it, so a line break in a
# name cannot reach the log as a workflow command.
refuse_manifest_name() {
    local name="$1" label="$2"
    run_manifest_case prepare_named_manifest "setup" "${name}"
    assert_eq "the manifest name ${label} is refused" '1' "${case_status}"
    assert_eq "the manifest name ${label} runs no composer command" '' "${case_calls}"
    assert_contains "the manifest name ${label} is reported as an error" "${case_output}" '::error::The manifest file'
}
run_manifest_case prepare_named_manifest_with_underscore "setup" "_composer.json"
assert_eq 'a manifest name that starts with an underscore is audited' '0' "${case_status}"
assert_eq 'a manifest name that starts with an underscore is read by every Composer command' '_composer.json' "${case_envs}"

run_manifest_case prepare_named_manifest "setup" "zzmarker!.json"
case_marker_hits="$(grep -c 'zzmarker' <<< "${case_output}" || true)"
assert_eq 'the error for a refused manifest name does not repeat the name' '0' "${case_marker_hits}"

refuse_manifest_name '../composer.json' 'with a parent segment'
refuse_manifest_name 'sub/composer.json' 'with a slash'
refuse_manifest_name 'composer.txt' 'without the extension json'
refuse_manifest_name '.json' 'that is only the extension'
refuse_manifest_name '-composer.json' 'with a leading dash'
refuse_manifest_name 'compo ser.json' 'with a space'
refuse_manifest_name $'composer.json\n::error::x' 'with a line break'
refuse_manifest_name 'cömposer.json' 'with an accented letter'
refuse_manifest_name 'composer.json ' 'with a trailing space'

report_and_exit 'composer-audit tests'
