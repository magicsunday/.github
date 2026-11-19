#!/usr/bin/env bash
# Pins the evaluation of the report that a Renovate dry run writes
# (renovate-dry-run.yml): the shared workflows of this repository are called
# with the @main ref by policy, so Renovate must propose no update for them,
# and a run that never saw them proves nothing. The report below has the shape
# of a real Renovate report (repositories, package files by manager, the
# dependencies of a package file with their updates), cut down to what the
# evaluation reads. Run via run-tests.sh.
#
# No `set -e`, because a failing assertion must be counted and not abort the run.
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)" || exit 1
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
LIB="${REPO_ROOT}/.github/scripts/lib/renovate-dry-run.sh"

require_files_or_bail "renovate dry run report tests" "${LIB}"
# shellcheck source=../lib/renovate-dry-run.sh
source "${LIB}"

workdir="$(mktemp -d)" || exit 1
trap 'rm -rf "${workdir}"' EXIT

# A consumer whose shared workflows and one other action are up to date.
report="${workdir}/report.json"
cat >"${report}" <<'JSON'
{
    "problems": [],
    "repositories": {
        "magicsunday/example": {
            "branches": [],
            "problems": [],
            "packageFiles": {
                "github-actions": [
                    {
                        "packageFile": ".github/workflows/ci.yml",
                        "deps": [
                            {"depName": "magicsunday/.github", "currentValue": "main", "updates": []},
                            {"depName": "magicsunday/.github", "currentValue": "main", "updates": []},
                            {"depName": "actions/checkout", "currentValue": "v7.0.1", "updates": []}
                        ]
                    },
                    {
                        "packageFile": ".github/workflows/i18n.yml",
                        "deps": [
                            {"depName": "magicsunday/.github", "currentValue": "main", "updates": []}
                        ]
                    }
                ],
                "renovate-config": [
                    {
                        "packageFile": "renovate.json",
                        "deps": [
                            {"depName": "magicsunday/.github", "currentValue": null, "updates": []}
                        ]
                    }
                ]
            }
        }
    }
}
JSON

assert_eq "the shared workflows are counted in the github-actions manager only" 3 "$(renovate_report_dependency_count "${report}" "magicsunday/.github")"

renovate_report_check_shared_workflows "${report}" >"${workdir}/out.txt" 2>&1
assert_eq "a report without updates for the shared workflows passes" 0 "$?"
assert_eq "the pass says how many calls it saw" "The shared workflows were seen in 3 calls and receive no update." "$(cat "${workdir}/out.txt")"

assert_eq "an up to date report lists no update" "" "$(renovate_report_updates "${report}")"

# Each kind of update for the shared workflows is caught, because the preset
# keeps them unpinned and so any update means the exemption does not hold.
for update_type in pin pinDigest digest minor major patch; do
    mutated="${workdir}/mutated-${update_type}.json"
    jq --arg type "${update_type}" \
        '.repositories["magicsunday/example"].packageFiles["github-actions"][0].deps[0].updates = [{"updateType": $type, "newValue": "v2"}]' \
        "${report}" >"${mutated}"
    out="$(renovate_report_check_shared_workflows "${mutated}" 2>&1)"
    assert_eq "an update of type ${update_type} for the shared workflows fails" 1 "$?"
    assert_contains "the failure for ${update_type} names the dependency and the type" "${out}" "magicsunday/.github main ${update_type}"
done

# An update for another action is reported and does not fail the check.
other="${workdir}/other.json"
jq '.repositories["magicsunday/example"].packageFiles["github-actions"][0].deps[2].updates = [{"updateType": "pinDigest", "newValue": "v7.0.2"}]' \
    "${report}" >"${other}"
renovate_report_check_shared_workflows "${other}" >/dev/null 2>&1
assert_eq "an update for another action does not fail the check" 0 "$?"
assert_eq "an update for another action is listed" "actions/checkout v7.0.1 pinDigest v7.0.2" "$(renovate_report_updates "${other}")"

# A run that never saw the shared workflows proves nothing, so it fails: the
# consumer may not call them, or Renovate may have read another manager.
none="${workdir}/none.json"
jq '.repositories["magicsunday/example"].packageFiles["github-actions"] |= map(.deps |= map(select(.depName != "magicsunday/.github")))' \
    "${report}" >"${none}"
out="$(renovate_report_check_shared_workflows "${none}" 2>&1)"
assert_eq "a report that never saw the shared workflows fails" 1 "$?"
assert_contains "the failure says that the run proves nothing" "${out}" "proves nothing"

# A missing, empty or malformed report fails, and a report with no repository
# fails, so a run that never read the consumer cannot pass.
out="$(renovate_report_check_shared_workflows "${workdir}/absent.json" 2>&1)"
assert_eq "a missing report fails" 1 "$?"
assert_contains "the failure for a missing report names it" "${out}" "missing or empty"
: >"${workdir}/empty.json"
out="$(renovate_report_check_shared_workflows "${workdir}/empty.json" 2>&1)"
assert_eq "an empty report fails" 1 "$?"
assert_contains "the failure for an empty report names it" "${out}" "missing or empty"
printf 'not json' >"${workdir}/bad.json"
out="$(renovate_report_check_shared_workflows "${workdir}/bad.json" 2>&1)"
assert_eq "a malformed report fails" 1 "$?"
assert_contains "the failure for a malformed report names it" "${out}" "not a JSON object"
printf '[]' >"${workdir}/array.json"
out="$(renovate_report_check_shared_workflows "${workdir}/array.json" 2>&1)"
assert_eq "a JSON value that is no object fails" 1 "$?"
assert_contains "the failure for a JSON array names it" "${out}" "not a JSON object"
printf '{"repositories": {}}' >"${workdir}/norepo.json"
renovate_report_check_shared_workflows "${workdir}/norepo.json" >/dev/null 2>&1
assert_eq "a report without a repository fails" 1 "$?"

# The repository input names a repository of this account, and nothing else
# reaches Renovate: another owner, a nested path, a missing name, an empty
# value, blanks and shell metacharacters all stop the run.
renovate_dry_run_check_repository "magicsunday/webtrees-fan-chart" >/dev/null 2>&1
assert_eq "a repository of the account passes" 0 "$?"
renovate_dry_run_check_repository "magicsunday/.github" >/dev/null 2>&1
assert_eq "a repository name with a leading dot passes" 0 "$?"
renovate_dry_run_check_repository "magicsunday/a_b.c-d1" >/dev/null 2>&1
assert_eq "a repository name with underscore, dot, dash and digit passes" 0 "$?"
for repository in \
    "other/webtrees-fan-chart" \
    "magicsunday" \
    "magicsunday/" \
    "magicsunday/a/b" \
    "magicsunday/a b" \
    "magicsunday/a;b" \
    "magicsunday/\$(id)" \
    "magicsunday/a
b" \
    "Magicsunday/a" \
    " magicsunday/a" \
    ""; do
    out="$(renovate_dry_run_check_repository "${repository}" 2>&1)"
    assert_eq "the repository input '${repository//$'\n'/\\n}' fails" 1 "$?"
    assert_contains "the failure for '${repository//$'\n'/\\n}' says what the input must read" "${out}" "magicsunday/name"
done

report_and_exit "renovate dry run report tests"
