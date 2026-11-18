#!/usr/bin/env bash
# Pins the package rule of renovate-config.json that keeps the shared
# workflows of this repository unpinned while every other GitHub Action keeps
# its digest pin. The preset is read by Renovate, not by this repository's own
# code, so the assertions read the JSON itself. RENOVATE_PRESET_FILE points
# the test at another copy of the preset and defaults to the file of this
# repository. Run via run-tests.sh.
#
# No `set -e`, because a failing assertion must be counted and not abort the run.
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)" || exit 1
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
PRESET="${RENOVATE_PRESET_FILE:-${REPO_ROOT}/renovate-config.json}"
SHARED_WORKFLOWS="magicsunday/.github"

require_files_or_bail "renovate preset tests" "${PRESET}"

# Package rules whose matchPackageNames lists the shared workflows.
rule_count="$(jq --arg name "${SHARED_WORKFLOWS}" \
    '[.packageRules[] | select((.matchPackageNames // []) | index($name))] | length' "${PRESET}")"
assert_eq "exactly one package rule matches ${SHARED_WORKFLOWS}" 1 "${rule_count}"

managers="$(jq -c --arg name "${SHARED_WORKFLOWS}" \
    '[.packageRules[] | select((.matchPackageNames // []) | index($name)) | .matchManagers] | first // null' "${PRESET}")"
assert_eq "the rule for ${SHARED_WORKFLOWS} is limited to the github-actions manager" '["github-actions"]' "${managers}"

pin_digests="$(jq -r --arg name "${SHARED_WORKFLOWS}" \
    '[.packageRules[] | select((.matchPackageNames // []) | index($name)) | .pinDigests] | first | tojson' "${PRESET}")"
assert_eq "the rule for ${SHARED_WORKFLOWS} sets pinDigests to false" false "${pin_digests}"

# A later rule that changes the pinning, whatever it matches, could undo the
# exemption, because rules are merged in order and the later one wins. A rule
# changes the pinning when it sets pinDigests or when it takes the pin update
# types and sets `enabled`, which can switch the pin pull requests back on. A
# rule that only sets automerge for those types leaves the pinning alone. The
# matcher of such a rule does not matter, so one that matches the shared
# workflows by matchDepNames or by matchPackagePatterns counts the same as one
# that names the package.
later_pin_rules_in() {
    jq --arg name "${SHARED_WORKFLOWS}" \
        '[.packageRules | (map((.matchPackageNames // []) | index($name) != null) | index(true)) as $at
          | to_entries[] | select(.key > ($at // -1)
              and (.value | has("pinDigests")
                  or (has("enabled") and ((.matchUpdateTypes // []) | any(. == "pin" or . == "pinDigest")))))] | length' "$1"
}
assert_eq "no package rule after the one for ${SHARED_WORKFLOWS} changes the pinning" 0 "$(later_pin_rules_in "${PRESET}")"

# Each way a later rule can change the pinning is seen, and an unrelated later
# rule is not. The cases append one rule to a copy of the preset.
mutated_preset="$(mktemp)" || exit 1
trap 'rm -f "${mutated_preset}"' EXIT
for later_rule in \
    "{\"matchPackageNames\": [\"${SHARED_WORKFLOWS}\"], \"pinDigests\": true}|1|a later rule by matchPackageNames that sets pinDigests" \
    "{\"matchDepNames\": [\"${SHARED_WORKFLOWS}\"], \"pinDigests\": true}|1|a later rule by matchDepNames that sets pinDigests" \
    "{\"matchPackagePatterns\": [\"^magicsunday/\"], \"pinDigests\": true}|1|a later rule by matchPackagePatterns that sets pinDigests" \
    "{\"matchDepNames\": [\"${SHARED_WORKFLOWS}\"], \"matchUpdateTypes\": [\"pinDigest\"], \"enabled\": true}|1|a later rule by matchDepNames that takes the pinDigest update type" \
    "{\"matchPackagePatterns\": [\"^magicsunday/\"], \"matchUpdateTypes\": [\"pin\"], \"enabled\": true}|1|a later rule by matchPackagePatterns that takes the pin update type" \
    "{\"matchDepNames\": [\"${SHARED_WORKFLOWS}\"], \"matchUpdateTypes\": [\"pinDigest\"], \"automerge\": true}|0|a later rule that only sets automerge for the pin update types"; do
    IFS='|' read -r rule_json expected_count rule_what <<<"${later_rule}"
    jq --argjson rule "${rule_json}" '.packageRules += [$rule]' "${PRESET}" >"${mutated_preset}"
    assert_eq "${rule_what}: counted as ${expected_count}" "${expected_count}" "$(later_pin_rules_in "${mutated_preset}")"
done

helper="$(jq -r '[.extends[] | select(. == "helpers:pinGitHubActionDigests")] | length' "${PRESET}")"
assert_eq "the preset still extends helpers:pinGitHubActionDigests" 1 "${helper}"

report_and_exit "renovate preset tests"
