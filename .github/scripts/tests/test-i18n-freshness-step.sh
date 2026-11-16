#!/usr/bin/env bash
# Runs the "Assert the catalogue is up to date" step of the pipeline job in
# i18n.yml against a scratch caller repository with staged changes, so the
# shell around i18n_only_references_changed() is covered: each outcome, its
# summary text, and the removal of the shared checkout before the decision.
# The comparison itself is covered by test-i18n-freshness.sh. The step that
# claims the path of the shared checkout is covered here as well.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/i18n.yml"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

work_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "${work_dir}"' EXIT
original_dir="$(pwd)" || exit 1

# Extract the run block of each step, the way the runner would execute it.
workflow_step_run "${WORKFLOW}" "Assert the catalogue is up to date" > "${work_dir}/step.sh" || { echo "FAIL: cannot extract the step"; exit 1; }
workflow_step_run "${WORKFLOW}" "Check the shared-checkout preconditions" > "${work_dir}/preconditions.sh" || { echo "FAIL: cannot extract the preconditions step"; exit 1; }

# run_step NAME
# Creates a caller repository with one committed catalogue, applies the
# change that the caller of this function makes through the CHANGE variable,
# stages it like the previous step does and runs the extracted step with the
# shared checkout in place. The result is left in $out, $rc, $summary and
# $shared_left.
run_step() {
    local caller="${work_dir}/$1"

    mkdir -p "${caller}/resources/lang/nl" || exit 1
    cd "${caller}" || exit 1
    git init --quiet . || exit 1
    git config user.email "test@example.invalid"
    git config user.name "Test"
    git config commit.gpgsign false
    printf '#: src/Module.php:10\nmsgid "Open"\nmsgstr "Openen"\n' > resources/lang/nl/messages.po
    git add -A
    git commit --quiet -m "Add the catalogue" || exit 1

    eval "${CHANGE}"
    git add -A

    ln -s "${REPO_ROOT}" .magicsunday-shared
    : > "${work_dir}/summary.md"
    out="$(GITHUB_STEP_SUMMARY="${work_dir}/summary.md" bash "${work_dir}/step.sh" 2>&1)"
    rc=$?
    summary="$(cat "${work_dir}/summary.md")"
    shared_left="no"
    if [ -e .magicsunday-shared ] || [ -L .magicsunday-shared ]; then
        shared_left="yes"
    fi
    cd "${original_dir}" || exit 1
}

CHANGE=':'
run_step nothing-staged
assert_eq "nothing staged: passes" "0" "${rc}"
assert_contains "nothing staged: the summary names the no-op" "${summary}" "make lang\` is a no-op"
assert_eq "nothing staged: the shared checkout is removed" "no" "${shared_left}"

CHANGE="sed -i 's|Module.php:10|Module.php:12|' resources/lang/nl/messages.po"
run_step moved-references
assert_eq "moved references: passes" "0" "${rc}"
assert_contains "moved references: the summary names the case" "${summary}" "only moved source references"
assert_eq "moved references: the shared checkout is removed" "no" "${shared_left}"

CHANGE="sed -i 's|Openen|Opent|' resources/lang/nl/messages.po"
run_step stale-catalogue
assert_eq "stale catalogue: fails" "1" "${rc}"
assert_contains "stale catalogue: the error annotation is printed" "${out}" "::error::make lang produced changes"
assert_contains "stale catalogue: the diff is printed" "${out}" "+msgstr \"Opent\""
assert_contains "stale catalogue: the summary lists the changes" "${summary}" "### Changes"
assert_eq "stale catalogue: the shared checkout is removed" "no" "${shared_left}"

# run_preconditions REPOSITORY SHA
# Runs the preconditions step in a fresh caller directory. The directory is
# prepared by the caller of this function through the PREPARE variable. The
# result is left in $out and $rc.
run_preconditions() {
    local caller="${work_dir}/preconditions-case"

    rm -rf "${caller}"
    mkdir -p "${caller}" || exit 1
    cd "${caller}" || exit 1
    eval "${PREPARE}"
    out="$(WORKFLOW_REPOSITORY="$1" WORKFLOW_SHA="$2" bash "${work_dir}/preconditions.sh" 2>&1)"
    rc=$?
    cd "${original_dir}" || exit 1
}

PREPARE=':'
run_preconditions "magicsunday/.github" "abc123"
assert_eq "preconditions: both values set and the path free passes" "0" "${rc}"

run_preconditions "" "abc123"
assert_eq "preconditions: an empty repository fails" "1" "${rc}"
assert_contains "preconditions: the empty repository is named" "${out}" "job.workflow_repository is empty"

run_preconditions "magicsunday/.github" ""
assert_eq "preconditions: an empty sha fails" "1" "${rc}"
assert_contains "preconditions: the empty sha is named" "${out}" "job.workflow_sha is empty"

PREPARE=': > .magicsunday-shared'
run_preconditions "magicsunday/.github" "abc123"
assert_eq "preconditions: a claimed path as a file fails" "1" "${rc}"
assert_contains "preconditions: the claimed path is named" "${out}" ".magicsunday-shared"

PREPARE='ln -s /nonexistent-target .magicsunday-shared'
run_preconditions "magicsunday/.github" "abc123"
assert_eq "preconditions: a claimed path as a dangling symlink fails" "1" "${rc}"

report_and_exit "i18n freshness step tests"
