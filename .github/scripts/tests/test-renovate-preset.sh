#!/usr/bin/env bash
# Pins the package rule of renovate-config.json that keeps the shared
# workflows of this repository unpinned while every other GitHub Action keeps
# its digest pin. The preset is read by Renovate, not by this repository's own
# code, so the assertions read the JSON itself. RENOVATE_PRESET_FILE points
# the test at another copy of the preset and defaults to the file of this
# repository. Run via run-tests.sh.
#
# No `set -e`: a failing assertion must be counted, not abort the run.
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

# A later rule that sets pinDigests, whatever it matches, could undo the
# exemption, because rules are merged in order and the later one wins.
later_pin_rules="$(jq --arg name "${SHARED_WORKFLOWS}" \
    '[.packageRules | (map((.matchPackageNames // []) | index($name) != null) | index(true)) as $at
      | to_entries[] | select(.key > ($at // -1) and (.value | has("pinDigests")))] | length' "${PRESET}")"
assert_eq "no package rule after the one for ${SHARED_WORKFLOWS} sets pinDigests" 0 "${later_pin_rules}"

helper="$(jq -r '[.extends[] | select(. == "helpers:pinGitHubActionDigests")] | length' "${PRESET}")"
assert_eq "the preset still extends helpers:pinGitHubActionDigests" 1 "${helper}"

report_and_exit "renovate preset tests"
