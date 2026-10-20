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

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
readonly WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/auto-merge-deps.yml"

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

# A malformed answer of the metadata action must hold the pull request, also
# in the way the workflow calls the function: inside a command substitution,
# where `set -e` of the caller does not apply.
for malformed in 'not json' '{"a":1}' '[1]' 'null' ''; do
    assert_eq "malformed dependency list '${malformed}' holds the pull request" \
        "unknown" \
        "$(set -e; effective_update_type "${malformed}" "" "${MAJOR}" 2>/dev/null)"
done

assert_eq "a group without a git pin returns the group type, not a recomputed one" \
    "${MAJOR}" \
    "$(effective_update_type '[{"dependencyName":"jscpd","updateType":"version-update:semver-patch","prevVersion":"5.4.0","newVersion":"5.4.1"}]' '' "${MAJOR}")"

assert_eq "a non-string version of a dependency does not break the classification" \
    "${MINOR}" \
    "$(set -e; effective_update_type '[{"dependencyName":"rollup","updateType":"version-update:semver-minor","newVersion":1}]' '' "${MINOR}")"

assert_eq "a short tag against its zero-padded form is the same tag" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 3.6 3.6.0)" "${MAJOR}")"

assert_eq "a zero-padded tag against a patch bump is patch" \
    "${PATCH}" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 3.6 3.6.1)" "${MAJOR}")"

# Two pins on one line, as in a minified package.json: each pin reads its own
# value, so the major bump of the first one is not hidden by the second one.
two_pins_json="$(jq -cn '[
    {dependencyName: "breaking", updateType: "version-update:semver-major", prevVersion: "1.0.0", newVersion: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    {dependencyName: "safe", updateType: "version-update:semver-major", prevVersion: "1.0.0", newVersion: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
]')"
two_pins_patch='-{"dependencies":{"breaking":"github:owner/breaking#1.0.0","safe":"github:owner/safe#1.0.0"}}
+{"dependencies":{"breaking":"github:owner/breaking#2.0.0","safe":"github:owner/safe#1.1.0"}}'

assert_eq "two pins on one line are read per key" \
    "${MAJOR}" \
    "$(effective_update_type "${two_pins_json}" "${two_pins_patch}" "${MAJOR}")"

assert_eq "the same pin twice on one line cannot be classified" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" '-{"a":{"@magicsunday/coding-standard":"github:m/c#3.6.0"},"b":{"@magicsunday/coding-standard":"github:m/c#3.6.0"}}
+{"a":{"@magicsunday/coding-standard":"github:m/c#3.8.0"},"b":{"@magicsunday/coding-standard":"github:m/c#3.8.0"}}' "${MAJOR}")"

# A pin that moves to a lower tag is no bump. Dependabot can propose an older
# tag for a git pin, and such a group must not merge as a minor update.
assert_eq "a minor downgrade of a git pin cannot be classified" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 1.5.0 1.3.0)" "${MAJOR}")"

assert_eq "a major downgrade of a git pin cannot be classified" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 2.0.0 1.0.0)" "${MAJOR}")"

assert_eq "a patch downgrade of a git pin cannot be classified" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 1.3.2 1.3.1)" "${MAJOR}")"

assert_eq "tags that are equal as numbers cannot be classified" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 3.06.0 3.6.0)" "${MAJOR}")"

assert_eq "a zero-padded patch component is read as a decimal number" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 1.2.08 1.2.8)" "${MAJOR}")"

assert_eq "a tag component of more than nine digits cannot be classified" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 1.2.1000000000 1.2.1000000001)" "${MAJOR}")"

# A group member whose type is absent or null cannot be classified, whatever
# the type of the other members is.
for missing_type in '{"dependencyName": "jscpd", "newVersion": "5.4.1"}' '{"dependencyName": "jscpd", "updateType": null, "newVersion": "5.4.1"}'; do
    assert_eq "a member without a usable type holds the group: ${missing_type}" \
        "unknown" \
        "$(effective_update_type "$(jq -cn --argjson sibling "${missing_type}" --arg hash "${HASH}" '[{dependencyName: "@magicsunday/coding-standard", updateType: "version-update:semver-major", prevVersion: "3.6.0", newVersion: $hash}, $sibling]')" "$(pin_patch 3.6.0 3.8.0)" "${MAJOR}")"
done

assert_eq "a major component of more than nine digits cannot be classified" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 1000000000.0.0 1000000001.0.0)" "${MAJOR}")"

assert_eq "a one-component new tag against its zero-padded form is the same tag" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 3.0 3)" "${MAJOR}")"

