#!/usr/bin/env bash
# Cross-checks the hand-maintained halves of commit-convention.yml's shared
# checkout against each other and against the tree: the checkout step's
# `path:` must be the directory prefix of every `. "<path>/..."` /
# `bash "<path>/..."` line below it, and the repo-relative remainder of each
# must name a file that exists here. Nothing else ties the three together - the shell-test
# suite sources every lib from its real repo path, never through
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
checkout_step_body="$(extract_block '- name: Check out the shared predicate and sanitizer' '- name:' "${WORKFLOW_FILE}")"
checkout_path="$(printf '%s' "${checkout_step_body}" | grep -oE '^ *path: *[^ ]+' | sed -E 's/^ *path: *//')"

# Every `. "<prefix>/<repo-relative-path>"` or `bash "<prefix>/..."` line that
# reads a file under a literal checkout prefix - the predicate and the
# sanitizer are dotted, the predicate's test script is run (issue #107).
# `[^$"]` excludes any source whose target starts with a `$` expansion.
source_targets="$(grep -oE '^ *(\.|bash) "[^$"]+/[^"]+"' "${WORKFLOW_FILE}" | sed -E 's/^ *(\.|bash) "//; s/"$//' | sort -u)"

assert_nonempty "${checkout_path}" \
    "extracted no path: from the checkout step in ${WORKFLOW_FILE} - regex or step shape changed"
assert_nonempty "${source_targets}" \
    "extracted no checkout-prefixed source line from ${WORKFLOW_FILE} - regex or source shape changed"

# Each file the workflow is known to read from the checkout must actually be
# among the extracted targets, so a regex that silently stops matching one
# shape (the `bash` run, say) cannot shrink this check to the others.
for expected_target in \
    .github/scripts/lib/commit-subject-predicate.sh \
    .github/scripts/lib/annotation-sanitize.sh \
    .github/scripts/tests/test-commit-subject-predicate.sh; do
    assert_contains "the workflow reads ${expected_target} from the shared checkout" \
        "${source_targets}" "/${expected_target}"
done

source_target=""
while IFS= read -r source_target; do
    [ -n "${source_target}" ] || continue

    assert_eq "the directory prefix of ${source_target} is the checkout step's path:" \
        "${checkout_path}" "${source_target%%/*}"

    require_file "${REPO_ROOT}/${source_target#*/}"
done <<<"${source_targets}"

report_and_exit "commit-convention shared-checkout source drift-guard test"
