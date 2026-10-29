#!/usr/bin/env bash
# Runs the "Decide whether the check applies" step of i18n.yml against a real
# merge commit, so the choice between running and skipping the core overlap
# check is covered in both directions. A pull request that changes a catalogue
# or the composer file runs it, one that changes neither skips it, and every
# other event and every failure to list the changes runs it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/i18n.yml"

# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# Extract the run block of the step, the way the runner would execute it.
python3 - "${WORKFLOW}" "${workdir}/step.sh" <<'EOF' || { echo "FAIL: cannot extract the step"; exit 1; }
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)

job = workflow["jobs"]["core-overlap-scope"]
step = [s for s in job["steps"] if s.get("id") == "scope"][0]

with open(sys.argv[2], "w", encoding="utf-8") as handle:
    handle.write(step["run"])

# The checkout reaches the first parent of the merge commit and only runs for a pull request.
checkout = [s for s in job["steps"] if s.get("uses", "").startswith("actions/checkout@")][0]
assert checkout["with"]["fetch-depth"] == 2, "fetch-depth"
assert checkout["if"].strip() == "${{ github.event_name == 'pull_request' }}", "checkout gate"
assert job["outputs"]["relevant"] == "${{ steps.scope.outputs.relevant }}", "output"
EOF

# Builds a caller repository whose HEAD is a merge commit of a base commit and a
# branch commit, like the checkout of a pull request. Arguments: the files the
# branch commit adds, one per word.
build_merge() {
    local repo="${workdir}/repo"

    rm -rf "${repo}"
    git init -q -b main "${repo}"
    git -C "${repo}" config user.email test@example.invalid
    git -C "${repo}" config user.name test
    git -C "${repo}" config commit.gpgsign false
    mkdir -p "${repo}/resources/lang/de" "${repo}/src"
    echo base > "${repo}/README.md"
    git -C "${repo}" add -A
    git -C "${repo}" commit -q -m base
    git -C "${repo}" switch -q -c topic
    local changed
    for changed in "$@"; do
        mkdir -p "${repo}/$(dirname "${changed}")"
        echo changed > "${repo}/${changed}"
    done
    git -C "${repo}" add -A
    git -C "${repo}" commit -q -m topic
    git -C "${repo}" switch -q main
    echo more >> "${repo}/README.md"
    git -C "${repo}" commit -q -am "base moved"
    git -C "${repo}" merge -q --no-ff -m merge topic
}

# Runs the step. Arguments: event name, language directory. The result is left
# in $output_file as the content of GITHUB_OUTPUT and in $rc.
run_step() {
    local event="$1" lang_dir="${2-resources/lang}"

    output_file="${workdir}/github-output"
    : > "${output_file}"
    (cd "${workdir}/repo" && EVENT_NAME="${event}" LANG_DIR="${lang_dir}" GITHUB_OUTPUT="${output_file}" bash "${workdir}/step.sh" > "${workdir}/log" 2>&1)
    rc=$?
}

assert_relevant() {
    # assert_relevant DESCRIPTION EXPECTED
    local value
    value="$(grep '^relevant=' "${output_file}" | tail -n 1)"
    if [ "${rc}" -ne 0 ]; then
        value="exit ${rc}: $(cat "${workdir}/log")"
    fi
    assert_eq "$1" "relevant=$2" "${value}"
}

build_merge resources/lang/de/messages.po
run_step pull_request
assert_relevant "a changed catalogue runs the check" true

build_merge composer.json
run_step pull_request
assert_relevant "a changed composer file runs the check" true

build_merge src/Thing.php package-lock.json
run_step pull_request
assert_relevant "a pull request that changes neither skips the check" false

build_merge resources/language-notes.txt
run_step pull_request
assert_relevant "a path that only shares the prefix of the language directory skips the check" false

build_merge docs/composer.json
run_step pull_request
assert_relevant "a composer file below another directory skips the check" false

build_merge i18n/de/messages.po
run_step pull_request i18n/
assert_relevant "a custom language directory with a trailing slash is honoured" true

build_merge i18n/de/messages.po
run_step pull_request ./i18n
assert_relevant "a custom language directory with a leading dot slash is honoured" true

build_merge .github/workflows/i18n.yml
run_step pull_request
assert_relevant "a changed workflow file runs the check because it can set the core tags" true

build_merge .github/dependabot.yml
run_step pull_request
assert_relevant "a file next to the workflows skips the check" false

build_merge src/Thing.php
run_step pull_request .
assert_relevant "catalogues at the repository root cannot be told apart, so every pull request runs the check" true

run_step pull_request ''
assert_relevant "an empty language directory runs the check" true

build_merge $'resources/lang/de/\303\251.po'
run_step pull_request
assert_relevant "a catalogue path with a non-ASCII name still runs the check" true

build_merge $'resources/lang/de/tab\there.po'
run_step pull_request
assert_relevant "a catalogue path with a tab in its name still runs the check" true

build_merge src/Thing.php
run_step push
assert_relevant "a push always runs the check" true

run_step workflow_dispatch
assert_relevant "a manual run always runs the check" true

# A checkout that has no parent cannot list the changes, so the check runs.
rm -rf "${workdir}/repo"
git init -q -b main "${workdir}/repo"
git -C "${workdir}/repo" config user.email test@example.invalid
git -C "${workdir}/repo" config user.name test
git -C "${workdir}/repo" config commit.gpgsign false
echo one > "${workdir}/repo/README.md"
git -C "${workdir}/repo" add -A
git -C "${workdir}/repo" commit -q -m only
run_step pull_request
assert_relevant "a checkout without a parent runs the check" true
assert_contains "the fallback is announced" "$(cat "${workdir}/log")" "Could not list the changed files"

report_and_exit "i18n core overlap scope tests"
