#!/usr/bin/env bash
# Sourced by code-scanning.yml's "Run Semgrep" step and by
# .github/scripts/tests/test-semgrep-report-check.sh, so the workflow and its
# test drive the same file rather than two copies that can drift apart.

# Fails unless Semgrep's --json-output report shows a complete scan. Prints
# exactly one `::error::` workflow annotation on failure (so a raw newline or
# a literal `%` in a path can never split it into an unattributed log line —
# both are sanitised before they are folded into the annotation), or the
# success line on stdout. Takes the path to the report file; returns non-zero
# exactly when the report is unreadable or incomplete.
assert_semgrep_report_complete() {
    local json_file="$1"

    # Readability is a property of the file, decided once here rather than at
    # each of the reads below, so a malformed report fails with an
    # explanation instead of a bare jq abort at whichever read reaches it
    # first.
    if ! jq . "$json_file" > /dev/null 2>&1; then
        echo "::error::Semgrep's JSON report could not be read, so the scan could not be shown to be complete - nothing was uploaded."
        return 1
    fi

    # Which skips are acceptable is decided by an allow list, so a reason
    # this list does not name fails the job, including one a later engine
    # introduces. A reason is tolerated on one of two grounds: the file was
    # never a scan target (this workflow's --exclude flags, an ignore file, a
    # rule's own path rules), or its content cannot carry a finding any rule
    # could make (binary). `minified` is neither and is tolerated as an
    # accepted risk — see code-scanning.yml for the full rationale, the
    # re-derive commands for every entry, and why the character class in the
    # sanitiser below has to admit capitals and drop the SkipReason class's
    # own name.
    local allowed_skip_reasons='[
        "always_skipped",
        "binary",
        "cli_exclude_flags_match",
        "cli_include_flags_do_not_match",
        "excluded_by_config",
        "irrelevant_rule",
        "minified",
        "semgrepignore_patterns_match",
        "wrong_language"
    ]'

    # A missing inventory is treated as a finding rather than as an empty
    # one, so dropping --verbose upstream cannot quietly pass.
    local unexpected
    unexpected="$(jq -r --argjson allowed "$allowed_skip_reasons" '
        if (.paths.skipped | type) != "array" then
            ["(whole report): no-skipped-inventory"]
        else
            [.paths.skipped[]
                | (.reason // "unknown") as $reason
                | select(($allowed | index($reason)) == null)
                | ((.path // "(no path)")
                    | gsub("%"; "%25")
                    | gsub("[[:cntrl:]]"; "?")) as $path
                | "\($path): \($reason)"]
        end
        | join("%0A")
    ' "$json_file")"

    if [ -n "$unexpected" ]; then
        echo "::error::Semgrep exited 0 but did not scan every file it was given, so its report understates what is in the tree and code scanning would retire the alerts of the files below. If a file is not meant to be scanned, declare it through this workflow's 'excludes' input in the caller; otherwise fix what stopped it being read. A pattern holding a slash is anchored at the root and its '*' does not cross one, so a nested file needs its directory, its literal path, or a '**' pattern.%0A${unexpected}"
        return 1
    fi

    # A report over an empty file set is well-formed and asserts that
    # nothing is wrong, which would retire every alert at once. An absent
    # inventory counts as empty here: jq gives `null | length` as 0, and the
    # check above has already rejected the reports where the inventory is
    # missing.
    local scanned
    scanned="$(jq '.paths.scanned | length' "$json_file")"

    if [ "$scanned" -lt 1 ]; then
        echo "::error::Semgrep scanned no files at all, so its report asserts a clean tree it never looked at."
        return 1
    fi

    echo "Scanned ${scanned} files, no undeclared skips."
    return 0
}
