#!/usr/bin/env bash
# Exercises check_canonical_drift() and its helpers
# (.github/scripts/lib/canonical-drift.sh), the account-wide canonical-file
# sweep canonical-drift.yml runs (issue #87). `gh` is replaced by a shell
# function serving fixture responses, so every API shape - found, 404, a
# failed request - is driven deterministically. Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"
# shellcheck source=../lib/canonical-drift.sh
source "${SCRIPT_DIR}/../lib/canonical-drift.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1

work_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "${work_dir}"' EXIT

# Fixture store: one file per endpoint, named after the endpoint with every
# `/`, `?`, `&` and `=` turned into `_`. `<key>.json` answers 200 with that
# body, `<key>.500` fails the request, and no file at all answers 404 - the
# contents API's answer for an absent path. Every request is also appended
# to `requests.log` in the store, so a case can assert that none was made.
fixtures=""

# Only the summary cases below may write a job summary. On a runner the
# variable is already set, and every other sweep here would append a fake
# report to the real shell-tests job summary.
unset GITHUB_STEP_SUMMARY

gh() {
    [ "$1" = "api" ] || return 99
    shift
    local endpoint="" jq_filter="" key
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --paginate) shift ;;
            --jq) jq_filter="$2"; shift 2 ;;
            *) endpoint="$1"; shift ;;
        esac
    done
    key="$(printf '%s' "${endpoint}" | tr '/?&=' '____')"
    printf '%s\n' "${endpoint}" >>"${fixtures}/requests.log"

    if [ -f "${fixtures}/${key}.500" ]; then
        echo "gh: Server Error (HTTP 500)" >&2
        return 1
    fi
    if [ -f "${fixtures}/${key}.json" ]; then
        if [ -n "${jq_filter}" ]; then
            jq -r "${jq_filter}" "${fixtures}/${key}.json"
        else
            cat "${fixtures}/${key}.json"
        fi
        return 0
    fi
    echo '{"message":"Not Found"}'
    echo "gh: Not Found (HTTP 404)" >&2
    return 1
}

# A fresh canonical root holding one canonical file, and a manifest for it.
canonical="${work_dir}/canonical"
mkdir -p "${canonical}/.github"
printf 'rules:\n  unpinned-uses: {}\n' >"${canonical}/.github/zizmor.yml"
canonical_sha="$(canonical_blob_sha "${canonical}" .github/zizmor.yml)"

manifest="${work_dir}/manifest.json"
write_manifest() {
    printf '%s' "$1" >"${manifest}"
}
default_manifest='{"files":[{"path":".github/zizmor.yml","applies_when_present":".github/workflows"}]}'

new_fixtures() {
    fixtures="$(mktemp -d "${work_dir}/fx.XXXXXX")"
}
fixture() {
    local key
    key="$(printf '%s' "$1" | tr '/?&=' '____')"
    rm -f "${fixtures}/${key}.500"
    printf '%s' "$2" >"${fixtures}/${key}.json"
}
fixture_error() {
    local key
    key="$(printf '%s' "$1" | tr '/?&=' '____')"
    rm -f "${fixtures}/${key}.json"
    : >"${fixtures}/${key}.500"
}
repo_list() {
    fixture "users/acme/repos?type=owner&per_page=100" "$1"
}
has_workflows() {
    fixture "repos/acme/$1/contents/.github/workflows" '[{"name":"ci.yml","type":"file"}]'
}
zizmor_file() {
    fixture "repos/acme/$1/contents/.github/zizmor.yml" "{\"type\":\"file\",\"sha\":\"$2\"}"
}

# Runs the sweep the way canonical-drift.yml does: a fresh shell under
# `set -euo pipefail` that sources the lib and calls the function as a plain
# command. Calling it inside `$(...)` from this file would clear errexit and
# hide every abort the workflow would hit.
lib="${SCRIPT_DIR}/../lib/canonical-drift.sh"
export -f gh
export fixtures
run_sweep() {
    output="$(bash -c 'set -euo pipefail; . "$1"; shift; check_canonical_drift "$@"' _ \
        "${lib}" "${manifest}" "${canonical}" acme .github 2>&1)"
    rc=$?
}

# --- the blob hash matches what git itself stores for this repository ---
expected_blob="$(git -C "${REPO_ROOT}" rev-parse HEAD:.github/zizmor.yml 2>/dev/null || true)"
if [ -n "${expected_blob}" ] && git -C "${REPO_ROOT}" diff --quiet HEAD -- .github/zizmor.yml; then
    assert_eq "canonical_blob_sha equals git's own blob id for .github/zizmor.yml" \
        "${expected_blob}" "$(canonical_blob_sha "${REPO_ROOT}" .github/zizmor.yml)"
fi