# Unknown ranks above a major: a major pin next to a member without a type
# stays open as unknown, not as a plain major.
assert_eq "a major pin next to a member without a type is unknown" \
    "unknown" \
    "$(effective_update_type "$(deps_json "")" "$(pin_patch 3.6.0 4.0.0)" "${MINOR}")"

# Two metadata entries of one name share one manifest change, so the second
# one has no tag pair of its own. The group cannot be classified then.
same_name_json="$(jq -cn '[
    {dependencyName: "pin", updateType: "version-update:semver-major", prevVersion: "1.0.0", newVersion: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    {dependencyName: "pin", updateType: "version-update:semver-major", prevVersion: "x", newVersion: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
]')"
assert_eq "two metadata entries of one pin name cannot be classified" \
    "unknown" \
    "$(effective_update_type "${same_name_json}" '-        "pin": "github:owner/repo#1.0.0",
+        "pin": "github:owner/repo#1.1.0",' "${MAJOR}")"

# A name that is the suffix of another key of the manifest must not read the
# tag pair of that other key.
unscoped_json="$(jq -cn --arg hash "${HASH}" '[{dependencyName: "coding-standard", updateType: "version-update:semver-major", prevVersion: "3.6.0", newVersion: $hash}]')"
assert_eq "an unscoped name does not read the tag pair of a scoped key" \
    "unknown" \
    "$(effective_update_type "${unscoped_json}" '-        "@magicsunday/coding-standard": "github:magicsunday/coding-standard#3.6.0",
+        "@magicsunday/coding-standard": "github:magicsunday/coding-standard#3.8.0",' "${MAJOR}")"

# Components that start with a zero and hold an eight or a nine are no octal
# numbers, in every component of both tags.
assert_eq "zero-padded major components are read as decimal numbers" \
    "${MAJOR}" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 08.0.0 09.0.0)" "${MAJOR}")"

assert_eq "zero-padded minor components are read as decimal numbers" \
    "${MINOR}" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 3.08.0 3.09.0)" "${MAJOR}")"

assert_eq "zero-padded patch components are read as decimal numbers" \
    "${PATCH}" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 1.2.08 1.2.09)" "${MAJOR}")"

# Missing components count as zero on both sides.
assert_eq "a one-component tag against a patch bump is a patch bump" \
    "${PATCH}" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 3 3.0.1)" "${MAJOR}")"

assert_eq "a one-component tag against its zero-padded form is the same tag" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 3 3.0)" "${MAJOR}")"

assert_eq "a one-component new tag against a major bump is a major bump" \
    "${MAJOR}" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 3.6.0 4)" "${MAJOR}")"

assert_eq "a full tag against its shortened form is the same tag" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 3.6.0 3.6)" "${MAJOR}")"

assert_eq "a tag with more components than the pattern admits cannot be classified" \
    "unknown" \
    "$(effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 1.2.3.4 1.2.3.5)" "${MAJOR}")"

# Only a string of exactly the length of a commit hash counts as one.
for not_a_hash in "$(printf 'a%.0s' {1..39})" "$(printf 'a%.0s' {1..41})" "z$(printf 'a%.0s' {1..40})"; do
    assert_eq "a ${#not_a_hash} character version is no commit hash" \
        "${MAJOR}" \
        "$(effective_update_type "$(jq -cn --arg version "${not_a_hash}" '[{dependencyName: "jscpd", updateType: "version-update:semver-major", prevVersion: "1.0.0", newVersion: $version}]')" '' "${MAJOR}")"
done

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

assert_eq "a package.json without a patch empties the answer" \
    "" \
    "$(package_json_patches "$(pages_json '[{"filename":"package.json","patch":"-a\n+b"},{"filename":"packages/x/package.json"}]')")"

assert_eq "a file that is not a package.json is ignored, with or without a patch" \
    "-a
+b" \
    "$(package_json_patches "$(pages_json '[{"filename":"package.json","patch":"-a\n+b"},{"filename":"package-lock.json"},{"filename":"notpackage.json","patch":"-z"}]')")"

assert_eq "malformed file pages empty the answer" \
    "" \
    "$(set -e; package_json_patches 'not json' 2>/dev/null)"

# The files API answers in pages, a manifest can sit on any of them.
assert_eq "a manifest on a later page is read" \
    "-a
+b" \
    "$(package_json_patches '[[{"filename":"README.md"}],[{"filename":"package.json","patch":"-a\n+b"}]]')"

assert_eq "a manifest without a patch on a later page empties the answer" \
    "" \
    "$(package_json_patches '[[{"filename":"package.json","patch":"-a\n+b"}],[{"filename":"packages/x/package.json"}]]')"

