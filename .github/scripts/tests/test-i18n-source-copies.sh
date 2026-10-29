#!/usr/bin/env bash
# Runs the unittest suite of i18n_source_copies.py, a plain Python module that
# the test-*.sh glob of run-tests.sh would not pick up by itself.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "${SCRIPT_DIR}/test_i18n_source_copies.py" -v