# --- a CRLF checkout still hashes to the LF blob git stores ---
crlf_repo="${work_dir}/crlf"
git init -q "${crlf_repo}"
printf 'a\nb\n' >"${crlf_repo}/f.yml"
git -C "${crlf_repo}" add f.yml
git -C "${crlf_repo}" -c user.email=test@example.invalid -c user.name=test -c commit.gpgsign=false commit -qm Init
echo '*.yml text eol=crlf' >"${crlf_repo}/.gitattributes"
rm -f "${crlf_repo}/f.yml"
git -C "${crlf_repo}" checkout -- f.yml
assert_eq "CRLF checkout: canonical_blob_sha equals the stored LF blob" \
    "$(git -C "${crlf_repo}" rev-parse HEAD:f.yml)" "$(canonical_blob_sha "${crlf_repo}" f.yml)"

# --- the repository filter drops archived repositories and forks ---
filtered="$(jq -r "${CANONICAL_DRIFT_REPO_FILTER}" <<<'[{"name":"a","archived":false,"fork":false},{"name":"b","archived":true,"fork":false},{"name":"c","archived":false,"fork":true}]')"
assert_eq "repo filter keeps only non-archived, non-fork repositories" "a" "${filtered}"

# --- this repository's own manifest is valid against its own tree ---
if assert_canonical_manifest_valid "${REPO_ROOT}/.github/canonical-files.json" "${REPO_ROOT}" >/dev/null; then r=0; else r=1; fi
assert_eq "the committed .github/canonical-files.json names only files that exist here" 0 "${r}"

# --- all in-scope repositories match ---
write_manifest "${default_manifest}"
new_fixtures
repo_list '[{"name":"one","archived":false,"fork":false},{"name":"two","archived":false,"fork":false},{"name":".github","archived":false,"fork":false}]'
has_workflows one; zizmor_file one "${canonical_sha}"
has_workflows two; zizmor_file two "${canonical_sha}"
# The source repository itself is never compared against its own copy: give
# it workflows and a drifted file, which would fail the sweep if it were.
has_workflows .github; zizmor_file .github "0000000000000000000000000000000000000000"
run_sweep
assert_eq "all matching: exit 0" 0 "${rc}"
assert_contains "all matching: reports two checked files" "${output}" "2 canonical file(s)"

# --- a missing file fails and names the repository ---
new_fixtures
repo_list '[{"name":"one","archived":false,"fork":false},{"name":"two","archived":false,"fork":false}]'
has_workflows one; zizmor_file one "${canonical_sha}"
has_workflows two
run_sweep
assert_eq "missing file: exit 1" 1 "${rc}"
assert_contains "missing file: names repository and path" "${output}" "acme/two: .github/zizmor.yml is missing"

# --- every failing repository is reported, not only the first ---
new_fixtures
repo_list '[{"name":"one","archived":false,"fork":false},{"name":"two","archived":false,"fork":false}]'
has_workflows one; zizmor_file one "0000000000000000000000000000000000000000"
has_workflows two
run_sweep
assert_eq "two failures: exit 1" 1 "${rc}"
assert_contains "two failures: first repository reported" "${output}" "acme/one: .github/zizmor.yml differs from the canonical copy"
assert_contains "two failures: second repository reported" "${output}" "acme/two: .github/zizmor.yml is missing"

# --- a drifted file fails ---
new_fixtures
repo_list '[{"name":"one","archived":false,"fork":false}]'
has_workflows one; zizmor_file one "0000000000000000000000000000000000000000"
run_sweep
assert_eq "drifted file: exit 1" 1 "${rc}"
assert_contains "drifted file: says it differs" "${output}" "acme/one: .github/zizmor.yml differs from the canonical copy"

# --- a path the contents API reports as a symlink (its target is not a
# regular file) or as a directory is not the canonical file ---
new_fixtures
repo_list '[{"name":"one","archived":false,"fork":false},{"name":"two","archived":false,"fork":false}]'
has_workflows one; fixture "repos/acme/one/contents/.github/zizmor.yml" "{\"type\":\"symlink\",\"sha\":\"${canonical_sha}\"}"
has_workflows two; fixture "repos/acme/two/contents/.github/zizmor.yml" '[{"name":"x","type":"file"}]'
run_sweep
assert_eq "symlink/directory: exit 1" 1 "${rc}"
assert_contains "symlink to a non-file: reported as not a regular file" "${output}" "acme/one: .github/zizmor.yml exists but is not a regular file"
assert_contains "directory: reported as not a regular file" "${output}" "acme/two: .github/zizmor.yml exists but is not a regular file"

