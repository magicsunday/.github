#!/usr/bin/env bash
# Cross-checks that every lib-to-lib `source "$(dirname ...)/<file>.sh"`
# dependency inside .github/scripts/lib/*.sh has a matching `cp .../<file>.sh
# "$SCRIPT_LIB/"` line in code-scanning.yml's "Install Semgrep" step
# (issue #78 introduced the first such dependency - semgrepignore-guard.sh
# and semgrep-report-check.sh both sourcing annotation-sanitize.sh).
#
# The dependency and the copy step are hand-maintained in separate files
# with nothing but the BASH_SOURCE-relative `source` line itself tying them
# together. The drift that matters: a lib file gains a new internal `source`
# dependency without a matching `cp` line added here - the shell-test suite
# (which sources every lib straight from its real repo path, never through
# the $SCRIPT_LIB copy the workflow actually performs) would stay green
# while the workflow step fails at real GitHub Actions runtime with
# "No such file or directory", since the sourced sibling was never staged
# into $SCRIPT_LIB alongside it. Mirrors the same sourcing-wiring shape
# test-semgrep-prune-dirs.sh checks on the workflow-step side of a
# comparable dependency.
#
# Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
LIB_DIR="${REPO_ROOT}/.github/scripts/lib"
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/code-scanning.yml"

require_files_or_bail "lib source/cp drift-guard test" "${WORKFLOW_FILE}"

# Every file the "Install Semgrep" step copies into $SCRIPT_LIB, scoped to
# that step's own body so a `cp` line elsewhere in the workflow (there is
# none today) cannot be mistaken for this step's copy list.
install_step_body="$(extract_block '- name: Install Semgrep' '- name:' "${WORKFLOW_FILE}")"
copied_files="$(printf '%s' "${install_step_body}" | grep -oE 'cp \.magicsunday-shared/\.github/scripts/lib/[A-Za-z0-9_-]+\.sh' \
    | grep -o '[A-Za-z0-9_-]*\.sh$' | sort -u)"

# Every BASH_SOURCE-relative `source ".../<file>.sh"` dependency named in a
# lib file that step copies, deduplicated. Only a copied lib resolves its
# siblings inside $SCRIPT_LIB; a lib the step never stages - canonical-drift.sh,
# sourced from its own repository checkout by canonical-drift.yml - finds its
# dependencies next to it in that checkout and is out of scope here. This
# pattern (not a plain `source "X.sh"`) is what the runner-temp copy actually
# needs to satisfy - a lib file sourcing a fixed repo-relative path would
# resolve differently and is out of scope as well.
copied_paths=()
copied=""
for copied in ${copied_files}; do
    [ -f "${LIB_DIR}/${copied}" ] && copied_paths+=("${LIB_DIR}/${copied}")
done
sourced_deps=""
if [ "${#copied_paths[@]}" -gt 0 ]; then
    sourced_deps="$(grep -ho 'source "\$(cd "\$(dirname "\${BASH_SOURCE\[0\]}")" && pwd)/[A-Za-z0-9_-]*\.sh"' "${copied_paths[@]}" \
        | grep -o '[A-Za-z0-9_-]*\.sh"$' | tr -d '"' | sort -u)"
fi

assert_nonempty "${sourced_deps}" \
    "extracted no lib-to-lib source dependencies from the libs the Install Semgrep step copies - regex or sourcing shape changed"
assert_nonempty "${copied_files}" \
    "extracted no cp lines from the Install Semgrep step in ${WORKFLOW_FILE} - regex or step shape changed"

missing=""
dep=""
for dep in ${sourced_deps}; do
    if ! grep -qx "${dep}" <<<"${copied_files}"; then
        missing="${missing}${dep}"$'\n'
    fi
done

assert_eq "every lib-to-lib source dependency is copied into \$SCRIPT_LIB by the Install Semgrep step" \
    "" "${missing}"

report_and_exit "lib source/cp drift-guard test"
