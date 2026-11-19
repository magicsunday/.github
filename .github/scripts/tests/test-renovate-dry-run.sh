#!/usr/bin/env bash
# Pins the properties of renovate-dry-run.yml that make it safe to run by hand
# against a consumer repository: it starts only on request, it can only read,
# it never opens a pull request or pushes a branch, and the action that runs
# Renovate is pinned by commit. The run itself cannot be exercised here,
# because only a Renovate run shows what the preset does to a repository, so
# the assertions read the workflow file. RENOVATE_DRY_RUN_WORKFLOW points the
# test at another copy and defaults to the file of this repository. Run via
# run-tests.sh.
#
# No `set -e`, because a failing assertion must be counted and not abort the run.
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)" || exit 1
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
WORKFLOW="${RENOVATE_DRY_RUN_WORKFLOW:-${REPO_ROOT}/.github/workflows/renovate-dry-run.yml}"

require_files_or_bail "renovate dry run tests" "${WORKFLOW}"

workflow_json="$(yq -o=json '.' "${WORKFLOW}")" || exit 1

query() {
    jq -r "$1" <<<"${workflow_json}"
}

# The only trigger is a manual start. A schedule or a pull request trigger
# would run Renovate against other repositories without anyone asking for it,
# and a reusable-workflow trigger would hand the run to a caller's token.
assert_eq "the only trigger is workflow_dispatch" '["workflow_dispatch"]' "$(query '[.on | keys[]] | sort | tojson')"

# The token can read and nothing else, at the workflow level and at the job.
assert_eq "the workflow grants contents: read and nothing else" '{"contents":"read"}' "$(query '.permissions | tojson')"
assert_eq "every job grants contents: read and nothing else" '1' "$(query '[.jobs[] | .permissions | tojson] | unique | map(select(. == "{\"contents\":\"read\"}")) | length')"
assert_eq "no job takes another permission block" '0' "$(query '[.jobs[] | select(.permissions != {"contents": "read"})] | length')"

# A secret would let the run write with a token of its own. The run reads
# with the token the workflow gets anyway.
secret_refs="$(grep -c 'secrets\.' "${WORKFLOW}" || true)"
assert_eq "the workflow references no secret" 0 "${secret_refs}"

# Every action is pinned by a full commit and carries its version in a comment.
unpinned="$(query '[.jobs[].steps[] | select(has("uses")) | .uses | select(test("@[0-9a-f]{40}$") | not)] | length')"
assert_eq "every action is pinned by a full commit" 0 "${unpinned}"

renovate_steps="$(query '[.jobs[].steps[] | select((.uses // "") | startswith("renovatebot/github-action@"))] | length')"
assert_eq "exactly one step runs Renovate" 1 "${renovate_steps}"

# The dry run reports what Renovate would do and writes nothing: no pull
# request, no branch, no onboarding commit.
renovate_env() {
    query "[.jobs[].steps[] | select((.uses // \"\") | startswith(\"renovatebot/github-action@\")) | .env.$1] | first"
}
assert_eq "the Renovate step runs with the dry run set to full" full "$(renovate_env RENOVATE_DRY_RUN)"
assert_eq "the Renovate step does not onboard the repository" false "$(renovate_env RENOVATE_ONBOARDING)"
assert_eq "the Renovate step reads one repository, taken from the input" '${{ inputs.repository }}' "$(renovate_env RENOVATE_REPOSITORIES)"
assert_eq "the Renovate step writes its report as a file" file "$(renovate_env RENOVATE_REPORT_TYPE)"

# The input is checked before it reaches Renovate, so a typo or another
# account's repository stops the run instead of reading it.
assert_eq "a step checks the input before the Renovate step" true "$(query '[.jobs[].steps | (map((.uses // "") | startswith("renovatebot/github-action@")) | index(true)) as $run | to_entries[] | select(.key < $run and ((.value.run // "") | contains("renovate_dry_run_check_repository \"$CONSUMER_REPOSITORY\"")))] | length == 1')"

# The report is evaluated by the library that its own test pins, and that step
# comes after the Renovate step that writes the report.
assert_eq "the evaluation step sources the library after the Renovate step" true "$(query '[.jobs[].steps | (map((.uses // "") | startswith("renovatebot/github-action@")) | index(true)) as $run | to_entries[] | select(.key > $run and ((.value.run // "") | contains("source .github/scripts/lib/renovate-dry-run.sh")))] | length == 1')"

# The checkout of this repository keeps no credentials in the git config.
persist="$(query '[.jobs[].steps[] | select((.uses // "") | startswith("actions/checkout@")) | .with["persist-credentials"]] | unique | tojson')"
assert_eq "every checkout drops the credentials" '[false]' "${persist}"

# The report path the Renovate step writes is the path the evaluation step reads.
report_path="$(renovate_env RENOVATE_REPORT_PATH)"
evaluate_run="$(workflow_step_run "${WORKFLOW}" "Evaluate the report")" || exit 1
case "${evaluate_run}" in
    *"${report_path}"*) echo "PASS: the evaluation step reads the report path that the Renovate step writes" ;;
    *) _harness_fail "the evaluation step reads the report path that the Renovate step writes" "${evaluate_run}" ;;
esac

# The evaluation step itself runs here, with the report path moved into a
# scratch directory, so the verdict, the job summary and the exit status are
# the ones a runner would produce. A missing report must reach the verdict of
# the library and not a bare jq error.
workdir="$(mktemp -d)" || exit 1
trap 'rm -rf "${workdir}"' EXIT
run_evaluation() {
    # $1 is the report file name inside the scratch directory.
    local script="${evaluate_run//${report_path}/${workdir}/$1}"
    : >"${workdir}/summary.md"
    (cd "${REPO_ROOT}" && CONSUMER_REPOSITORY="magicsunday/example" GITHUB_STEP_SUMMARY="${workdir}/summary.md" bash -c "${script}") 2>&1
}

make_report() {
    # $1 file name, $2 the updates array of one shared workflow call.
    jq -n --argjson updates "$2" \
        '{repositories: {"magicsunday/example": {packageFiles: {"github-actions": [{packageFile: ".github/workflows/ci.yml", deps: [{depName: "magicsunday/.github", currentValue: "main", updates: $updates}]}]}}}}' \
        >"${workdir}/$1"
}

make_report ok.json '[]'
out="$(run_evaluation ok.json)"
assert_eq "an up to date report passes the evaluation step" 0 "$?"
assert_contains "the summary of a passing run says that nothing is proposed" "$(cat "${workdir}/summary.md")" "Renovate would propose no update." "Verdict: The shared workflows were seen in 1 calls"

make_report pin.json '[{"updateType": "pinDigest", "newValue": "v2"}]'
out="$(run_evaluation pin.json)"
assert_eq "a pin update for the shared workflows fails the evaluation step" 1 "$?"
assert_contains "the summary of a failing run lists the update" "$(cat "${workdir}/summary.md")" "magicsunday/.github main pinDigest v2" "Verdict:"
assert_contains "the output of a failing run carries the error annotation" "${out}" "::error::"

out="$(run_evaluation absent.json)"
assert_eq "a missing report fails the evaluation step" 1 "$?"
assert_contains "a missing report reaches the verdict of the library" "${out}" "missing or empty"
assert_contains "the summary of a missing report holds the verdict" "$(cat "${workdir}/summary.md")" "Verdict:" "missing or empty"

report_and_exit "renovate dry run tests"
