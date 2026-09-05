#!/usr/bin/env bash
# Runs test_find_workflow_call_targets.py's unittest suite - a plain Python
# module rather than a test-*.sh script itself, since run-tests.sh's own
# glob only picks up test-*.sh, not test_*.py. This wrapper is the only
# reason the Python unit tests execute at all under run-tests.sh /
# lint.yml's "Shell logic tests" job.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "${SCRIPT_DIR}/test_find_workflow_call_targets.py" -v
