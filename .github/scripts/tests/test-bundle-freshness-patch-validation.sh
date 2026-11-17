#!/usr/bin/env bash
# Runs the decisions of the bundle push in bundle-freshness.yml for real. The
# build job runs package scripts, so the patch it hands to the job that holds
# the write token is untrusted, and the checks here are what stands between a
# forged patch and the push. A text pin cannot see a check that is still in
# the file but lets a case through, a run can.
#
# Each decision is cut from the real step, so a change that moves or drops it
# fails here instead of passing unseen:
#   - the validation of the patch, in the step "Commit the rebuilt bundle and
#     push it", from the comment on the untrusted patch to the comment that
#     opens the commit identity. It applies the patch to the index and checks
#     the result, so each case leaves the index clean again,
#   - the check that the branch still is the head commit of the run, in the
#     same step, from the remote line to the comment on the validation,
#   - the hand-over of the patch, in the step "Rebuild the bundle and assert
#     it is up to date", from its comment to the error line.
# The conditions that select a pull request are Actions expressions that no
# shell runs, so they are compared in full as text.
#
# Run via run-tests.sh. Needs PyYAML, which lint.yml's shell-tests job
# installs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/bundle-freshness.yml"

require_files_or_bail "bundle freshness push test" "${WORKFLOW_FILE}"

WORK_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "${WORK_DIR}"' EXIT

PUSH_STEP="Commit the rebuilt bundle and push it"
BUILD_STEP="Rebuild the bundle and assert it is up to date"

workflow_step_run "${WORKFLOW_FILE}" "${PUSH_STEP}" >"${WORK_DIR}/push-step.sh" || exit 1
workflow_step_run "${WORKFLOW_FILE}" "${BUILD_STEP}" >"${WORK_DIR}/build-step.sh" || exit 1

awk '/^# The build ran package scripts/ {on = 1} /^# The commit is made as/ {on = 0} on' "${WORK_DIR}/push-step.sh" >"${WORK_DIR}/validation.sh"
awk '/^remote=/ {on = 1} /^# The build ran package scripts/ {on = 0} on' "${WORK_DIR}/push-step.sh" >"${WORK_DIR}/moved-check.sh"
awk '/^# Hand the change to the push job/ {on = 1} /^echo "::error::The committed/ {on = 0} on' "${WORK_DIR}/build-step.sh" >"${WORK_DIR}/handover.sh"
# A workflow without this step must fail an assertion below and not stop the test here.
workflow_step_run "${WORKFLOW_FILE}" "Check that a push token is present" >"${WORK_DIR}/token-check.sh" 2>/dev/null || : >"${WORK_DIR}/token-check.sh"
assert_nonempty "$(cat "${WORK_DIR}/validation.sh")" "validation cut from the step"
assert_nonempty "$(cat "${WORK_DIR}/moved-check.sh")" "branch check cut from the step"
assert_nonempty "$(cat "${WORK_DIR}/handover.sh")" "hand-over cut from the step"
assert_nonempty "$(cat "${WORK_DIR}/token-check.sh")" "token check step"

REPO_DIR="${WORK_DIR}/repo"
git init -q "${REPO_DIR}" || exit 1
cd "${REPO_DIR}" || exit 1
git config user.email test@example.invalid
git config user.name test
git config advice.addEmbeddedRepo false
mkdir -p resources/js other
echo one >resources/js/main.min.js
echo one >other/file.txt
ln -s ../../other/file.txt resources/js/existing-link.js
git add -A
git commit -q -m "Add base files" || exit 1

reset_tree() {
    git reset -q --hard
    git clean -q -ffd
}

# Writes the staged state as a patch the way the build job does. The second
# argument is the rename handling and the third an optional copy detection.
make_patch() {
    git add -A
    git diff --cached --binary "$2" ${3:+"$3"} >"${WORK_DIR}/$1.patch"
    reset_tree
}

# Runs the validation on one patch, leaving rc and output for the asserts.
validate() {
    output="$(
        BUNDLE_DIR="resources/js" bash -c "set -euo pipefail; $(sed "s#\${PATCH_DIR}/bundle.patch#${WORK_DIR}/$1.patch#" "${WORK_DIR}/validation.sh")" 2>&1
    )"
    rc=$?
    reset_tree
}

echo two >resources/js/main.min.js
echo new >resources/js/extra.min.js.map
make_patch good --no-renames
validate good
assert_eq "change inside the bundle directory: accepted" "0" "${rc}"

git rm -q resources/js/main.min.js
make_patch delete --no-renames
validate delete
assert_eq "deletion inside the bundle directory: accepted" "0" "${rc}"

# A rebuild may rename a bundle file inside the directory. The result is read
# without rename detection, so the move is a deletion plus an addition.
git mv resources/js/main.min.js resources/js/main.renamed.min.js
make_patch inner-rename --no-renames
validate inner-rename
assert_eq "rename inside the bundle directory: accepted" "0" "${rc}"

echo two >other/file.txt
make_patch outside --no-renames
validate outside
assert_eq "path outside the bundle directory: refused" "1" "${rc}"
assert_contains "path outside: names the reason" "${output}" "other than regular files inside the bundle directory"

