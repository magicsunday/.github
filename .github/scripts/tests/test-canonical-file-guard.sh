#!/usr/bin/env bash
# Exercises assert_canonical_zizmor_config()
# (.github/scripts/lib/canonical-file-guard.sh), the function zizmor.yml
# sources to reject a caller repository whose .github/zizmor.yml is missing
# or has drifted from the canonical copy. Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"
# shellcheck source=../lib/canonical-file-guard.sh
source "${SCRIPT_DIR}/../lib/canonical-file-guard.sh"

work_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "${work_dir}"' EXIT
original_dir="$(pwd)" || exit 1

# Every case gets its OWN fresh caller directory AND its own fresh canonical
# directory, mirroring the isolation test-semgrepignore-guard.sh already
# established for a similar guard: reusing one directory across cases risks
# a leftover .github/zizmor.yml from an earlier case masking a later one.

# An identical copy passes with no output and exit 0.
caller_dir="$(mktemp -d "${work_dir}/caller-XXXXXX")" || exit 1
canonical_dir="$(mktemp -d "${work_dir}/canonical-XXXXXX")" || exit 1
mkdir -p "${caller_dir}/.github" "${canonical_dir}/.github"
printf 'on: {}\n' > "${caller_dir}/.github/zizmor.yml"
printf 'on: {}\n' > "${canonical_dir}/.github/zizmor.yml"
cd "${caller_dir}" || exit 1
output="$(assert_canonical_zizmor_config "${canonical_dir}" 2>&1)"
rc=$?
cd "${original_dir}" || exit 1
assert_eq "identical copy: passes" "0" "${rc}"
assert_eq "identical copy: no output" "" "${output}"

# A missing caller file fails with the "missing" annotation, not the
# "differs" one - the two failure modes need distinct, actionable text.
caller_dir="$(mktemp -d "${work_dir}/caller-XXXXXX")" || exit 1
canonical_dir="$(mktemp -d "${work_dir}/canonical-XXXXXX")" || exit 1
mkdir -p "${caller_dir}/.github" "${canonical_dir}/.github"
printf 'on: {}\n' > "${canonical_dir}/.github/zizmor.yml"
cd "${caller_dir}" || exit 1
output="$(assert_canonical_zizmor_config "${canonical_dir}" 2>&1)"
rc=$?
cd "${original_dir}" || exit 1
assert_eq "missing caller file: fails closed" "1" "${rc}"
assert_eq "missing caller file: emits the missing annotation" \
    "::error file=.github/zizmor.yml::.github/zizmor.yml is missing. It declares that first-party reusable workflows track @main by policy - without it, the unpinned-uses zizmor audit falls back to its blanket hash-pin rule and reports every reusable-workflow reference as a finding. Copy the canonical file from https://github.com/magicsunday/.github/blob/main/.github/zizmor.yml" \
    "${output}"

# A drifted caller file (present, but byte-different) fails with the
# "differs" annotation.
caller_dir="$(mktemp -d "${work_dir}/caller-XXXXXX")" || exit 1
canonical_dir="$(mktemp -d "${work_dir}/canonical-XXXXXX")" || exit 1
mkdir -p "${caller_dir}/.github" "${canonical_dir}/.github"
printf 'on: {}\n' > "${caller_dir}/.github/zizmor.yml"
printf 'on: {}\nignore: []\n' > "${canonical_dir}/.github/zizmor.yml"
cd "${caller_dir}" || exit 1
output="$(assert_canonical_zizmor_config "${canonical_dir}" 2>&1)"
rc=$?
cd "${original_dir}" || exit 1
assert_eq "drifted caller file: fails closed" "1" "${rc}"
assert_eq "drifted caller file: emits the differs annotation" \
    "::error file=.github/zizmor.yml::.github/zizmor.yml differs from the canonical copy in magicsunday/.github. A stale or locally-edited copy can silently change which reusable-workflow references the unpinned-uses zizmor audit flags. Sync it from https://github.com/magicsunday/.github/blob/main/.github/zizmor.yml" \
    "${output}"

# A missing canonical copy (the reusable workflow's own checkout failed to
# produce it) is a defect in THIS workflow, not the caller - distinct text,
# so a maintainer reading the log does not go looking in the wrong repo.
caller_dir="$(mktemp -d "${work_dir}/caller-XXXXXX")" || exit 1
canonical_dir="$(mktemp -d "${work_dir}/canonical-XXXXXX")" || exit 1
mkdir -p "${caller_dir}/.github"
printf 'on: {}\n' > "${caller_dir}/.github/zizmor.yml"
cd "${caller_dir}" || exit 1
output="$(assert_canonical_zizmor_config "${canonical_dir}" 2>&1)"
rc=$?
cd "${original_dir}" || exit 1
assert_eq "missing canonical copy: fails closed" "1" "${rc}"
assert_eq "missing canonical copy: emits the own-checkout-defect annotation" \
    "::error::Could not verify .github/zizmor.yml against the canonical copy - the checked-out canonical source at '${canonical_dir}/.github/zizmor.yml' does not exist. This is a defect in the reusable workflow's own checkout, not in the calling repository." \
    "${output}"

report_and_exit "canonical-file-guard tests"