# One pin, two manifests, the second without a patch: the second one could
# hold a major bump of the same dependency, so the group cannot be classified.
omitted_patch="$(package_json_patches "$(pages_json '[{"filename":"packages/current/package.json","patch":"-        \"pin\": \"github:owner/repo#2.0.0\",\n+        \"pin\": \"github:owner/repo#2.1.0\","},{"filename":"packages/legacy/package.json"}]')")"
single_pin_json="$(jq -cn '[{dependencyName: "pin", updateType: "version-update:semver-major", prevVersion: "2.0.0", newVersion: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]')"
assert_eq "a pin is not classified while a manifest patch is missing" \
    "unknown" \
    "$(effective_update_type "${single_pin_json}" "${omitted_patch}" "${MAJOR}")"

# A member without a string version is no pin. A group made of such members
# keeps the type of the action, also in a caller that runs under errexit.
for no_version in '{"dependencyName": "x", "updateType": "version-update:semver-minor", "newVersion": null}' '{"dependencyName": "x", "updateType": "version-update:semver-minor"}'; do
    assert_eq "a member without a version keeps the group type: ${no_version}" \
        "${MINOR}" \
        "$(set -e; effective_update_type "[${no_version}]" '' "${MINOR}" 2>&1)"
done

assert_eq "a member without a version next to a pin is read by its own type" \
    "${MINOR}" \
    "$(effective_update_type "$(jq -cn --arg hash "${HASH}" '[{dependencyName: "@magicsunday/coding-standard", updateType: "version-update:semver-major", prevVersion: "3.6.0", newVersion: $hash}, {dependencyName: "x", updateType: "version-update:semver-minor", newVersion: null}]')" "$(pin_patch 3.6.0 3.8.0)" "${MAJOR}")"

# JSON allows white space between a key and its colon. Such a key counts like
# any other and must neither hide a second declaration nor be missed.
assert_eq "a key with white space before its colon is read" \
    "${MINOR}" \
    "$(effective_update_type "${single_pin_json}" '-        "pin" : "github:owner/repo#1.0.0",
+        "pin" : "github:owner/repo#1.1.0",' "${MAJOR}")"

assert_eq "a spaced key counts as a second declaration of the same name" \
    "unknown" \
    "$(effective_update_type "${single_pin_json}" '-        "pin": "github:owner/repo#2.0.0",
+        "pin": "github:owner/repo#2.1.0",
-        "pin" : "github:owner/repo#1.0.0",
+        "pin" : "github:owner/repo#2.1.0",' "${MAJOR}")"

# Tags of two different sources say nothing about each other, so a pin that
# moves to another repository cannot be classified from its tags.
assert_eq "a pin that changes its source cannot be classified" \
    "unknown" \
    "$(effective_update_type "${single_pin_json}" '-        "pin": "github:owner/original#1.0.0",
+        "pin": "github:owner/replacement#1.1.0",' "${MAJOR}")"

assert_eq "a pin that keeps its source is classified by its tags" \
    "${MINOR}" \
    "$(effective_update_type "${single_pin_json}" '-        "pin": "github:owner/original#1.0.0",
+        "pin": "github:owner/original#1.1.0",' "${MAJOR}")"

# The workflow assigns the answer in a step that runs under errexit, so every
# answer, also an unclassifiable one, has to end with a zero status.
returns_zero() {
    local description="$1"
    shift
    local status=0

    "$@" >/dev/null 2>&1 || status=$?
    assert_eq "${description} answers with a zero status" "0" "${status}"
}

returns_zero "a malformed dependency list" effective_update_type 'not json' '' "${MAJOR}"
returns_zero "a group without a git pin" effective_update_type '[]' '' "${MINOR}"
returns_zero "a group with repeated pin names" effective_update_type "${same_name_json}" '' "${MAJOR}"
returns_zero "a group with a classified pin" effective_update_type "$(deps_json "${PATCH}")" "$(pin_patch 3.6.0 3.8.0)" "${MAJOR}"
returns_zero "a group with an unclassifiable pin" effective_update_type "$(deps_json "${PATCH}")" '' "${MAJOR}"

# The auto-merge step must decide on the classified type. Reading the group
# type of the metadata action again would bring the original defect back, and
# no assertion on the function above would notice.
enable_step="$(extract_block '- name: Enable auto-merge for patch' 'run: gh pr merge' "${WORKFLOW_FILE}")"
assert_eq "the auto-merge condition reads the classified type" \
    "2" \
    "$(printf '%s\n' "${enable_step}" | grep -c 'steps.classify.outputs.update-type ==')"
assert_eq "the auto-merge condition does not read the group type of the metadata action" \
    "0" \
    "$(printf '%s\n' "${enable_step}" | grep -c 'steps.metadata.outputs.update-type')"
assert_contains "the auto-merge condition admits the patch and the minor type" \
    "${enable_step}" \
    "steps.classify.outputs.update-type == 'version-update:semver-patch'" \
    "steps.classify.outputs.update-type == 'version-update:semver-minor'"
