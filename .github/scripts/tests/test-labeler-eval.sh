#!/usr/bin/env bash
# Runs test_labeler_eval.py's unittest suite. run-tests.sh only picks up
# test-*.sh, so this wrapper is what makes the Python tests run under it and
# under lint.yml's "Shell logic tests" job.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "${SCRIPT_DIR}/test_labeler_eval.py" -v