# --- a repository without workflows is out of scope for zizmor.yml ---
new_fixtures
repo_list '[{"name":"one","archived":false,"fork":false},{"name":"docs-only","archived":false,"fork":false}]'
has_workflows one; zizmor_file one "${canonical_sha}"
run_sweep
assert_eq "no workflows: not applicable, exit 0" 0 "${rc}"
assert_contains "no workflows: one file checked" "${output}" "1 canonical file(s)"

# --- a failed request is unchecked, never missing and never fine ---
new_fixtures
repo_list '[{"name":"one","archived":false,"fork":false}]'
has_workflows one; fixture_error "repos/acme/one/contents/.github/zizmor.yml"
run_sweep
assert_eq "file fetch error: exit 1" 1 "${rc}"
assert_contains "file fetch error: reported as unchecked" "${output}" "fetching .github/zizmor.yml failed, so it went unchecked"

new_fixtures
repo_list '[{"name":"one","archived":false,"fork":false}]'
fixture_error "repos/acme/one/contents/.github/workflows"
run_sweep
assert_eq "applicability fetch error: exit 1" 1 "${rc}"
assert_contains "applicability fetch error: reported as unchecked" "${output}" "could not check whether .github/workflows exists"

# --- listing failures and empty scopes never pass ---
new_fixtures
fixture_error "users/acme/repos?type=owner&per_page=100"
run_sweep
assert_eq "repo listing error: exit 1" 1 "${rc}"
assert_contains "repo listing error: says nothing was checked" "${output}" "nothing was checked"

new_fixtures
repo_list '[]'
run_sweep
assert_eq "empty repo list: exit 1" 1 "${rc}"
assert_contains "empty repo list: says the sweep checked nothing" "${output}" "the sweep checked nothing"

# Without applies_when_present an empty listing line would be fetched as the
# repository "", so the empty-line skip is what keeps this at "checked nothing".
write_manifest '{"files":[{"path":".github/zizmor.yml"}]}'
summary="${work_dir}/summary-empty.md"
: >"${summary}"
GITHUB_STEP_SUMMARY="${summary}" run_sweep
assert_eq "empty repo list, no applicability: exit 1" 1 "${rc}"
assert_contains "empty repo list, no applicability: says the sweep checked nothing" "${output}" "the sweep checked nothing"
case "${output}" in
    *"acme/:"*) r=fetched ;;
    *) r=skipped ;;
esac
assert_eq "empty repo list: no request for an empty repository name" skipped "${r}"
case "$(cat "${summary}")" in
    *"| Repository | File | Result |"*) r=table ;;
    *) r=no-table ;;
esac
assert_eq "empty repo list: summary has no empty table" no-table "${r}"
write_manifest "${default_manifest}"

# --- manifest validation: each problem is named by its own message ---
validate() {
    output="$(assert_canonical_manifest_valid "${manifest}" "${canonical}" 2>&1)"
    rc=$?
}

write_manifest '{"files":[]}'
validate
assert_eq "empty manifest: rejected" 1 "${rc}"
assert_contains "empty manifest: says so" "${output}" "lists no canonical files"

write_manifest 'not json'
validate
assert_eq "manifest not JSON: rejected" 1 "${rc}"
assert_contains "manifest not JSON: says so" "${output}" "is not valid JSON"

write_manifest '{"files":[{"path":5}]}'
validate
assert_eq "manifest path not a string: rejected" 1 "${rc}"
assert_contains "manifest path not a string: says so" "${output}" 'has no string "path"'

write_manifest '{"files":[{"path":".github/absent.yml"}]}'
validate
assert_eq "manifest path absent here: rejected" 1 "${rc}"
assert_contains "manifest path absent here: says so" "${output}" "is not a regular file in this repository"

ln -s zizmor.yml "${canonical}/.github/link.yml"
write_manifest '{"files":[{"path":".github/link.yml"}]}'
validate
assert_eq "manifest path is a symlink: rejected" 1 "${rc}"
assert_contains "manifest path is a symlink: says so" "${output}" "is not a regular file in this repository"
rm -f "${canonical}/.github/link.yml"

for applies in false 5 '""'; do
    write_manifest "{\"files\":[{\"path\":\".github/zizmor.yml\",\"applies_when_present\":${applies}}]}"
    validate
    assert_eq "applies_when_present ${applies}: rejected" 1 "${rc}"
    assert_contains "applies_when_present ${applies}: says so" "${output}" "applies_when_present must be a non-empty string"
done

write_manifest "${default_manifest}"
validate
assert_eq "valid manifest: accepted" 0 "${rc}"