assert_eq "the auto-merge condition does not admit the major type" \
    "0" \
    "$(printf '%s\n' "${enable_step}" | grep -c 'semver-major')"

# The wiring of the classify step, pinned where a change would break it without
# any test of the function noticing.
classify_step="$(extract_block '- name: Classify the update type' 'update-type=' "${WORKFLOW_FILE}")"
checkout_step="$(extract_block '- name: Check out the shared scripts' 'persist-credentials' "${WORKFLOW_FILE}")"
assert_eq "the classify step has exactly the id that the condition reads" \
    "1" \
    "$(printf '%s\n' "${classify_step}" | grep -c '^ *id: classify$')"
# The needles are literal workflow text, so the dollar signs must not expand.
# shellcheck disable=SC2016
assert_contains "the classify step binds its inputs and fails on any error" \
    "${classify_step}" \
    'DEPENDENCIES_JSON: ${{ steps.metadata.outputs.updated-dependencies-json }}' \
    'GROUP_UPDATE_TYPE: ${{ steps.metadata.outputs.update-type }}' \
    'set -euo pipefail'
# shellcheck disable=SC2016
assert_contains "the shared checkout is pinned to the revision of the workflow and lands where it is sourced" \
    "${checkout_step}" \
    'ref: ${{ job.workflow_sha }}' \
    'path: .magicsunday-shared' \
    'sparse-checkout: .github/scripts/lib'
assert_contains "the classify step sources the file of the shared checkout" \
    "${classify_step}" \
    'source .magicsunday-shared/.github/scripts/lib/auto-merge-update-type.sh'

# Running the run block of the classify step against a stubbed gh and a fake
# output file shows what the step publishes, with the inputs wired as the
# workflow does. The block is cut out of the workflow file itself.
classify_run_body="$(awk '
    /- name: Classify the update type/ { found = 1 }
    found && /run: \|/ { in_run = 1; next }
    in_run { sub(/^                  /, ""); print; if ($0 ~ /GITHUB_OUTPUT/) exit }
' "${WORKFLOW_FILE}")"

# Prints "status|published" for one run of the step. Arguments: the dependency
# list, the group type, the pages the stub answers with and, when set, a flag
# that makes the stub fail. The stub script text is written out as it is, so
# nothing in it may expand.
# shellcheck disable=SC2016
run_classify_step() {
    local work status
    work="$(mktemp -d)"
    mkdir -p "${work}/bin" "${work}/.magicsunday-shared/.github/scripts/lib"
    cp "${SCRIPT_DIR}/../lib/auto-merge-update-type.sh" "${work}/.magicsunday-shared/.github/scripts/lib/"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'case "$*" in *"api --paginate --slurp repos/o/r/pulls/7/files"*) ;; *) echo "unexpected call: $*" >&2; exit 9 ;; esac' \
        'if [ -n "${GH_STUB_FAIL:-}" ]; then exit 1; fi' \
        'printf "%s\n" "${GH_STUB_PAGES}"' >"${work}/bin/gh"
    chmod +x "${work}/bin/gh"
    printf '%s\n' "${classify_run_body}" >"${work}/step.sh"
    status=0
    (
        cd "${work}" || exit 1
        PATH="${work}/bin:${PATH}" GITHUB_OUTPUT="${work}/published" PULL_REQUEST_FILES="repos/o/r/pulls/7/files" \
            GH_TOKEN="token" DEPENDENCIES_JSON="$1" GROUP_UPDATE_TYPE="$2" GH_STUB_PAGES="$3" GH_STUB_FAIL="${4:-}" \
            bash -eo pipefail step.sh >/dev/null 2>&1
    ) || status=$?
    printf '%s|%s' "${status}" "$(cat "${work}/published" 2>/dev/null)"
    rm -rf "${work}"
}

pin_pages="$(jq -cn --arg patch "$(pin_patch 3.6.0 3.8.0)" '[[{filename: "package.json", patch: $patch}]]')"

assert_eq "the classify step publishes the type of a pin group from the tags" \
    "0|update-type=${MINOR}" \
    "$(run_classify_step "$(deps_json "${PATCH}")" "${MAJOR}" "${pin_pages}")"

assert_eq "the classify step passes the group type through without a dependency list" \
    "0|update-type=${MINOR}" \
    "$(run_classify_step '' "${MINOR}" '[[]]')"

assert_eq "the classify step does not publish when the files call fails" \
    "1|" \
    "$(run_classify_step "$(deps_json "${PATCH}")" "${MAJOR}" "${pin_pages}" fail)"

report_and_exit "auto-merge update-type tests"
