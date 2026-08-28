#!/usr/bin/env bash
# Runs every test-*.sh script in this directory and fails if any of them
# does. Invoked from lint.yml so a regression in the shell logic the
# reusable workflows source is caught before it reaches a caller repository.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failures=0

for test_script in "${SCRIPT_DIR}"/test-*.sh; do
    echo "== ${test_script} =="
    if ! bash "${test_script}"; then
        failures=$((failures + 1))
    fi
    echo
done

if [ "${failures}" -gt 0 ]; then
    echo "${failures} test script(s) failed."
    exit 1
fi

echo "All shell-logic tests passed."
