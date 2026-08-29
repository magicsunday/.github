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
    # this list does not name fails the job — including one a later engine
    # introduces. A deny list naming today's known bad reasons would let
    # exactly that next addition through silently, which is the defect this
    # check exists to prevent.
    #
    # A reason is tolerated on one of two grounds: the file was never a scan
    # target (this workflow's --exclude flags, an ignore file, a rule's own
    # path rules), or its content cannot carry a finding any rule could make
    # (binary).
    #
    # `minified` is deliberately NOT on this list, despite an earlier revision
    # of this comment tolerating it as an accepted risk on the theory that
    # minified JavaScript still parses and `p/secrets` is regex work
    # minification does not defeat. That theory was never wrong, but the risk
    # it worried about does not exist against the pinned engine: `semgrep
    # scan`'s Python wrapper hardcodes `exclude_minified_files=False` with no
    # CLI flag reaching it (`--exclude-minified-files` is undocumented-broken
    # outside `--experimental` — semgrep/semgrep#10454, open as of 2026-08-29;
    # re-check its state before citing it as still open past that date), so
    # this workflow's exact invocation cannot
    # produce a `minified` skip. Confirmed against the pinned engine with a
    # fixture crossing both of the engine's own thresholds for the reason —
    # `< 7% whitespace, or ... average of > 1000 bytes per line`, the pinned
    # engine's own wording for `--exclude-minified-files`, re-derive with:
    #
    #   semgrep scan --help | grep -A2 "Skip minified files"
    #
    # — holding a token `p/secrets` matches:
    #
    #   printf 'function f(a,b,c){return a+b+c;}%.0s' {1..80} > b.js
    #   printf 'var k="%s%s";' 'AKIA' 'ABCDEFGHIJKLMNOP' >> b.js
    #   semgrep scan --config p/secrets --json-output=j.json \
    #       --verbose --metrics off b.js
    #   jq '.paths.skipped, (.results | length)' j.json  # [], 1
    #
    # The token is split across two printf arguments on purpose: joined into
    # one literal, this recipe's own source line matches the very rule it is
    # demonstrating, and this repo's own Semgrep code-scanning flags it as a
    # false positive (`security/code-scanning/19`, `/20`) even after a
    # `nosemgrep` suppression, which is why it is split rather than
    # suppressed. GitHub secret-scanning push protection is a separate
    # product and was checked separately — it did NOT flag the joined
    # literal (`gh api repos/<owner>/<repo>/secret-scanning/alerts` returned
    # no alert of any state, measured 2026-08-29) — but keep it split anyway,
    # since a future change to that product's own heuristics could start
    # matching it; re-check both before "simplifying" this back into one
    # quoted string.
    #
    # The `.paths.skipped == []` half is engine-behaviour and holds until the
    # pin changes. The `(.results | length) == 1` half additionally depends
    # on the live, unpinned `p/secrets` registry pack (AGENTS.md: "The `p/*`
    # Semgrep rule packs ... cannot be pinned or vendored") still flagging
    # this token shape — a re-run showing `.paths.skipped == []` with zero
    # results still confirms the point (not skipped), just without that
    # pack's corroboration.
    #
    # `minified` stays off the allow list on purpose — a future engine bump
    # that makes it reachable again should fail this gate and force a fresh
    # re-derive, not be tolerated pre-emptively. Full history and the
    # original risk framing this replaces: issue #50.
    #
    # Everything else means a file that WAS a target went unread — it
    # exceeded a limit, could not be parsed, or could not be opened — and its
    # findings are missing from a report that does not say so. Re-derive the
    # engine's full set; whatever it names that is absent below fails the
    # job, so the two sets stay a partition by construction rather than by a
    # count kept in step:
    #
    #   sed -n '/^class SkipReason/,/^class /p' "$(python3 -c \
    #       'from semgrep.semgrep_interfaces import \
    #        semgrep_output_v1 as m; print(m.__file__)')" \
    #       | grep -oE "'[A-Za-z_]+'" | grep -vx "'SkipReason'" \
    #       | sort -u
    #
    # The character class below has to admit capitals, or it drops the three
    # PascalCase wire values and its output then agrees with this list and
    # reads as complete. It also has to drop the class's own name, which the
    # generated file repeats inside the same block.
    #
    # Those three — `Dotfile`, `Gitignore_patterns_match`,
    # `Nonexistent_file` — are denied, but measured on the pin the scan path
    # never emits them: a dotfile directory is scanned, and a gitignored path
    # is reported as `semgrepignore_patterns_match`, which this list
    # tolerates. So denying them is a decision about the schema, not live
    # coverage — a `.gitignore` DIRECTORY entry covering tracked files does
    # drop them silently, and that is the accepted risk recorded in issue #48
    # rather than something denied here. Re-derive, in a git checkout, since
    # targets come from `git ls-files` when one is present:
    #
    #   mkdir -p dist .hidden
    #   printf '<?php eval($_GET["x"]);\n' > dist/x.php
    #   printf '<?php eval($_GET["y"]);\n' > .hidden/y.php
    #   printf 'dist/\n' > .gitignore && git add -Af . &&
    #   semgrep scan --config p/php --json-output=j.json \
    #       --verbose --metrics off
    #   jq -r '.paths.skipped[] | "\(.path): \(.reason)"' j.json
    #       # dist/x.php: semgrepignore_patterns_match — tracked,
    #       # holding a finding, dropped, and tolerated here
    #   jq -r '.paths.scanned[]' j.json
    #       # .hidden/y.php — the dotfile directory was scanned
    #
    # Both fixtures have to exist, or the commands print nothing and the
    # empty output reads as confirmation.
    local allowed_skip_reasons='[
        "always_skipped",
        "binary",
        "cli_exclude_flags_match",
        "cli_include_flags_do_not_match",
        "excluded_by_config",
        "irrelevant_rule",
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
    # OR malformed inventory counts as empty here: `type != "array"` catches
    # a report whose `.paths.scanned` is a string or object rather than a
    # list, which jq's polymorphic `length` would otherwise answer for
    # (a string's character count) instead of failing the scan closed.
    local scanned
    if [ "$(jq '.paths.scanned | type' "$json_file")" != '"array"' ]; then
        echo "::error::Semgrep's report does not have a scanned-files list, so it cannot be shown to have scanned anything."
        return 1
    fi
    scanned="$(jq '.paths.scanned | length' "$json_file")"

    if [ "$scanned" -lt 1 ]; then
        echo "::error::Semgrep scanned no files at all, so its report asserts a clean tree it never looked at."
        return 1
    fi

    # A tolerated skip is still a file whose alerts this upload retires, so
    # what was skipped has to be legible in the run that did it — but the
    # engine already writes that: `--verbose` puts a `Files skipped:` section
    # naming each path, and a `Scan skipped:` breakdown per reason, on
    # stderr, which is kept. Undocumented in `--help`, only observable by
    # running it. Self-contained re-derive:
    #
    #   printf '<?php\n' > huge.php
    #   yes '// pad' | head -200000 >> huge.php
    #   semgrep scan --config p/php --verbose --metrics off \
    #       huge.php 2>err.txt
    #   grep -c "Files skipped:\|Scan skipped:" err.txt  # 2
    #
    # Reprinting it from the JSON gave counts without the paths, so only the
    # gate's own verdict is echoed here.
    echo "Scanned ${scanned} files, no undeclared skips."
    return 0
}
