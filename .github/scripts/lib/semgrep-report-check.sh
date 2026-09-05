#!/usr/bin/env bash
# Sourced by code-scanning.yml's "Run Semgrep" step and by
# .github/scripts/tests/test-semgrep-report-check.sh, so the workflow and its
# test drive the same file rather than copies that can drift apart. The
# lint.yml-only smoke-test helpers (build_minified_fixture(),
# assert_absent_from_json_array()) live in semgrep-smoke-helpers.sh instead
# (issue #99) - neither is a production completeness-gate dependency.

# shellcheck source=annotation-sanitize.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/annotation-sanitize.sh"

# Writes `git -C repo_root ls-files -s -z` output to a fresh temp file and
# prints its path on stdout. Its one direct caller is
# _git_ls_files_filtered_deduped() below (re-derive: `grep -vn '^\s*#'
# .github/scripts/lib/semgrep-report-check.sh | grep -c
# '_git_tracked_entries_tempfile "'`, expect exactly 1); through that,
# assert_semgrep_report_complete() and warn_tracked_archives() both reach it
# indirectly. Every caller invokes this as an `if` condition, never a bare
# assignment - under `set -e`, `out="$(cmd)"` trips errexit immediately on a
# failing `cmd`, before a following `rc=$?` line is ever reached.
#
# Distinguishes a mktemp failure from a `git ls-files` failure via its own
# return code (1 vs 2), so each caller keeps its own distinct message and
# severity: assert_semgrep_report_complete() fails closed with
# `::error::`/`return 1` on either, warn_tracked_archives() degrades open
# with `::warning::`/`return 0` on either. On a `git ls-files` failure the
# temp file is already removed before this returns.
_git_tracked_entries_tempfile() {
    local repo_root="$1"
    local f
    f="$(mktemp)" || return 1
    # `-s` adds the object mode git itself assigns each entry ahead of the
    # path, `<mode> SP <object> SP <stage> TAB <path>` - how a caller tells a
    # symlink/gitlink from an ordinary tracked file without re-deriving that
    # from file content. Read from a temp FILE, never through a
    # `$(...)`-captured bash string: as observed 2026-09-02 (`bash -c
    # 'x=$(printf "a\0b"); echo "${#x}"'` → warns "ignored null byte in
    # input" and prints 2, not 3), command substitution silently drops
    # embedded NUL bytes, which is exactly what `-z` NUL-separates its
    # output WITH - a capture through a string variable would corrupt every
    # entry after the first.
    if ! git -C "$repo_root" ls-files -s -z > "$f" 2>/dev/null; then
        rm -f "$f" || true
        return 2
    fi
    printf '%s' "$f"
}