# --- an invalid manifest stops the sweep before any request ---
# The manifest is invalid only in a field the rest of the sweep would
# silently tolerate, and the fixtures would let that sweep pass, so only the
# early stop can make this case fail.
write_manifest '{"files":[{"path":".github/zizmor.yml","applies_when_present":false}]}'
new_fixtures
repo_list '[{"name":"one","archived":false,"fork":false}]'
zizmor_file one "${canonical_sha}"
run_sweep
assert_eq "invalid manifest: sweep exits 1" 1 "${rc}"
assert_contains "invalid manifest: sweep names the problem" "${output}" "applies_when_present must be a non-empty string"
case "${output}" in
    *"canonical file(s)"*) r=swept ;;
    *) r=stopped ;;
esac
assert_eq "invalid manifest: sweep never reaches its result line" stopped "${r}"
if [ -e "${fixtures}/requests.log" ]; then r=requested; else r=none; fi
assert_eq "invalid manifest: no API request is made" none "${r}"

# --- every manifest entry is checked, not only the first ---
printf 'other: true\n' >"${canonical}/.github/other.yml"
other_sha="$(canonical_blob_sha "${canonical}" .github/other.yml)"
write_manifest '{"files":[{"path":".github/zizmor.yml"},{"path":".github/other.yml"}]}'
new_fixtures
repo_list '[{"name":"one","archived":false,"fork":false}]'
zizmor_file one "${canonical_sha}"
fixture "repos/acme/one/contents/.github/other.yml" "{\"type\":\"file\",\"sha\":\"0000000000000000000000000000000000000000\"}"
run_sweep
assert_eq "two manifest entries, second drifted: exit 1" 1 "${rc}"
assert_contains "two manifest entries: second entry reported" "${output}" "acme/one: .github/other.yml differs from the canonical copy"
fixture "repos/acme/one/contents/.github/other.yml" "{\"type\":\"file\",\"sha\":\"${other_sha}\"}"
run_sweep
assert_eq "two manifest entries, both matching: exit 0" 0 "${rc}"
assert_contains "two manifest entries: both counted" "${output}" "2 canonical file(s)"
rm -f "${canonical}/.github/other.yml"

# --- the summary names every outcome and counts only what was checked ---
write_manifest "${default_manifest}"
new_fixtures
repo_list '[{"name":"ok-repo","archived":false,"fork":false},{"name":"drift","archived":false,"fork":false},{"name":"gone","archived":false,"fork":false},{"name":"flaky","archived":false,"fork":false},{"name":"docs","archived":false,"fork":false},{"name":"probe-error","archived":false,"fork":false},{"name":"link","archived":false,"fork":false}]'
has_workflows ok-repo; zizmor_file ok-repo "${canonical_sha}"
has_workflows drift; zizmor_file drift "0000000000000000000000000000000000000000"
has_workflows gone
has_workflows flaky; fixture_error "repos/acme/flaky/contents/.github/zizmor.yml"
fixture_error "repos/acme/probe-error/contents/.github/workflows"
has_workflows link; fixture "repos/acme/link/contents/.github/zizmor.yml" "{\"type\":\"symlink\",\"sha\":\"${canonical_sha}\"}"
summary="${work_dir}/summary.md"
: >"${summary}"
GITHUB_STEP_SUMMARY="${summary}" run_sweep
summary_text="$(cat "${summary}")"
assert_eq "summary run: exit 1" 1 "${rc}"
assert_contains "summary: counts answered requests (found or missing) as checked, failed ones as unchecked" "${summary_text}" "4 file(s) checked, 3 failed (drifted, missing or not a regular file), 2 unchecked"
assert_contains "summary: table header" "${summary_text}" "| Repository | File | Result |"
assert_contains "summary: ok row" "${summary_text}" "| ok-repo | \`.github/zizmor.yml\` | ok |"
assert_contains "summary: drifted row" "${summary_text}" "| drift | \`.github/zizmor.yml\` | **drifted** |"
assert_contains "summary: missing row" "${summary_text}" "| gone | \`.github/zizmor.yml\` | **missing** |"
assert_contains "summary: unchecked row" "${summary_text}" "| flaky | \`.github/zizmor.yml\` | **unchecked** (API error) |"
assert_contains "summary: not-a-file row" "${summary_text}" "| link | \`.github/zizmor.yml\` | **not a regular file** |"
assert_contains "summary: applicability error row" "${summary_text}" "| probe-error | \`.github/zizmor.yml\` | **unchecked** (API error) |"
assert_contains "summary: not-applicable row" "${summary_text}" "| docs | \`.github/zizmor.yml\` | not applicable (no \`.github/workflows\`) |"