mkdir -p .github/workflows
echo x >.github/workflows/evil.yml
make_patch workflow --no-renames
validate workflow
assert_eq "workflow file: refused" "1" "${rc}"
assert_contains "workflow file: names the reason" "${output}" "other than regular files inside the bundle directory"

mkdir -p resources/js-evil
echo x >resources/js-evil/a
make_patch prefix --no-renames
validate prefix
assert_eq "sibling directory sharing the name prefix: refused" "1" "${rc}"
assert_contains "sibling directory: names the reason" "${output}" "other than regular files inside the bundle directory"

# A rename names only its target in the path list, so the source outside the
# bundle directory is deleted without the path test seeing it.
git mv other/file.txt resources/js/moved.txt
make_patch rename -M
validate rename
assert_eq "rename from outside into the bundle directory: refused" "1" "${rc}"
assert_contains "rename: names the reason" "${output}" "other than regular files inside the bundle directory"

# A copy only reads its source and adds a regular file inside the bundle
# directory, which is a plain addition.
cp other/file.txt resources/js/copied.txt
make_patch copy -M --find-copies-harder
validate copy
assert_eq "copy into the bundle directory: accepted as an addition" "0" "${rc}"

# A patch whose old and new names differ without any rename header still
# removes the old path, so the text of the patch does not show the deletion.
cat >"${WORK_DIR}/forged-rename.patch" <<'PATCH'
diff --git a/other/file.txt b/resources/js/forged.txt
--- a/other/file.txt
+++ b/resources/js/forged.txt
@@ -1 +1 @@
-one
+evil
PATCH
validate forged-rename
assert_eq "forged rename without a rename header: refused" "1" "${rc}"
assert_contains "forged rename: names the reason" "${output}" "other than regular files inside the bundle directory"

ln -s ../../other/file.txt resources/js/link.js
make_patch symlink --no-renames
validate symlink
assert_eq "new symlink inside the bundle directory: refused" "1" "${rc}"
assert_contains "new symlink: names the reason" "${output}" "other than regular files inside the bundle directory"

# The mode line of the same patch in spellings that the patch format accepts
# and a text pattern does not match.
sed 's/^new file mode 120000$/new file mode 120000 /' "${WORK_DIR}/symlink.patch" >"${WORK_DIR}/symlink-space.patch"
validate symlink-space
assert_eq "symlink with a trailing space in the mode line: refused" "1" "${rc}"
assert_contains "symlink with a trailing space: names the reason" "${output}" "other than regular files inside the bundle directory"
sed 's/^new file mode 120000$/new file mode 0120000/' "${WORK_DIR}/symlink.patch" >"${WORK_DIR}/symlink-zero.patch"
validate symlink-zero
assert_eq "symlink with a leading zero in the mode: refused" "1" "${rc}"
assert_contains "symlink with a leading zero: names the reason" "${output}" "other than regular files inside the bundle directory"

# A symlink that is already committed keeps its mode, so the patch has no mode
# line of its own, only the index line names the mode.
rm resources/js/existing-link.js
ln -s ../../other/other-target.txt resources/js/existing-link.js
make_patch retarget --no-renames
validate retarget
assert_eq "retargeting an existing symlink: refused" "1" "${rc}"
assert_contains "retargeting a symlink: names the reason" "${output}" "other than regular files inside the bundle directory"

# A nested repository is staged as a submodule entry.
git init -q resources/js/submodule
git -C resources/js/submodule config user.email test@example.invalid
git -C resources/js/submodule config user.name test
git -C resources/js/submodule commit -q --allow-empty -m "Add nothing"
make_patch submodule --no-renames
validate submodule
assert_eq "submodule inside the bundle directory: refused" "1" "${rc}"
assert_contains "submodule: names the reason" "${output}" "other than regular files inside the bundle directory"

# The hand-over of the build job. The step stages everything before it runs
# this part, so each case stages its change first.
run_handover() {
    command rm -rf "${WORK_DIR}/tmp" "${WORK_DIR}/out"
    mkdir -p "${WORK_DIR}/tmp"
    : >"${WORK_DIR}/out"
    AUTO_PUSH="$1" BUNDLE_DIR="resources/js" RUNNER_TEMP="${WORK_DIR}/tmp" GITHUB_OUTPUT="${WORK_DIR}/out" \
        bash -c "set -euo pipefail; $(cat "${WORK_DIR}/handover.sh")" >/dev/null 2>&1
    rc=$?
    handed_over="$(cat "${WORK_DIR}/out")"
    if [ -s "${WORK_DIR}/tmp/bundle.patch" ]; then patch_written=yes; else patch_written=no; fi
}

echo two >resources/js/main.min.js
git add -A
run_handover true
assert_eq "bot pull request, change inside the bundle directory: handed over" "patchable=true" "${handed_over}"
assert_eq "bot pull request, change inside: patch written" "yes" "${patch_written}"
assert_contains "handed over patch holds the bundle file" "$(cat "${WORK_DIR}/tmp/bundle.patch")" "resources/js/main.min.js"
reset_tree

