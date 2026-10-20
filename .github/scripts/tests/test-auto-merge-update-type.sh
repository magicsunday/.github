#!/usr/bin/env bash
# Exercises effective_update_type() (.github/scripts/lib/auto-merge-update-type.sh),
# the function auto-merge-deps.yml sources to classify a Dependabot pull
# request whose group contains a git-pinned dependency. Run via run-tests.sh.
#
# No `set -e`: assertions capture results themselves, and a failing
# assertion must be counted, not abort the run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"
# shellcheck source=../lib/auto-merge-update-type.sh
source "${SCRIPT_DIR}/../lib/auto-merge-update-type.sh"

readonly HASH="6d769850d4ded756bc7fccf3d7966a586e123027"
readonly MAJOR="version-update:semver-major"
readonly MINOR="version-update:semver-minor"
readonly PATCH="version-update:semver-patch"

# The package.json patch of a pull request that moves the pin from $1 to $2.
pin_patch() {
    printf '%s\n' \
        '@@ -10,7 +10,7 @@' \
        '     "devDependencies": {' \
        "-        \"@magicsunday/coding-standard\": \"github:magicsunday/coding-standard#$1\"," \
        "+        \"@magicsunday/coding-standard\": \"github:magicsunday/coding-standard#$2\"," \
        '         "jscpd": "5.4.1"'
}

# The updated-dependencies-json of a group: the git pin as Dependabot reports
# it (the new version is a commit hash) plus one registry dependency.
deps_json() {
    jq -cn --arg registry_type "$1" --arg hash "${HASH}" '[
        {dependencyName: "@magicsunday/coding-standard", updateType: "version-update:semver-major", prevVersion: "3.6.0", newVersion: $hash},
        {dependencyName: "jscpd", updateType: $registry_type, prevVersion: "5.4.0", newVersion: "5.4.1"}
    ]'
}

assert_eq "no git pin keeps the type of the action" \
    "${MINOR}" \
    "$(effective_update_type '[{"dependencyName":"rollup","updateType":"version-update:semver-minor","prevVersion":"4.63.0","newVersion":"4.64.0"}]' '' "${MINOR}")"

assert_eq "no git pin keeps a major of the action" \
    "${MAJOR}" \
    "$(effective_update_type '[{"dependencyName":"rollup","updateType":"version-update:semver-major","prevVersion":"4.63.0","newVersion":"5.0.0"}]' '' "${MAJOR}")"

assert_eq "git pin minor bump with a patch sibling is minor" \
    "${MINOR}" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 3.6.0 3.8.0)" "${MAJOR}")"

assert_eq "git pin patch bump with a patch sibling is patch" \
    "${PATCH}" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 3.6.0 3.6.1)" "${MAJOR}")"

assert_eq "git pin major bump is major" \
    "${MAJOR}" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 3.6.0 4.0.0)" "${MAJOR}")"

assert_eq "a real major in a registry sibling wins over a minor git pin" \
    "${MAJOR}" \
    "$(effective_update_type "$(deps_json "${MAJOR}")" "$(pin_patch 3.6.0 3.8.0)" "${MAJOR}")"

assert_eq "a leading v on the pin tag is read" \
    "${MINOR}" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch v3.6.0 v3.8.0)" "${MAJOR}")"

assert_eq "a pin tag with two components is read" \
    "${MINOR}" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 3.6 3.8)" "${MAJOR}")"

assert_eq "an empty patch cannot be classified" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" '' "${MAJOR}")"

assert_eq "a pin line that is only on one side cannot be classified" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" '+        "@magicsunday/coding-standard": "github:magicsunday/coding-standard#3.8.0",' "${MAJOR}")"

assert_eq "a pin without a tag cannot be classified" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch main main)" "${MAJOR}")"

assert_eq "the same tag on both sides cannot be classified" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 3.8.0 3.8.0)" "${MAJOR}")"

assert_eq "a pin that appears twice cannot be classified" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 3.6.0 3.8.0)"$'\n'"$(pin_patch 3.6.0 3.8.0)" "${MAJOR}")"

assert_eq "a registry sibling without a type holds the pull request" \
    "unknown" \
    "$(effective_update_type "$(deps_json "")" "$(pin_patch 3.6.0 3.8.0)" "${MAJOR}")"

assert_eq "a name that is only a prefix of another key does not match" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" '-        "@magicsunday/coding-standard-extra": "github:a/b#3.6.0",
+        "@magicsunday/coding-standard-extra": "github:a/b#3.8.0",' "${MAJOR}")"

# The patches come from the pages of the pull request files API. Evidence
# that is missing for one manifest must not be replaced by the evidence of
# another one, so a manifest without a patch empties the whole answer.
pages_json() {
    jq -cn --argjson files "$1" '[$files]'
}

assert_eq "the patches of every package.json are returned" \
    "-a
+b
-c
+d" \
    "$(package_json_patches "$(pages_json '[{"filename":"package.json","patch":"-a\n+b"},{"filename":"packages/x/package.json","patch":"-c\n+d"}]')")"

assert_eq "a file that is not a package.json is ignored, with or without a patch" \
    "-a
+b" \
    "$(package_json_patches "$(pages_json '[{"filename":"package.json","patch":"-a\n+b"},{"filename":"package-lock.json"},{"filename":"notpackage.json","patch":"-z"}]')")"

assert_eq "malformed file pages empty the answer" \
    "" \
    "$(set -e; package_json_patches 'not json' 2>/dev/null)"


report_and_exit "auto-merge update-type tests"
