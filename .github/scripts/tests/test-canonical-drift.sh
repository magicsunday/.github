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
# contents API's answer for an absent path.
fixtures=""

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
canonical_sha="$(canonical_blob_sha "${canonical}/.github/zizmor.yml")"

manifest="${work_dir}/manifest.json"
write_manifest() {
    printf '%s' "$1" >"${manifest}"
}
default_manifest='{"files":[{"path":".github/zizmor.yml","applies_when_present":".github/workflows","exempt":["legacy"]}]}'

new_fixtures() {
    fixtures="$(mktemp -d "${work_dir}/fx.XXXXXX")"
}
fixture() {
    local key
    key="$(printf '%s' "$1" | tr '/?&=' '____')"
    printf '%s' "$2" >"${fixtures}/${key}.json"
}
fixture_error() {
    local key
    key="$(printf '%s' "$1" | tr '/?&=' '____')"
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

run_sweep() {
    output="$(check_canonical_drift "${manifest}" "${canonical}" acme .github 2>&1)"
    rc=$?
}

# --- the blob hash matches what git itself stores for this repository ---
expected_blob="$(git -C "${REPO_ROOT}" rev-parse HEAD:.github/zizmor.yml 2>/dev/null || true)"
if [ -n "${expected_blob}" ] && git -C "${REPO_ROOT}" diff --quiet HEAD -- .github/zizmor.yml; then
    assert_eq "canonical_blob_sha equals git's own blob id for .github/zizmor.yml" \
        "${expected_blob}" "$(canonical_blob_sha "${REPO_ROOT}/.github/zizmor.yml")"
fi

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

# --- a drifted file fails ---
new_fixtures
repo_list '[{"name":"one","archived":false,"fork":false}]'
has_workflows one; zizmor_file one "0000000000000000000000000000000000000000"
run_sweep
assert_eq "drifted file: exit 1" 1 "${rc}"
assert_contains "drifted file: says it differs" "${output}" "acme/one: .github/zizmor.yml differs from the canonical copy"

# --- a symlink or directory at the path is not the canonical file ---
new_fixtures
repo_list '[{"name":"one","archived":false,"fork":false},{"name":"two","archived":false,"fork":false}]'
has_workflows one; fixture "repos/acme/one/contents/.github/zizmor.yml" "{\"type\":\"symlink\",\"sha\":\"${canonical_sha}\"}"
has_workflows two; fixture "repos/acme/two/contents/.github/zizmor.yml" '[{"name":"x","type":"file"}]'
run_sweep
assert_eq "symlink/directory: exit 1" 1 "${rc}"
assert_contains "symlink: reported as not a regular file" "${output}" "acme/one: .github/zizmor.yml exists but is not a regular file"
assert_contains "directory: reported as not a regular file" "${output}" "acme/two: .github/zizmor.yml exists but is not a regular file"

# --- a repository without workflows is out of scope for zizmor.yml ---
new_fixtures
repo_list '[{"name":"one","archived":false,"fork":false},{"name":"docs-only","archived":false,"fork":false}]'
has_workflows one; zizmor_file one "${canonical_sha}"
run_sweep
assert_eq "no workflows: not applicable, exit 0" 0 "${rc}"
assert_contains "no workflows: one file checked" "${output}" "1 canonical file(s)"

# --- an exempt repository is skipped even when drifted ---
new_fixtures
repo_list '[{"name":"one","archived":false,"fork":false},{"name":"legacy","archived":false,"fork":false}]'
has_workflows one; zizmor_file one "${canonical_sha}"
has_workflows legacy; zizmor_file legacy "0000000000000000000000000000000000000000"
run_sweep
assert_eq "exempt repository: exit 0" 0 "${rc}"

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

# --- a repository name outside the allowed set is unchecked, not echoed ---
new_fixtures
repo_list '[{"name":"one","archived":false,"fork":false},{"name":"bad name::error::x","archived":false,"fork":false}]'
has_workflows one; zizmor_file one "${canonical_sha}"
run_sweep
assert_eq "invalid repo name: exit 1" 1 "${rc}"
case "${output}" in
    *"bad name"*) r=echoed ;;
    *) r=withheld ;;
esac
assert_eq "invalid repo name: the raw name never reaches the output" withheld "${r}"

# --- manifest validation ---
new_fixtures
repo_list '[{"name":"one","archived":false,"fork":false}]'

write_manifest '{"files":[]}'
run_sweep
assert_eq "empty manifest: exit 1" 1 "${rc}"

write_manifest '{"files":[{"path":".github/absent.yml"}]}'
run_sweep
assert_eq "manifest path absent here: exit 1" 1 "${rc}"
assert_contains "manifest path absent here: says so" "${output}" "is not a regular file in this repository"

write_manifest '{"files":[{"path":"../etc/passwd"}]}'
run_sweep
assert_eq "manifest path traversal: exit 1" 1 "${rc}"

write_manifest '{"files":[{"path":".github/zizmor.yml","exempt":"legacy"}]}'
run_sweep
assert_eq "manifest exempt not an array: exit 1" 1 "${rc}"

write_manifest 'not json'
run_sweep
assert_eq "manifest not JSON: exit 1" 1 "${rc}"

# --- the summary is written when GITHUB_STEP_SUMMARY is set ---
write_manifest "${default_manifest}"
new_fixtures
repo_list '[{"name":"one","archived":false,"fork":false}]'
has_workflows one; zizmor_file one "0000000000000000000000000000000000000000"
summary="${work_dir}/summary.md"
GITHUB_STEP_SUMMARY="${summary}" check_canonical_drift "${manifest}" "${canonical}" acme .github >/dev/null 2>&1
assert_contains "summary: lists the drifted repository" "$(cat "${summary}")" "| one | \`.github/zizmor.yml\` | **drifted** |"

report_and_exit "canonical-drift tests"