echo two >resources/js/main.min.js
git add -A
run_handover false
assert_eq "not a bot pull request, change inside: not handed over" "" "${handed_over}"
assert_eq "not a bot pull request: no patch written" "no" "${patch_written}"
reset_tree

echo two >resources/js/main.min.js
echo two >other/file.txt
git add -A
run_handover true
assert_eq "bot pull request, change also outside: not handed over" "" "${handed_over}"
assert_eq "change also outside: no patch written" "no" "${patch_written}"
reset_tree

# The check that the branch still is the head commit of the run. A stub git
# answers the remote query, and a line after the cut shows whether the step
# goes on.
mkdir -p "${WORK_DIR}/shim"
cat >"${WORK_DIR}/shim/git" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "ls-remote" ]; then
    printf '%s\trefs/heads/%s\n' "${REMOTE_SHA}" "${HEAD_REF}"
    exit 0
fi
exec /usr/bin/env -i PATH="${REAL_PATH}" git "$@"
STUB
chmod +x "${WORK_DIR}/shim/git"

run_moved_check() {
    output="$(
        env "REAL_PATH=${PATH}" "PATH=${WORK_DIR}/shim:${PATH}" "REMOTE_SHA=$1" TOKEN=token REPOSITORY=owner/repo \
            HEAD_REF=feature HEAD_SHA=aaaaaaaa \
            bash -c "set -euo pipefail; $(cat "${WORK_DIR}/moved-check.sh"); echo CONTINUED" 2>&1
    )"
    rc=$?
}

run_moved_check aaaaaaaa
assert_eq "branch at the head commit: ends successfully" "0" "${rc}"
assert_contains "branch at the head commit: the step goes on" "${output}" "CONTINUED"

run_moved_check bbbbbbbb
assert_eq "branch moved on: ends successfully" "0" "${rc}"
assert_contains "branch moved on: names the reason" "${output}" "branch moved on"
case "${output}" in
    *CONTINUED*) _harness_fail "branch moved on: the step stops" "${output}" ;;
    *) echo "PASS: branch moved on: the step stops" ;;
esac

# The push job names the secret and ends without a push when it is empty. The
# step writes its result to the output file that the later steps test.
run_token_check() {
    command rm -f "${WORK_DIR}/token-out"
    : >"${WORK_DIR}/token-out"
    output="$(
        TOKEN="$1" GITHUB_OUTPUT="${WORK_DIR}/token-out" \
            bash -c "set -euo pipefail; $(cat "${WORK_DIR}/token-check.sh")" 2>&1
    )"
    rc=$?
    token_output="$(cat "${WORK_DIR}/token-out")"
}

run_token_check "a-token"
assert_eq "token present: the later steps are enabled" "present=true" "${token_output}"
run_token_check ""
assert_eq "token empty: the later steps stay disabled" "" "${token_output}"
assert_eq "token empty: the step ends successfully" "0" "${rc}"
assert_contains "token empty: names the reason" "${output}" "the rebuilt bundle is not pushed"

# The conditions that select a pull request are Actions expressions.
expressions="$(python3 - "${WORKFLOW_FILE}" <<'PY'
import sys
import yaml

jobs = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["jobs"]
build_step = [s for s in jobs["bundle-freshness"]["steps"] if s.get("id") == "rebuild"][0]
print("BUILD=" + build_step["env"]["AUTO_PUSH"])
print("PUSH=" + jobs["push-rebuild"]["if"])
PY
)"
build_expression="$(printf '%s\n' "${expressions}" | sed -n 's/^BUILD=//p')"
push_expression="$(printf '%s\n' "${expressions}" | sed -n 's/^PUSH=//p')"
expected_build=$'${{ github.event_name == \'pull_request\' && github.event.pull_request.user.login == inputs.bot-login && github.event.pull_request.head.repo.full_name == github.repository }}'
expected_push=$'${{ !cancelled() && needs.bundle-freshness.outputs.patchable == \'true\' && github.event_name == \'pull_request\' && github.event.pull_request.user.login == inputs.bot-login && github.event.pull_request.head.repo.full_name == github.repository }}'
assert_eq "build gate: pull request event, bot author and this repository, and no secret" "${expected_build}" "${build_expression}"
assert_eq "push gate: output of the build, pull request event, bot author and this repository" "${expected_push}" "${push_expression}"

dependencies="$(python3 - "${WORKFLOW_FILE}" <<'PY'
import re
import sys
import yaml

jobs = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["jobs"]
condition = "${{ steps.token.outputs.present == 'true' }}"
for step in jobs["push-rebuild"]["steps"]:
    if step.get("id") != "token":
        print("GATED" if step.get("if") == condition else "OPEN " + step.get("name", ""))
build = yaml.safe_dump(jobs["bundle-freshness"])
print("BUILD_NAMES_SECRET" if re.search(r"\bsecrets\b", build) else "BUILD_CLEAN")
PY
)"
assert_eq "every later step of the push job depends on the token check, and the build job names no secret" \
    "$(printf 'GATED\nGATED\nGATED\nBUILD_CLEAN')" "${dependencies}"

report_and_exit "bundle freshness push tests"
