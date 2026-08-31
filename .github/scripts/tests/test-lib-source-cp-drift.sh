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
# into $SCRIPT_LIB alongside it. Mirrors the same drift-guard shape as
# test-semgrepignore-prune-matches-excludes.sh, for a different pair of
# hand-maintained lists.
#
# Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
LIB_DIR="${REPO_ROOT}/.github/scripts/lib"
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/code-scanning.yml"

if [ ! -f "${WORKFLOW_FILE}" ]; then
    echo "FAIL: expected file not found: ${WORKFLOW_FILE}"
    failures=$((failures + 1))
    report_and_exit "lib source/cp drift-guard test"
fi

# Every BASH_SOURCE-relative `source ".../<file>.sh"` dependency named across
# all lib files, deduplicated. This pattern (not a plain `source "X.sh"`)
# is what code-scanning.yml's runner-temp $SCRIPT_LIB copy actually needs to
# satisfy - a lib file sourcing a fixed repo-relative path would resolve
# differently and is out of scope for this check.
sourced_deps="$(grep -ho 'source "\$(cd "\$(dirname "\${BASH_SOURCE\[0\]}")" && pwd)/[A-Za-z0-9_-]*\.sh"' "${LIB_DIR}"/*.sh \
    | grep -o '[A-Za-z0-9_-]*\.sh"$' | tr -d '"' | sort -u)"

# Every file the "Install Semgrep" step copies into $SCRIPT_LIB, scoped to
# that step's own body so a `cp` line elsewhere in the workflow (there is
# none today) cannot be mistaken for this step's copy list.
install_step_body="$(sed -n '/- name: Install Semgrep/,/- name:/p' "${WORKFLOW_FILE}")"
copied_files="$(printf '%s' "${install_step_body}" | grep -oE 'cp \.magicsunday-shared/\.github/scripts/lib/[A-Za-z0-9_-]+\.sh' \
    | grep -o '[A-Za-z0-9_-]*\.sh$' | sort -u)"

if [ -z "${sourced_deps}" ]; then
    echo "FAIL: extracted no lib-to-lib source dependencies from ${LIB_DIR}/*.sh - regex or sourcing shape changed"
    failures=$((failures + 1))
fi
if [ -z "${copied_files}" ]; then
    echo "FAIL: extracted no cp lines from the Install Semgrep step in ${WORKFLOW_FILE} - regex or step shape changed"
    failures=$((failures + 1))
fi

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
