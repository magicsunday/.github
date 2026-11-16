#!/usr/bin/env bash
# Runs the "Assert the catalogue is up to date" step of the pipeline job in
# i18n.yml against a scratch caller repository with staged changes, so the
# shell around i18n_only_references_changed() is covered: each outcome, its
# summary text, and the removal of the shared checkout before the decision. The comparison itself is covered by test-i18n-freshness.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/i18n.yml"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

work_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "${work_dir}"' EXIT
original_dir="$(pwd)" || exit 1

# Extract the run block of the step, the way the runner would execute it.
python3 - "${WORKFLOW}" "${work_dir}/step.sh" <<'EOF' || { echo "FAIL: cannot extract the step"; exit 1; }
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)

steps = workflow["jobs"]["pipeline"]["steps"]
step = [s for s in steps if s.get("name") == "Assert the catalogue is up to date"][0]

with open(sys.argv[2], "w", encoding="utf-8") as handle:
    handle.write(step["run"])
EOF

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

report_and_exit "i18n freshness step tests"
