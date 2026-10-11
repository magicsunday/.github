#!/usr/bin/env bash
# Runs the unittest modules of the labeler evaluation tool. run-tests.sh only
# picks up test-*.sh, so this wrapper is what makes the Python tests run under
# it and under lint.yml's "Shell logic tests" job.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 -m unittest discover -s "${SCRIPT_DIR}" -p 'test_labeler_eval*.py' -v