# --- template sets: the shared files of the ZIP webtrees modules ---
# The canonical content is the template directory of another repository, read
# through the API. Every file of it but the exclusions is compared with the
# same path in each named module. A .php file is rendered with the module's
# MODULE_NAME and MODULE_NS first, so only the identity lines may differ.
template_dir="templates/webtrees-module"
blob_of() {
    printf '%s' "$1" | git hash-object --stdin
}
base64_of() {
    printf '%s' "$1" | base64 | tr -d '\n'
}
tpl_makefile=$'all:\n\techo build\n'
tpl_php=$'<?php\n/**\n * This file is part of the package magicsunday/webtrees-<name>.\n */\n\nnamespace MagicSunday\\Webtrees\\ModuleName\\Test\\Release;\n'
php_for() {
    printf '%s' "${tpl_php}" | sed -e "s/webtrees-<name>/$1/g" -e "s/Webtrees\\\\ModuleName\\\\/Webtrees\\\\$2\\\\/g"
}
tpl_makefile_sha="$(blob_of "${tpl_makefile}")"

write_manifest_sets() {
    write_manifest "$(jq -cn --argjson sets "$1" '{files: [{path: ".github/zizmor.yml", applies_when_present: ".github/workflows"}], template_sets: $sets}')"
}
default_sets='[{"source_repository":"coding-standard","source_directory":"templates/webtrees-module","exclude":["module.mk.example"],"parameter_file":"Make/module.mk","repositories":["mod-a","mod-b"]}]'

# Serves the template: a Makefile, one PHP file with identity lines, and the
# parameter example that the sync script never copies.
template_fixtures() {
    fixture "repos/acme/coding-standard/git/trees/HEAD?recursive=1" "$(jq -cn \
        --arg mk "${tpl_makefile_sha}" --arg php "$(blob_of "${tpl_php}")" --arg ex "$(blob_of 'example')" \
        --arg dir "${template_dir}" '{truncated: false, tree: [
            {type: "tree", path: $dir, sha: "t"},
            {type: "tree", path: ($dir + "/Make"), sha: "t"},
            {type: "tree", path: ($dir + "/Make/helper"), sha: "t"},
            {type: "tree", path: ($dir + "/tests"), sha: "t"},
            {type: "tree", path: ($dir + "/tests/Release"), sha: "t"},
            {type: "blob", path: ($dir + "/Makefile"), sha: $mk},
            {type: "blob", path: ($dir + "/tests/Release/A.php"), sha: $php},
            {type: "blob", path: ($dir + "/module.mk.example"), sha: $ex},
            {type: "blob", path: "README.md", sha: "0"}]}')"
    fixture "repos/acme/coding-standard/contents/${template_dir}/tests/Release/A.php" "{\"type\":\"file\",\"content\":\"$(base64_of "${tpl_php}")\"}"
}
# A module with its parameter file and, per argument, the content of each file.
module_fixtures() {
    local repo="$1" name="$2" namespace="$3"
    fixture "repos/acme/${repo}/contents/Make/module.mk" "{\"type\":\"file\",\"content\":\"$(base64_of "MODULE_NAME := ${name}"$'\n'"MODULE_NS := ${namespace}"$'\n')\"}"
    fixture "repos/acme/${repo}/contents/Makefile" "{\"type\":\"file\",\"sha\":\"${tpl_makefile_sha}\"}"
    fixture "repos/acme/${repo}/contents/tests/Release/A.php" "{\"type\":\"file\",\"sha\":\"$(blob_of "$(php_for "${name}" "${namespace}")"$'\n')\"}"
}

write_manifest_sets "${default_sets}"
new_fixtures
repo_list '[]'
template_fixtures
module_fixtures mod-a webtrees-fan-chart Fan
module_fixtures mod-b webtrees-statistics Statistic
run_sweep
assert_eq "template set, in step modules with different identity lines: exit 0" 0 "${rc}"
assert_contains "template set: the template files of both modules are counted" "${output}" "4 canonical file(s)"
case "${output}" in
    *module.mk.example*) r=compared ;;
    *) r=excluded ;;
esac
assert_eq "template set: an excluded file is not compared" excluded "${r}"
assert_eq "template set: a file outside the directory is never requested" 0 \
    "$(grep -c 'README.md' "${fixtures}/requests.log")"
assert_eq "template set: a directory entry of the listing is never requested as a file" 0 \
    "$(grep -cE 'contents/(Make|Make/helper|tests|tests/Release)$' "${fixtures}/requests.log")"

# A module file with other bytes is reported with the module and the file.
fixture "repos/acme/mod-a/contents/Makefile" '{"type":"file","sha":"0000000000000000000000000000000000000000"}'
run_sweep
assert_eq "template set, modified Makefile: exit 1" 1 "${rc}"
assert_contains "template set, modified Makefile: names module and file" "${output}" "::error::acme/mod-a: Makefile differs from the template coding-standard/templates/webtrees-module"
case "${output}" in
    *"acme/mod-b: "*) r=reported ;;
    *) r=quiet ;;
esac
assert_eq "template set, modified Makefile: the unmodified module is not reported" quiet "${r}"

