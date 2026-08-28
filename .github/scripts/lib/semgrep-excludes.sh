#!/usr/bin/env bash
# Sourced by code-scanning.yml's "Run Semgrep" step and by
# .github/scripts/tests/test-semgrep-excludes.sh, so the workflow and its
# test drive the same file rather than two copies that can drift apart.

# Appends `--exclude <pattern>` pairs to the caller's `extra` array (declared
# and empty before this is sourced) from a whitespace-separated pattern list.
# noglob is enabled around the split so a caller-supplied pattern holding a
# glob character (`docs/*.pdf`) reaches Semgrep literally instead of being
# resolved against the runner's checkout: an unquoted expansion would also
# glob, and glob is the wrong matcher here, because it resolves the pattern
# against the runner's checkout instead of handing it to Semgrep. Measured on
# the pinned engine: `--exclude '*.pdf'` skips a PDF at any depth, while the
# shell would expand it against the working directory only and leave a
# nested one to be read.
build_semgrep_exclude_args() {
    local patterns="${1:-}"

    set -f
    # shellcheck disable=SC2086
    for pattern in ${patterns}; do
        extra+=(--exclude "$pattern")
    done
    set +f
}
