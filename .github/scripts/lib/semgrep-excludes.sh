#!/usr/bin/env bash
# Sourced by code-scanning.yml's "Run Semgrep" step and by
# .github/scripts/tests/test-semgrep-excludes.sh, so the workflow and its
# test drive the same file rather than two copies that can drift apart.

# Appends `--exclude <pattern>` pairs to the caller's `extra` array (declared
# and empty before this is sourced) from a whitespace-separated pattern list.
# The caller's list is consumed as a plain argument rather than inlined into
# a command, so a value cannot inject shell. It is split on whitespace
# WITHOUT pathname expansion: an unquoted expansion would also glob, and
# glob is the wrong matcher here, because it resolves the pattern against
# the runner's checkout instead of handing it to Semgrep. The divergence is
# a SLASH-FREE pattern: measured on the pinned engine, `--exclude '*.pdf'`
# skips a PDF at any depth, while the shell expands it against the working
# directory only and leaves a nested one to be read — which then fails this
# gate and is reported as undeclared. A pattern WITH a slash is anchored one
# level either way, so it is the wrong example to reason from. Re-derive:
#
# Read `.paths.skipped`, not `.paths.scanned`: no language claims a PDF, so
# it is absent from BOTH inventories when unexcluded, and a scanned-side
# check would read as confirmation even if the pattern had stopped matching
# at depth.
#
#   semgrep scan --config p/php --exclude '*.pdf' \
#       --json-output=j.json --verbose --metrics off
#   jq -r '.paths.skipped[]
#       | select(.reason == "cli_exclude_flags_match")
#       | .path' j.json   # the nested PDF is listed too
#
# Globbing is switched off around the loop rather than the split being
# hand-rolled: the default `IFS` already splits on space, tab and newline,
# which is what a caller writing the YAML block form sends.
build_semgrep_exclude_args() {
    local patterns="${1:-}"

    set -f
    # shellcheck disable=SC2086
    for pattern in ${patterns}; do
        extra+=(--exclude "$pattern")
    done
    set +f
}