# A PHP file whose identity lines are the template's own placeholder text or
# another module's is a drift, since it differs from the rendering for this module.
module_fixtures mod-a webtrees-fan-chart Fan
fixture "repos/acme/mod-a/contents/tests/Release/A.php" "{\"type\":\"file\",\"sha\":\"$(blob_of "$(php_for webtrees-statistics Statistic)"$'\n')\"}"
run_sweep
assert_eq "template set, PHP file with another module's identity: exit 1" 1 "${rc}"
assert_contains "template set, PHP file with another module's identity: reported" "${output}" "acme/mod-a: tests/Release/A.php differs from the template"

# A body change in a PHP file is a drift as well, not masked away with the identity lines.
module_fixtures mod-a webtrees-fan-chart Fan
fixture "repos/acme/mod-a/contents/tests/Release/A.php" "{\"type\":\"file\",\"sha\":\"$(blob_of "$(php_for webtrees-fan-chart Fan)"$'\n// local edit\n')\"}"
run_sweep
assert_eq "template set, PHP file with a body change: exit 1" 1 "${rc}"

# A missing file is reported.
module_fixtures mod-a webtrees-fan-chart Fan
rm -f "${fixtures}/repos_acme_mod-a_contents_Makefile.json"
run_sweep
assert_eq "template set, missing file: exit 1" 1 "${rc}"
assert_contains "template set, missing file: names module and file" "${output}" "acme/mod-a: Makefile is missing"

# A file that is not a regular file is reported.
module_fixtures mod-a webtrees-fan-chart Fan
fixture "repos/acme/mod-a/contents/Makefile" "{\"type\":\"symlink\",\"sha\":\"${tpl_makefile_sha}\"}"
run_sweep
assert_eq "template set, symlink: exit 1" 1 "${rc}"
assert_contains "template set, symlink: reported" "${output}" "acme/mod-a: Makefile exists but is not a regular file"

# A module without a parameter file cannot be rendered and is a failure.
module_fixtures mod-a webtrees-fan-chart Fan
rm -f "${fixtures}/repos_acme_mod-a_contents_Make_module.mk.json"
run_sweep
assert_eq "template set, no parameter file: exit 1" 1 "${rc}"
assert_contains "template set, no parameter file: says so" "${output}" "acme/mod-a: Make/module.mk is missing"

# Request failures are unchecked and never read as fine.
module_fixtures mod-a webtrees-fan-chart Fan
fixture_error "repos/acme/mod-a/contents/Makefile"
run_sweep
assert_eq "template set, file fetch error: exit 1" 1 "${rc}"
assert_contains "template set, file fetch error: unchecked" "${output}" "fetching Makefile failed, so it went unchecked"

module_fixtures mod-a webtrees-fan-chart Fan
fixture_error "repos/acme/mod-a/contents/Make/module.mk"
run_sweep
assert_eq "template set, parameter fetch error: exit 1" 1 "${rc}"
assert_contains "template set, parameter fetch error: unchecked" "${output}" "fetching Make/module.mk failed"

# An identity parameter that is absent or has the wrong shape is unchecked.
module_fixtures mod-a webtrees-fan-chart Fan
fixture "repos/acme/mod-a/contents/Make/module.mk" "{\"type\":\"file\",\"content\":\"$(base64_of $'MODULE_NAME := not a name\nMODULE_NS := Fan\n')\"}"
run_sweep
assert_eq "template set, unusable MODULE_NAME: exit 1" 1 "${rc}"
assert_contains "template set, unusable MODULE_NAME: unchecked" "${output}" "does not hold a usable MODULE_NAME and MODULE_NS"
fixture "repos/acme/mod-a/contents/Make/module.mk" "{\"type\":\"file\",\"content\":\"$(base64_of $'MODULE_NAME := webtrees-fan-chart\n')\"}"
run_sweep
assert_eq "template set, MODULE_NS absent: exit 1" 1 "${rc}"
assert_contains "template set, MODULE_NS absent: unchecked" "${output}" "does not hold a usable MODULE_NAME and MODULE_NS"

# The parameter file is read the way make reads it: the last assignment wins
# and ?= only sets a name that is still unset.
fixture "repos/acme/mod-a/contents/Make/module.mk" "{\"type\":\"file\",\"content\":\"$(base64_of $'MODULE_NAME := webtrees-old\nMODULE_NS ?= Other\nMODULE_NS := Fan\n  MODULE_NAME = webtrees-fan-chart\nMODULE_NAME ?= webtrees-ignored\n')\"}"
run_sweep
assert_eq "template set, last assignment wins and ?= does not override: exit 0" 0 "${rc}"