# Fills the array named by $1 (a nameref - the caller passes a plain
# variable name, e.g. `_git_ls_files_filtered_deduped tracked "$repo_root"
# keep`) with every tracked path from _git_tracked_entries_tempfile()'s scan
# of repo_root ($2) whose git file mode IS a symlink (120000) or
# gitlink/submodule (160000) if sense ($3) is "keep", or whose mode is
# NEITHER of those two if sense is "skip". Hardcoded rather than a
# caller-supplied mode list - every call site filters on exactly these two
# modes (re-derive: `grep -vn '^\s*#' .github/scripts/lib/semgrep-report-check.sh
# .github/scripts/tests/*.sh | grep '_git_ls_files_filtered_deduped [a-z]'`
# - stripping comment lines first excludes this file's own usage-example
# prose, which would otherwise self-match; expect only `keep`/`skip` as the
# trailing argument, never a mode list). No second temp file for the
# result: unlike _git_tracked_entries_tempfile()'s own NUL-delimited file
# (load-bearing there, since a command-substitution capture would silently
# drop the NULs), the filtered/deduped result goes straight into the
# caller's array in the same shell, so there's no boundary to smuggle it
# across.
#
# Adjacent duplicates of the same path collapse to one entry - an
# unresolved merge conflict stages the same path once per stage, all under
# the same mode. `git ls-files -s` sorts primarily by pathname, so every
# stage of a conflicted path is contiguous in read order - as observed
# 2026-09-02, a conflicted path's stage lines land contiguously in
# `git ls-files -s -z` output. Comparing only
# against the last-appended array element is therefore equivalent to a
# full "seen" set here, without a second data structure. Extension/content
# filtering beyond mode (e.g. warn_tracked_archives()'s archive-suffix
# check) is safe to apply AFTER this function returns: a conflicted path's
# stages all carry the identical path string, so such a filter agrees
# across every stage regardless of whether dedup happens before or after it.
#
# Returns 1 on a mktemp failure and 2 on a `git ls-files` failure -
# _git_tracked_entries_tempfile()'s own two-code contract, propagated
# verbatim - leaving the array untouched either way.
_git_ls_files_filtered_deduped() {
    # Every OTHER local below is underscore-prefixed too, not just style -
    # a nameref resolves by NAME against the function's own scope, so a
    # later plain `local` here that happened to reuse the caller's chosen
    # array name (e.g. a future caller passing "mode" or "path") would
    # silently shadow `_out` for the rest of the call: the write lands in
    # that new local instead of the caller's array, `_out` still thinks it
    # succeeded (rc=0), and the caller is left with a silently EMPTY result
    # - false-success on a completeness-relevant check. Verified live:
    # `f() { local -n _out="$1"; local mode=x; _out=(a); }; declare -a
    # mode=(); f mode; echo "${#mode[@]}"` prints `0`, no error. Prefixing
    # every local closes the collision for any
    # caller-chosen name that is not itself one of this function's own
    # underscore-prefixed internals (`_repo_root`, `_sense`, `_entry`,
    # `_mode`, `_path`, `_match`, `_git_ls_files_file`, `_tef_rc`) - narrower
    # than "no caller ever chooses one of these names", but every real
    # caller's array name (`tracked`, `raw_paths`) is outside that set.
    local -n _out="$1"
    local _repo_root="$2" _sense="$3"

    local _git_ls_files_file _tef_rc
    if _git_ls_files_file="$(_git_tracked_entries_tempfile "$_repo_root")"; then
        _tef_rc=0
    else
        _tef_rc=$?
    fi
    # `$?` inside a negated `if ! cmd; then ...` branch is the NEGATED
    # test's own status (always 0 there), never the original command's -
    # verified live (`if ! x="$(f)"; then echo "$?"; fi` where f returns 1
    # prints 0), which is why this captures the code in an `else` branch
    # instead, the same shape _git_tracked_entries_tempfile()'s own callers
    # already use for exactly this reason (see this file's own header
    # comment on that function for the sibling `local x=$(cmd)` variant of
    # this trap).
    [ "$_tef_rc" -eq 0 ] || return "$_tef_rc"

    _out=()
    local _entry _mode _path _match
    while IFS= read -r -d '' _entry; do
        _mode="${_entry%% *}"
        case "$_mode" in
            120000 | 160000) _match=0 ;;
            *) _match=1 ;;
        esac
        if [ "$_sense" = "skip" ]; then
            [ "$_match" -eq 0 ] && continue
        else
            [ "$_match" -eq 1 ] && continue
        fi
        _path="${_entry#*$'\t'}"
        if [ "${#_out[@]}" -eq 0 ] || [ "${_out[-1]}" != "$_path" ]; then
            _out+=("$_path")
        fi
    done < "$_git_ls_files_file"
    rm -f "$_git_ls_files_file" || true
}

