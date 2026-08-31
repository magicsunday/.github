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
#   away. `tr '[:cntrl:]'` alone would map two DIFFERENT control bytes to
#   the same placeholder character and then collapse that placeholder to a
#   space in a second pass — colliding with any literal `?` already in the
#   path (a legal filename character) and silently mangling it the same
#   way. Folding straight to space in one pass has no such collision.
#   `tr '[:cntrl:]'` only recognizes single-byte ASCII control codes
#   (0x00-0x1F, 0x7F) — a control codepoint encoded as multi-byte UTF-8
#   (e.g. a C1 control such as U+0085 NEL) passes through unfolded, unlike
#   `semgrep-report-check.sh`'s Unicode-aware jq `gsub("[[:cntrl:]]"; " ")`
#   pipeline (issue #80, open).
# - A PERCENT-ENCODED control byte. As observed 2026-08-31 against a real
#   Actions run, GitHub Actions' own workflow-command escaping scheme
#   represented a literal `%`, CR or LF inside an annotation MESSAGE as
#   `%25`, `%0D`, `%0A` respectively, and the runner decoded those
#   sequences back on render — it cannot tell an already-escaped sequence
#   from literal `%0D` text that happened to be in the source data. A path
#   literally named `%0D%0A::error::forged` passes `tr '[:cntrl:]'`
#   untouched (no raw control byte in it) and would decode to a real CRLF
#   once the runner renders it. Escaping a literal `%` to `%25` FIRST is
#   what closes this - the identical defense semgrep-report-check.sh
#   applies to report-derived text via its own `gsub("%"; "%25")`.
sanitize_for_annotation() {
    printf '%s' "$1" | sed 's/%/%25/g' | tr '[:cntrl:]' ' '
}
