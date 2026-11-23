#!/usr/bin/env bash
# Pins which updates the shared Renovate preset (renovate-config.json) lets
# Renovate merge by itself and which stay with a person. The preset is read by
# Renovate, not by this repository's own code, so the test reads the JSON and
# works out the verdict per update the way Renovate merges package rules: every
# rule whose matchers all hold applies, a missing matcher matches anything, and
# the last matching rule that sets automerge wins. A verdict is a decision of
# the preset, so each case names the update it stands for. RENOVATE_PRESET_FILE
# points the test at another copy of the preset and defaults to the file of this
# repository. Run via run-tests.sh.
#
# No `set -e`, because a failing assertion must be counted and not abort the run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
PRESET="${RENOVATE_PRESET_FILE:-${REPO_ROOT}/renovate-config.json}"
TOOLING_IMAGE="ghcr.io/magicsunday/webtrees-docker-module-base"
CHART_LIB="@magicsunday/webtrees-chart-lib"
CODING_STANDARD="@magicsunday/coding-standard"
CONSUMER="magicsunday/webtrees-statistics"

require_files_or_bail "renovate automerge tests" "${PRESET}"

# The verdict of a preset for one update, true or false. An update without a
# matching rule that sets automerge is not merged by Renovate.
verdict() {
    local preset="$1" manager="$2" update_type="$3" dep_name="$4" datasource="${5:-}" repository="${6:-${CONSUMER}}"

    jq -r --arg manager "${manager}" --arg type "${update_type}" --arg dep "${dep_name}" \
        --arg datasource "${datasource}" --arg repository "${repository}" '
        def listed($key; $value):
            (.[$key] // null) as $list | ($list == null) or (($list | index($value)) != null);
        def applies:
            listed("matchManagers"; $manager)
            and listed("matchUpdateTypes"; $type)
            and listed("matchDepNames"; $dep)
            and listed("matchPackageNames"; $dep)
            and listed("matchDatasources"; $datasource)
            and listed("matchRepositories"; $repository);
        # The switch of the lock file refresh is the base of that update type, a
        # package rule that sets automerge overrides it.
        (if $type == "lockFileMaintenance" then (.lockFileMaintenance.automerge // false) else false end) as $base
        | [.packageRules[] | select(applies) | select(has("automerge")) | .automerge] as $set
        | if ($set | length) > 0 then $set[-1] else $base end
    ' "${preset}"
}

# Each case: manager, update type, dependency, datasource, expected verdict and
# the update it stands for. A repository other than the consumer is the sixth
# argument of verdict().
check() {
    local expected="$1" manager="$2" update_type="$3" dep_name="$4" datasource="$5" what="$6"

    assert_eq "${what}: merged by Renovate is ${expected}" "${expected}" \
        "$(verdict "${PRESET}" "${manager}" "${update_type}" "${dep_name}" "${datasource}")"
}

# GitHub Actions: all but majors merge by themselves.
check true github-actions patch actions/checkout github-tags "a patch update of a GitHub Action"
check true github-actions minor actions/checkout github-tags "a minor update of a GitHub Action"
check true github-actions digest actions/checkout github-tags "a digest update of a GitHub Action"
check true github-actions pin actions/checkout github-tags "a pin update of a GitHub Action"
check true github-actions pinDigest actions/checkout github-tags "a pinned digest update of a GitHub Action"
check false github-actions major actions/checkout github-tags "a major update of a GitHub Action"

# npm: patch and minor merge by themselves, majors do not.
check true npm patch rollup npm "a patch update of an npm package"
check true npm minor rollup npm "a minor update of an npm package"
check false npm major rollup npm "a major update of an npm package"

# The packages pinned by git tag are npm updates like the others: patch and
# minor merge by themselves, majors do not.
check true npm minor "${CODING_STANDARD}" github-tags "a minor update of the coding standard pin"
check false npm major "${CODING_STANDARD}" github-tags "a major update of the coding standard pin"
check true npm minor "${CHART_LIB}" github-tags "a minor update of the chart library pin"
check false npm major "${CHART_LIB}" github-tags "a major update of the chart library pin"

# The tooling image: a new digest merges by itself, a new tag does not, and
# another image never does.
check true docker digest "${TOOLING_IMAGE}" docker "a new digest of the tooling image"
check false docker minor "${TOOLING_IMAGE}" docker "a minor update of the tooling image"
check false docker major "${TOOLING_IMAGE}" docker "a major update of the tooling image"
check false docker pin "${TOOLING_IMAGE}" docker "a pin update of the tooling image"
check false docker pinDigest "${TOOLING_IMAGE}" docker "a pinned digest update of the tooling image"
check false docker digest mysql docker "a new digest of another image"

# What the preset does not name stays with a person.
check false composer patch vendor/package packagist "a patch update of a Composer package"
check false pip-compile patch semgrep pypi "a patch update of a pip-compile closure"
check false pip-compile minor semgrep pypi "a minor update of a pip-compile closure"

# The tooling image digest stays manual in the repository of the shared workflows.
assert_eq "a new digest of the tooling image in the shared workflow repository: merged by Renovate is false" false \
    "$(verdict "${PRESET}" docker digest "${TOOLING_IMAGE}" docker "magicsunday/.github")"

# The weekly lock file refresh has its own switch, and the closures of pip stay manual.
check true npm lockFileMaintenance "" "" "the weekly refresh of an npm lock file"
check true composer lockFileMaintenance "" "" "the weekly refresh of a Composer lock file"
check false pip-compile lockFileMaintenance "" "" "the weekly refresh of the pip-compile closures"

# The cases above only mean something if the checker can see a rule go missing.
# A copy without the npm rule must lose the merge of an npm patch update.
mutated_preset="$(mktemp)" || exit 1
trap 'rm -f "${mutated_preset}"' EXIT
jq '.packageRules |= map(select(((.matchManagers // []) == ["npm"]) and ((.matchUpdateTypes // []) == ["patch", "minor"]) | not))' \
    "${PRESET}" >"${mutated_preset}"
assert_eq "without the npm rule an npm patch update is not merged by Renovate" false \
    "$(verdict "${mutated_preset}" npm patch rollup npm)"

report_and_exit "renovate automerge tests"