# The assignment forms and the trimming of the value. `::=` is an assignment
# like `:=`, trailing blanks and a carriage return are no part of the value.
module_fixtures mod-a webtrees-fan-chart Fan
fixture "repos/acme/mod-a/contents/Make/module.mk" "{\"type\":\"file\",\"content\":\"$(base64_of $'MODULE_NAME ::= webtrees-fan-chart\nMODULE_NS::=Fan\n')\"}"
run_sweep
assert_eq "template set, ::= assignment: exit 0" 0 "${rc}"
fixture "repos/acme/mod-a/contents/Make/module.mk" "{\"type\":\"file\",\"content\":\"$(base64_of $'MODULE_NAME := webtrees-fan-chart \t \nMODULE_NS := Fan  \n')\"}"
run_sweep
assert_eq "template set, trailing blanks are not part of the value: exit 0" 0 "${rc}"
fixture "repos/acme/mod-a/contents/Make/module.mk" "{\"type\":\"file\",\"content\":\"$(base64_of $'MODULE_NAME := webtrees-fan-chart\r\nMODULE_NS := Fan\r\n')\"}"
run_sweep
assert_eq "template set, CRLF line ends are not part of the value: exit 0" 0 "${rc}"

# Each shape rule of the identity parameters rejects its own bad value.
for bad_identity in \
    $'webtrees-Fan|Fan|an uppercase letter in the name' \
    $'webtrees-fan_chart|Fan|an underscore in the name' \
    $'webtrees-|Fan|a name that ends after the prefix' \
    $'webtrees-fan-chart|Fan\\Ns|a backslash in the namespace' \
    $'webtrees-fan-chart|1Fan|a leading digit in the namespace' \
    $'webtrees-fan-chart|Fan;x|a semicolon in the namespace'; do
    IFS='|' read -r bad_name bad_ns bad_what <<<"${bad_identity}"
    module_fixtures mod-a webtrees-fan-chart Fan
    fixture "repos/acme/mod-a/contents/Make/module.mk" "{\"type\":\"file\",\"content\":\"$(base64_of "MODULE_NAME := ${bad_name}"$'\n'"MODULE_NS := ${bad_ns}"$'\n')\"}"
    run_sweep
    assert_eq "template set, ${bad_what}: exit 1" 1 "${rc}"
    assert_contains "template set, ${bad_what}: unchecked" "${output}" "acme/mod-a: Make/module.mk does not hold a usable MODULE_NAME and MODULE_NS"
done

# A failed or truncated template listing never passes.
module_fixtures mod-a webtrees-fan-chart Fan
fixture_error "repos/acme/coding-standard/git/trees/HEAD?recursive=1"
run_sweep
assert_eq "template listing error: exit 1" 1 "${rc}"
assert_contains "template listing error: says the modules went unchecked" "${output}" "Could not list the template acme/coding-standard/templates/webtrees-module completely"

template_fixtures
fixture "repos/acme/coding-standard/git/trees/HEAD?recursive=1" '{"truncated":true,"tree":[]}'
run_sweep
assert_eq "template listing truncated: exit 1" 1 "${rc}"
assert_contains "template listing truncated: unchecked" "${output}" "Could not list the template"

# A template without any file must not pass.
fixture "repos/acme/coding-standard/git/trees/HEAD?recursive=1" '{"truncated":false,"tree":[{"type":"blob","path":"README.md","sha":"0"}]}'
run_sweep
assert_eq "empty template directory: exit 1" 1 "${rc}"
assert_contains "empty template directory: says so" "${output}" "lists no files"

# A template PHP file that cannot be fetched, or a placeholder the rendering does not cover, is unchecked.
template_fixtures
rm -f "${fixtures}/repos_acme_coding-standard_contents_templates_webtrees-module_tests_Release_A.php.json"
run_sweep
assert_eq "template file fetch error: exit 1" 1 "${rc}"
assert_contains "template file fetch error: unchecked" "${output}" "Could not fetch the template file tests/Release/A.php"

template_fixtures
unknown_tpl=$'<?php\n// webtrees-<name> and <name>-other\n'
fixture "repos/acme/coding-standard/contents/${template_dir}/tests/Release/A.php" "{\"type\":\"file\",\"content\":\"$(base64_of "${unknown_tpl}")\"}"
module_fixtures mod-a webtrees-fan-chart Fan
run_sweep
assert_eq "template placeholder left after rendering: exit 1" 1 "${rc}"
assert_contains "template placeholder left after rendering: unchecked" "${output}" "holds a placeholder that is not rendered"