# Fails unless Semgrep's --json-output report shows a complete scan. Prints
# exactly one `::error::` workflow annotation on failure (so a raw newline or
# a literal `%` in a path can never split it into an unattributed log line —
# both are sanitised before they are folded into the annotation), or the
# success line on stdout. Takes the path to the report file ($1) and,
# optionally, the checkout root ($2) — when given, this also compares the
# report against every git-tracked symlink/gitlink under that root (issue
# #49) and fails closed if the comparison itself cannot be run (a temp file
# or `git ls-files` failure), not only when the report proves incomplete.
assert_semgrep_report_complete() {
    local json_file="$1"
    # Optional, appended rather than spliced in: every existing call site
    # (including every fixture-only test that predates this parameter) keeps
    # working unchanged, since an empty value skips the check below entirely.
    local repo_root="${2:-}"

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
    #   source .github/scripts/lib/semgrep-smoke-helpers.sh
    #   build_minified_fixture b.js
    #   printf 'var k="%s%s";' 'AKIA' 'ABCDEFGHIJKLMNOP' >> b.js
    #   semgrep scan --config p/secrets --json-output=j.json \
    #       --verbose --metrics off b.js
    #   jq '.paths.skipped, (.results | length)' j.json  # [], 1
    #
    # The token is split across two printf arguments on purpose: joined into
    # one literal, this recipe's own source line matches the very rule it is
    # demonstrating, and this repo's own Semgrep code-scanning flagged it as
    # a false positive (`security/code-scanning/19`). A `nosemgrep` comment
    # on the joined literal did NOT clear it — Semgrep's SARIF still carries
    # a nosemgrep'd result marked merely `suppressions: [{kind: inSource}]`,
    # and code scanning opened a second alert (`/20`) on that same commit
    # regardless. Only removing the matching literal from the source (this
    # split) closed both. Keep it split; do not "simplify" it back into one
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
    # drop them silently, and that stays an accepted risk (issue #48). A
    # caller's own `.semgrepignore` FILE is a different channel producing the
    # same tolerated reason and is not tolerated the same way: code-scanning.yml
    # rejects its presence outright, in a precondition step before the scan
    # runs, rather than leaving it for this list to distinguish from the
    # engine's built-in defaults. Re-derive, in a git checkout, since
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
    # one, so dropping --verbose upstream cannot quietly pass. The `|| { ...;
    # return 1; }` matters as much as the filter itself: a `.paths.skipped[]`
    # entry whose `path` is not a string (a malformed or hand-edited report)
    # crashes this jq filter mid-evaluation, and a plain assignment discards
    # that non-zero exit status - the empty stdout it leaves behind would
    # otherwise read as "no unexpected reasons" and pass a report jq could
    # not finish evaluating (issue #65).
    #
    # jq's own diagnostic (which value crashed the filter, and why) is kept
    # rather than discarded: it is captured into a temp file instead of
    # `2>/dev/null`, run through sanitize_for_annotation() (annotation-sanitize.sh,
    # sourced above, itself jq-backed since issue #80) - a raw excerpt cannot
    # carry unsanitised report content into the annotation. That second jq
    # invocation degrades to its own fallback text internally on failure
    # (issue #83) rather than relying on this function's caller's `set -e` -
    # truncated, and folded into the single `::error::` line below. `cat`
    # is still guarded explicitly with `|| jq_error="(diagnostic unavailable)"`
    # for the same reason: every command between creating the temp file and
    # removing it must degrade to a placeholder rather than abort the script,
    # or the whole point of this branch - printing one attributable
    # annotation - is lost to a bare `set -e` exit instead. `rm -f` needs the
    # same `|| true` guard for the identical reason, despite `-f` in its name: `-f`
    # suppresses only the missing-file case, not a genuine permission or
    # filesystem error, which still exits non-zero - reproduced directly
    # (`chmod 555` on the containing directory made `rm -f` on a file inside
    # it exit 1) - and would otherwise abort this same branch, and the
    # success continuation below, before their own cleanup or annotation
    # runs (issue #69).
    #
    # Cleanup is two explicit `rm -f` calls (crash branch, success
    # continuation) rather than `trap ... RETURN`: that trap is NOT scoped to
    # the function that sets it - verified with bash 5.2, a RETURN trap set
    # inside a called function persists and fires again on the CALLER's own
    # return, using a `local` variable that has since gone out of scope,
    # which crashes under this function's caller's `set -u` with "unbound
    # variable" instead of cleaning anything up.
    local jq_stderr_file
    jq_stderr_file="$(mktemp)" || {
        echo "::error::jq failed while evaluating the skip inventory, so the report cannot be shown complete."
        return 1
    }

    local unexpected
    unexpected="$(jq -r --argjson allowed "$allowed_skip_reasons" '
        if (.paths.skipped | type) != "array" then
            ["(whole report): no-skipped-inventory"]
        else
            [.paths.skipped[]
                | (.reason // "unknown") as $reason
                | select(($allowed | index($reason)) == null)
                | ((.path // "(no path)")
                    | '"${ANNOTATION_SANITIZE_JQ_FILTER}"') as $path
                | "\($path): \($reason)"]
        end
        | join("%0A")
    ' "$json_file" 2>"$jq_stderr_file")" || {
        local jq_error
        jq_error="$(cat "$jq_stderr_file" 2>/dev/null)" || jq_error="(diagnostic unavailable)"
        jq_error="$(sanitize_for_annotation "${jq_error}" "(diagnostic unavailable)")"
        if [ "${#jq_error}" -gt 200 ]; then
            jq_error="${jq_error:0:197}..."
        fi
        rm -f "$jq_stderr_file" || true
        echo "::error::jq failed while evaluating the skip inventory, so the report cannot be shown complete: ${jq_error}"
        return 1
    }

    rm -f "$jq_stderr_file" || true

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

    # `scanned ∪ skipped` is everything the engine has an OPINION about — a
    # path absent from both leaves no trace in this report for either check
    # above to catch, because both read a `reason` Semgrep itself assigned
    # and a path in neither array carries none. This runs only when the
    # caller passes a `repo_root` (issue #49; channel 1 of that issue — a
    # warn-level `.errors[]` entry with no matching skip, and `.errors[]`
    # reaching the exit code at all outside `--strict`). As observed
    # 2026-09-02 against the pinned engine, this could not be made to
    # manifest even with a deliberately adversarial fixture:
    #
    #   yes 'function f(a,b,c){ if(a>b){return a;} else { return b+c; } }' \
    #       | head -200000 > huge.js
    #   semgrep scan --config p/javascript --timeout 1 --json-output=j.json \
    #       --verbose --metrics off huge.js
    #   jq '.errors, .paths.skipped, .paths.scanned' j.json
    #       # [], [], ["huge.js"] — no warn-level error, no skip
    #
    # (a 5000-deep nested-parenthesis expression under `--timeout 5` produced
    # the same empty `.errors`). Issue #49's own channel 2 — a file in
    # neither inventory — is what this block implements, not a second
    # unreproducible channel; see that issue for the full reproduction
    # attempts and its current status.
    #
    # This does NOT compare the whole `git ls-files` tree against the
    # report — only git-tracked SYMLINKS (mode 120000) and SUBMODULES
    # (gitlinks, mode 160000), the two git object types the engine cannot
    # represent as ordinary file content at all. An earlier version of this
    # block compared every tracked path and was wrong to: Semgrep's own
    # binary-content handling leaves an ORDINARY tracked binary asset (a
    # `.png`, a `.zip`) in neither `.paths.scanned` nor `.paths.skipped`
    # too, under the exact four-pack invocation this workflow runs —
    # reproduced 2026-09-02 against the pinned engine:
    #
    #   git init -q repro && cd repro
    #   printf '<?php eval($_GET["x"]);\n' > target.php
    #   printf '\x89PNG\r\n\x1a\n' > logo.png && git add -Af .
    #   semgrep scan --config p/security-audit --config p/secrets \
    #       --config p/php --config p/javascript --exclude '*.min.js' \
    #       --json-output=j.json --verbose --metrics off .
    #   jq '.paths.scanned, .paths.skipped' j.json
    #       # ["target.php"], [] — logo.png is in neither
    #
    # A blanket "every tracked path needs a verdict" check would have failed
    # closed on that ordinary asset — reddening code-scanning on merge for
    # every consumer carrying a tracked image, font, or archive without
    # already declaring it via `excludes`, which is most of them. Narrowing
    # to symlinks and gitlinks avoids depending on Semgrep's own
    # binary/content-type handling at all: neither object type is ever
    # "read" as file content by any engine invocation, pack selection, or
    # future engine version, so this check's soundness does not rest on
    # what the configured rule packs currently claim to cover.
    #
    # A git-tracked SYMLINK is the confirmed case this issue was filed for
    # — the engine neither scans nor lists one. Reproduced against the
    # pinned engine, 2026-09-02:
    #
    #   git init -q repro && cd repro
    #   printf '<?php eval($_GET["x"]);\n' > target.php
    #   ln -s target.php link.php && git add -Af .
    #   semgrep scan --config p/php --json-output=j.json \
    #       --verbose --metrics off .
    #   jq -r '.paths.scanned[], (.paths.skipped[]?.path // empty)' j.json
    #       # target.php — link.php is in neither
    #
    # A git-tracked SUBMODULE (a gitlink, mode 160000) is the second,
    # named-but-unobserved case — as observed 2026-09-02 via the git-trees
    # API, no non-archived magicsunday/* repository had one among this
    # workflow's consumers. Either way, if Semgrep ever DOES report a
    # symlink or gitlink as skipped on its own (a future engine version),
    # the allow-list check above already tolerates that reason and this
    # block simply never sees the path as missing. When one legitimately
    # needs to stay unscanned, exclude its path via this workflow's
    # `excludes` input — a `.semgrepignore` is not an alternative here, per
    # the rejection this file already explains above.
    if [ -n "$repo_root" ]; then
        # Every mode other than the symlink/gitlink pair
        # _git_ls_files_filtered_deduped() (above) keeps is left to the
        # reason-based check above. As observed 2026-09-02
        # (re-derive with `grep -rn "assert_semgrep_report_complete\b"
        # .github --include=*.yml --include=*.sh`), the sole production
        # caller checks out a single ref with `actions/checkout`, which
        # never leaves the index mid-conflict — the multi-stage/dedup
        # concern _git_ls_files_filtered_deduped() (above) guards against
        # cannot manifest through that call path today, but costs nothing
        # extra to keep for a caller that might. This also keeps
        # `git ls-files`' own sorted iteration order intact — the test
        # pinning two simultaneously-missing paths' exact join order
        # depends on it.
        local -a tracked=()
        local frc
        if _git_ls_files_filtered_deduped tracked "$repo_root" keep; then
            frc=0
        else
            frc=$?
        fi
        if [ "$frc" -eq 1 ]; then
            echo "::error::Could not create a temp file to compare the tree against the report — the completeness check cannot run."
            return 1
        elif [ "$frc" -eq 2 ]; then
            local safe_repo_root
            safe_repo_root="$(sanitize_for_annotation "${repo_root}")"
            echo "::error::\`git ls-files\` failed in ${safe_repo_root} — the tree cannot be compared against the report, so it cannot be shown complete."
            return 1
        fi

        # NUL-separated end to end, same reason `git ls-files -z` is used
        # above: an ordinary line-based read would misparse the rare path
        # holding a literal newline, and a git-tracked path is not
        # guaranteed not to.
        local -A covered=()
        local _covered_path
        while IFS= read -r -d '' _covered_path; do
            covered["$_covered_path"]=1
        done < <(jq -j '
            (.paths.scanned // [])[],
            ((.paths.skipped // [])[] | .path // empty)
            | select(type == "string")
            | (. + "\u0000")
        ' "$json_file" 2>/dev/null)

        local -a missing=()
        local _p
        for _p in "${tracked[@]}"; do
            [ -n "${covered[$_p]+x}" ] || missing+=("$_p")
        done

        if [ "${#missing[@]}" -gt 0 ]; then
            # One `jq` call over every missing path, piped through NUL-
            # delimited stdin - not one `sanitize_for_annotation` fork per
            # path. After the mode narrowing above, `missing` is bounded by
            # the number of tracked symlinks/gitlinks, not by the tree size
            # - but the form below is still the right one, for a reason
            # independent of that bound: a git-tracked path shaped like a
            # jq flag (`--rawfile`) does not reach jq's own argv/option
            # parser at all through a pipe, so there is nothing to
            # misinterpret regardless of how few or many paths there are.
            #
            # An earlier version of this block passed `missing` via jq's own
            # `--args`/`$ARGS.positional` instead of a pipe - written before
            # the mode narrowing, when `missing` really could be
            # tree-sized. Two independent problems with that form, both
            # found and fixed 2026-09-02:
            #  - a flag-shaped path was parsed as an option by jq's own
            #    getopt-style scanner rather than landing in
            #    `$ARGS.positional` - fixable with a `--` separator, but the
            #    deeper problem below made this form worth abandoning
            #    rather than patching.
            #  - passing thousands of paths as argv is bounded by the
            #    kernel's own limit, not by available memory - as observed
            #    2026-09-02 (`getconf ARG_MAX` -> 2097152 on the host
            #    tested), reproduced with 80000 synthetic paths:
            #    `jq: Argument list too long`, and the `|| missing_lines=...`
            #    fallback below then silently dropped every path from the
            #    annotation at exactly the scale a systematically incomplete
            #    report would have produced, before the narrowing made that
            #    scale unreachable through this call path.
            # Piping NUL-delimited data into `jq -Rs` (as `tracked`/`covered`
            # above already do, via a temp file and a process substitution
            # respectively) has neither limit: no argv, so no ARG_MAX: a
            # `--`-shaped or flag-shaped element is just bytes on stdin, not
            # a token jq's own arg parser ever sees.
            local missing_lines
            missing_lines="$(printf '%s\0' "${missing[@]}" | jq -Rsr '
                split("\u0000")[0:-1]
                | map('"${ANNOTATION_SANITIZE_JQ_FILTER}"')
                | join("%0A")
            ' 2>/dev/null)" || missing_lines="(sanitisation failed)"
            # The `excludes` remedy named below can represent a tracked path
            # containing a literal space (issue #89, fixed): the caller lists
            # one pattern per line rather than whitespace-separating them, and
            # `build_semgrep_exclude_args()` (semgrep-excludes.sh) splits on
            # newline only. Verified against the real helper:
            # `build_semgrep_exclude_args 'my link.php'` now produces exactly
            # one pattern, not two.
            echo "::error::Semgrep's report says nothing about the file(s) below — they are tracked by git but absent from both .paths.scanned and .paths.skipped, so the engine never enumerated them and code scanning would retire any alert they held. A git-tracked symlink is the confirmed producer of this shape; a submodule gitlink reaches it too. Declare the path through this workflow's 'excludes' input if it is not meant to be scanned, otherwise investigate why the engine never enumerated it.%0A${missing_lines}"
            return 1
        fi
    fi

    echo "Scanned ${scanned} files, no undeclared skips."
    return 0
}

# Prints one `::notice::` naming every git-tracked path whose extension marks
# it as an archive/container format (issue #90) - deliberately NEVER fails
# the job, unlike assert_semgrep_report_complete() above. A git-tracked
# archive is an ordinary regular file the pinned engine's own file-type
# detection never opens, so its contents land in neither `.paths.scanned`
# nor `.paths.skipped` - the same blind spot that function's own repo_root
# block documents for ordinary tracked binary assets (a `.png`, a font), just
# for a format that CAN carry scannable source where those cannot. Confirmed
# directly (not just inferred from the binary-asset case), as observed
# 2026-09-03 against the pinned engine (1.174.0), for one tracked archive
# per structural family the extension list below covers - a zip-based
# container (`.zip`, `.jar`, `.whl`), a tar-based container (`.tar.gz`,
# `.tgz`), a single-file compressor (`.gz`), and a `.7z` archive - full
# repro in issue #90's own reproduction section. `.war`/`.ear`/`.apk`
# (zip-based), `.tar`/`.tbz2`/`.txz` (tar-based - a bare, uncompressed
# `.tar` was never reproduced either, only its gzipped form), and
# `.bz2`/`.xz`/`.rar` (compressor/archive) are each the same structural
# shape as an already-confirmed sibling and are not independently
# reproduced beyond that. Turning this into a hard failure would resurrect
# exactly the false-positive class issue #49's fix removed - a tracked
# archive is not inherently a problem (a vendored dependency, a build
# artifact), so this
# only surfaces the fact for a reviewer to judge, via a non-blocking
# annotation.
#
# Every failure mode here (a mktemp or `git ls-files` failure) degrades to a
# `::warning::` and `return 0` rather than propagating, for the same reason -
# this check exists to add signal, never to gate a build the completeness
# check above didn't already gate.
#
# The extension list is scoped to formats that bundle or compress arbitrary
# file content (so a renamed/nested source file survives inside), not to
# every compressed format in general use - an opaque media format (a `.png`,
# a `.woff`) is excluded on the same ground assert_semgrep_report_complete()
# already documents: it structurally cannot carry a rule-detectable finding,
# archive or not. A single-file compressor (`.gz`/`.bz2`/`.xz`) is included
# alongside the multi-file container formats (`.zip`/`.tar`/...) because it
# hides exactly the same way a multi-file archive does - only the entry
# count differs. Compound suffixes each get their own entry (`.tgz`, not
# just `.gz`) only where the short form does not already end with a listed
# suffix; `.tar.gz` is deliberately absent because every path ending in it
# already ends in `.gz`, which is on the list - a spelled-out synonym here
# would be dead weight, never reached before the shorter suffix wins.
#
# `-s` (same flag assert_semgrep_report_complete()'s own repo_root block
# uses) is load-bearing, not decoration: a git-tracked SYMLINK or GITLINK
# whose name happens to end in a listed extension carries no archive content
# at all - the target is what would need scanning, if anything - so mode
# 120000/160000 entries are skipped before the extension match runs. Without
# this, a symlink a caller already quieted via this workflow's `excludes`
# input for the completeness check above (moving it into the tolerated
# `cli_exclude_flags_match` skip reason) would still trip this notice,
# falsely claiming it carries packed content invisible to scanning.
warn_tracked_archives() {
    local repo_root="$1"
    local -a archive_exts=(
        ".zip" ".jar" ".war" ".ear" ".apk" ".whl"
        ".tar" ".tgz" ".tbz2" ".txz"
        ".7z" ".rar" ".gz" ".bz2" ".xz"
    )

    local -a raw_paths=()
    local frc
    if _git_ls_files_filtered_deduped raw_paths "$repo_root" skip; then
        frc=0
    else
        frc=$?
    fi
    if [ "$frc" -eq 1 ]; then
        echo "::warning::Could not create a temp file to list tracked archives - the archive-visibility notice did not run."
        return 0
    elif [ "$frc" -eq 2 ]; then
        local safe_repo_root
        safe_repo_root="$(sanitize_for_annotation "${repo_root}")"
        echo "::warning::\`git ls-files\` failed in ${safe_repo_root} - the archive-visibility notice did not run."
        return 0
    fi

    # The dedup this loop used to do inline now happens once, upstream, in
    # _git_ls_files_filtered_deduped() - safe to move because a conflicted
    # path's stages all carry the identical path string, so the extension
    # match below (keyed purely on that string) agrees across every stage
    # regardless of whether dedup ran before or after it (see that
    # function's own comment).
    local -a hits=()
    local raw_path lower_path ext matched
    for raw_path in "${raw_paths[@]}"; do
        lower_path="${raw_path,,}"
        matched=0
        for ext in "${archive_exts[@]}"; do
            case "$lower_path" in
                *"$ext")
                    matched=1
                    break
                    ;;
            esac
        done
        [ "$matched" -eq 1 ] && hits+=("$raw_path")
    done

    if [ "${#hits[@]}" -eq 0 ]; then
        return 0
    fi

    # One sanitize_for_annotation() call per hit rather than the batched
    # NUL-piped jq form assert_semgrep_report_complete() uses for its own
    # missing-path list: that form exists to survive an ARG_MAX-scale list
    # passed through jq's argv, which cannot happen here - `hits` is bounded
    # by how many archives a repository tracks, not by tree size.
    local safe_hits="" hit safe_hit
    for hit in "${hits[@]}"; do
        safe_hit="$(sanitize_for_annotation "${hit}")"
        if [ -z "$safe_hits" ]; then
            safe_hits="$safe_hit"
        else
            safe_hits="${safe_hits}%0A${safe_hit}"
        fi
    done

    echo "::notice::The tracked archive(s) below are opaque to the pinned engine - it neither scans their contents nor lists them as skipped, so any source code packed inside is invisible to code scanning. This is informational only and does not affect the job's outcome; review each individually.%0A${safe_hits}"
    return 0
}
