#!/usr/bin/env bash
# Cross-checks the hand-maintained halves of commit-convention.yml's shared
# checkout against each other and against the tree: the checkout step's
# `path:` must be the directory prefix the `. "<path>/..."` source line below
# it uses, and the repo-relative remainder of that source line must name a
# file that exists here. Nothing else ties the three together - the shell-test
# suite sources annotation-sanitize.sh from its real repo path, never through
# the workflow's checkout, so a rename of the lib, of the checkout path, or a
# typo in the source line stays green locally and breaks every consumer at
# real GitHub Actions runtime with "No such file or directory". Mirrors the
# shape test-lib-source-cp-drift.sh checks for code-scanning.yml's copy list.
#
# Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/commit-convention.yml"

require_files_or_bail "commit-convention shared-checkout source drift-guard test" "${WORKFLOW_FILE}"

# The checkout step's `path:` value, scoped to that step's own body so a
# `path:` elsewhere in the workflow cannot be mistaken for it.
checkout_step_body="$(extract_block '- name: Check out the canonical annotation sanitizer' '- name:' "${WORKFLOW_FILE}")"
checkout_path="$(printf '%s' "${checkout_step_body}" | grep -oE '^ *path: *[^ ]+' | sed -E 's/^ *path: *//')"

# The `. "<prefix>/<repo-relative-path>"` line that dots a file under a
# literal checkout prefix. `[^$"]` excludes the RUNNER_TEMP predicate source,
# whose target starts with a `$` expansion.
source_target="$(grep -oE '^ *\. "[^$"]+/[^"]+"' "${WORKFLOW_FILE}" | sed -E 's/^ *\. "//; s/"$//')"

assert_nonempty "${checkout_path}" \
    "extracted no path: from the checkout step in ${WORKFLOW_FILE} - regex or step shape changed"
assert_nonempty "${source_target}" \
    "extracted no checkout-prefixed source line from ${WORKFLOW_FILE} - regex or source shape changed"

source_prefix="${source_target%%/*}"
source_relative="${source_target#*/}"

assert_eq "the source line's directory prefix is the checkout step's path:" \
    "${checkout_path}" "${source_prefix}"

if [ -f "${REPO_ROOT}/${source_relative}" ]; then
    echo "PASS: the sourced file exists at ${source_relative}"
else
    echo "FAIL: the sourced file does not exist at ${source_relative}"
    failures=$((failures + 1))
fi

report_and_exit "commit-convention shared-checkout source drift-guard test"