# The report summary carries the template rows.
template_fixtures
module_fixtures mod-a webtrees-fan-chart Fan
module_fixtures mod-b webtrees-statistics Statistic
fixture "repos/acme/mod-b/contents/Makefile" '{"type":"file","sha":"0000000000000000000000000000000000000000"}'
summary="${work_dir}/summary-template.md"
: >"${summary}"
GITHUB_STEP_SUMMARY="${summary}" run_sweep
summary_text="$(cat "${summary}")"
assert_contains "summary: template ok row" "${summary_text}" "| mod-a | \`Makefile\` | ok |"
assert_contains "summary: template drifted row" "${summary_text}" "| mod-b | \`Makefile\` | **drifted** |"
assert_contains "summary: PHP row of an in-step module" "${summary_text}" "| mod-b | \`tests/Release/A.php\` | ok |"

assert_contains "summary: names the template source next to this repository" "${summary_text}" "Compared against \`acme/.github and acme/coding-standard/templates/webtrees-module\`"

# A file path from the template listing is not trusted. A newline in it would
# start a forged annotation line and a pipe would start a new report cell, so
# the path is made safe before it is printed, and the line it sits on is intact.
evil_path=$'evil\n::error::forged%0A|x.txt'
template_fixtures
module_fixtures mod-a webtrees-fan-chart Fan
module_fixtures mod-b webtrees-statistics Statistic
fixture "repos/acme/coding-standard/git/trees/HEAD?recursive=1" "$(jq -cn --arg mk "${tpl_makefile_sha}" --arg dir "${template_dir}" --arg evil "${evil_path}" '{truncated: false, tree: [
    {type: "blob", path: ($dir + "/Makefile"), sha: $mk},
    {type: "blob", path: ($dir + "/" + $evil), sha: "1111111111111111111111111111111111111111"}]}')"
summary="${work_dir}/summary-evil.md"
: >"${summary}"
GITHUB_STEP_SUMMARY="${summary}" run_sweep
assert_eq "template path with a newline: exit 1" 1 "${rc}"
assert_contains "template path with a newline: the annotation carries the path folded to one line, % escaped" "${output}" "::error::acme/mod-a: evil ::error::forged%250A\\|x.txt is missing."
case "${output}" in
    *$'\n::error::forged'*) r=forged ;;
    *) r=intact ;;
esac
assert_eq "template path with a newline: no forged annotation line" intact "${r}"
assert_contains "template path with a pipe: the row cell escapes the pipe" "$(cat "${summary}")" "| mod-a | \`evil ::error::forged%250A\\|x.txt\` | **missing** |"

# --- template_sets validation ---
for bad_case in \
    '[]|template_sets must be a non-empty array.' \
    '{}|template_sets must be a non-empty array.' \
    '[5]|template_sets[0] is not an object.' \
    '[{"source_directory":"d","parameter_file":"p","repositories":["r"]}]|template_sets[0].source_repository must be a non-empty string.' \
    '[{"source_directory":"d","parameter_file":"p","repositories":["r"],"source_repository":""}]|template_sets[0].source_repository must be a non-empty string.' \
    '[{"source_repository":"s","parameter_file":"p","repositories":["r"]}]|template_sets[0].source_directory must be a non-empty string.' \
    '[{"source_repository":"s","parameter_file":"p","repositories":["r"],"source_directory":""}]|template_sets[0].source_directory must be a non-empty string.' \
    '[{"source_repository":"s","source_directory":"d","repositories":["r"]}]|template_sets[0].parameter_file must be a non-empty string.' \
    '[{"source_repository":"s","source_directory":"d","repositories":["r"],"parameter_file":""}]|template_sets[0].parameter_file must be a non-empty string.' \
    '[{"source_repository":"s","source_directory":"d","parameter_file":"p","repositories":[]}]|template_sets[0].repositories must be a non-empty array of names.' \
    '[{"source_repository":"s","source_directory":"d","parameter_file":"p","repositories":[1]}]|template_sets[0].repositories must be a non-empty array of names.' \
    '[{"source_repository":"s","source_directory":"d","parameter_file":"p","repositories":["r"],"exclude":"x"}]|template_sets[0].exclude must be an array of paths.' \
    '[{"source_repository":"s","source_directory":"d","parameter_file":"p","repositories":["r"],"exclude":[1]}]|template_sets[0].exclude must be an array of paths.' \
    '[{"source_repository":"s","source_directory":"d","parameter_file":"p","repositories":["r"],"exclude":[""]}]|template_sets[0].exclude must be an array of paths.'; do
    bad_sets="${bad_case%%|*}"
    bad_message="${bad_case#*|}"
    write_manifest_sets "${bad_sets}"
    validate
    assert_eq "template_sets ${bad_sets}: rejected" 1 "${rc}"
    assert_contains "template_sets ${bad_sets}: names the problem" "${output}" "${bad_message}"
done
write_manifest_sets "${default_sets}"
validate
assert_eq "valid template_sets: accepted" 0 "${rc}"
write_manifest "${default_manifest}"


report_and_exit "canonical-drift tests"
