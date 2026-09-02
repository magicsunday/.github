#!/usr/bin/env bash
# Sourced by semgrepignore-guard.sh and semgrep-report-check.sh, so both
# callers share ONE sanitizer rather than carrying their own copies that can
# drift apart - semgrep-report-check.sh's own jq_error path once did exactly
# that (issue #78): it kept the same `tr '[:cntrl:]' '?'` collision
# sanitize_for_annotation() itself used to fold to before GH-48 fixed it
# here, so a fix landed in one copy without reaching the other.

# Neutralizes a string before the caller embeds it into a GitHub Actions
# `::error::` log annotation, closing two independent forgery channels a
# caller-controlled path can carry:
#
# - A raw control byte. As observed 2026-08-31 against a real Actions run,
#   the runner's log reader was .NET-based and `TextReader.ReadLine()`
#   treated a bare CR as a line terminator the same way it treated LF — so
#   an embedded CR, not only LF, can forge what reads as a second,
#   attacker-authored annotation line unless every control byte is folded
#   away. This routes through jq's own Unicode-aware `gsub("[[:cntrl:]]"; " ")`
#   rather than bash `tr '[:cntrl:]'`, which recognizes only single-byte
#   ASCII control codes (0x00-0x1F, 0x7F) and passed a control codepoint
#   encoded as multi-byte UTF-8 (e.g. a C1 control such as U+0085 NEL)
#   through unfolded (issue #80) - jq now folds the exact codepoint set
#   `semgrep-report-check.sh`'s own `.path` pipeline folds, using the same
#   jq builtin class `tr` never covered. The filter text is still several
#   hand-maintained copies, not shared code (issue #91 proposes hoisting it
#   into one shared constant) - test-annotation-sanitize-jq-parity.sh keeps
#   every copy in sync by comparing their literal strings against each
#   other, not by removing the duplication. A raw, non-UTF-8-encoded byte in
#   that same range
#   (invalid on its own, with no continuation byte) is neutralized too, as
#   a side effect of jq requiring valid UTF-8 input: it substitutes U+FFFD
#   rather than erroring, which is not a control codepoint either.
# - A PERCENT-ENCODED control byte. As observed 2026-08-31 against a real
#   Actions run, GitHub Actions' own workflow-command escaping scheme
#   represented a literal `%`, CR or LF inside an annotation MESSAGE as
#   `%25`, `%0D`, `%0A` respectively, and the runner decoded those
#   sequences back on render — it cannot tell an already-escaped sequence
#   from literal `%0D` text that happened to be in the source data. A path
#   literally named `%0D%0A::error::forged` would decode to a real CRLF
#   once the runner renders it unless a literal `%` is escaped to `%25`
#   FIRST - the identical defense, and the identical ordering,
#   semgrep-report-check.sh applies to report-derived text via its own
#   `gsub("%"; "%25")`.
#
# Piped rather than handed to jq via a here-string (`<<<`): a here-string
# appends a trailing newline that the cntrl fold below would turn into a
# trailing space nothing in the actual input produced. `-s` (slurp) reads
# the piped bytes as one string, embedded newlines included, so multi-line
# input (e.g. several matched paths) folds to one space-joined line same as
# before.
#
# Degrades to $2 (default "(unavailable)") if jq itself fails - it shells
# out (issue #80) and can now fail where the sed/tr version it replaced
# practically never did. This function therefore never returns non-zero
# itself; both call sites used to wrap every call in their own identical
# `2>/dev/null || safe="(placeholder)"` guard, which stayed in sync by luck
# rather than by construction (issue #83) - folding the fallback in here
# means a future third caller gets fail-closed behaviour for free instead of
# needing to remember the guard idiom itself.
#
# $2 is printed VERBATIM on that path, with none of the sanitisation $1
# gets - a future caller MUST pass only a fixed, developer-authored string
# literal, never text derived from $1 or from any other caller-controlled
# input, or the exact forgery this function exists to close reopens on the
# jq-failure branch.
sanitize_for_annotation() {
    local fallback="${2:-(unavailable)}"
    printf '%s' "$1" | jq -Rsr 'gsub("%"; "%25") | gsub("[[:cntrl:]]"; " ")' 2>/dev/null \
        || printf '%s' "${fallback}"
}
