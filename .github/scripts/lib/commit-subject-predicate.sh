#!/usr/bin/env bash
# The commit-subject predicate commit-convention.yml applies to a pull
# request's title and to every commit subject in it. The rule itself is
# stated once, in that workflow's header; this file is its executable form.
# Proven against a decision table by
# .github/scripts/tests/test-commit-subject-predicate.sh, which run-tests.sh
# runs on every pull request here and commit-convention.yml runs again on the
# consumer's runner before judging anything (issue #107).
#
# Commit subjects are written in English, so in practice the leading capital
# is always A-Z and the documented convention says so. The `[[:upper:]]`
# class below stays deliberately wider: the capital *match* sits only in
# accept positions (the byte-based `tr` uses the class too, but on ASCII
# only), so widening it can only add PASSes and cannot produce a false block.
# Narrowing it to `[A-Z]` would buy nothing — no subject in this repository's
# history starts with a non-ASCII capital — while turning a documentation
# change into a behaviour one.
#
# That is a claim about the capital class ALONE, not about the gate. The gate
# is not a superset of `^[A-Z]` — the `GH-` routing, the conventional-commit
# ban and the path-like ban below each reject subjects that do start with a
# capital, on purpose, and the convention states every one of them too.
#
# `[[:upper:]]` is locale-dependent: under LC_ALL=C a subject starting with
# `Ä` is NOT considered uppercase and would be rejected. A UTF-8 locale is
# therefore load-bearing for that width — see locale_is_utf8() below, and the
# job-level pin in commit-convention.yml. The locale buys that width for the
# bash regex only: `tr` is byte-based here and lowercases ASCII alone, which
# suffices because every banned prefix is ASCII.

# Returns 0 when the subject satisfies the convention.
subject_is_valid() {
    local subject="$1"
    local lowered

    # An absent subject is never acceptable.
    [ -n "$subject" ] || return 1

    # Subjects git generates itself keep their own wording. This
    # is checked BEFORE the prefix ban on purpose, so reverting
    # someone else's conventional-commit subject does not fail —
    # a table row pins that order.
    case "$subject" in
        "Merge "*|"Revert "*) return 0 ;;
    esac

    # Conventional-commit prefixes, any case, with or without
    # a scope. Matched against the finite set of types rather
    # than "any word followed by a colon", so an ordinary
    # subject that happens to contain a colon is unaffected.
    # One expression rather than a `case` arm per spelling: the
    # type, the optional scope and the optional breaking-change
    # `!` combine, and enumerating the combinations left the
    # unscoped bang form (`Feat!:`) accepted while the scoped
    # one was blocked.
    lowered=$(printf '%s' "$subject" | tr '[:upper:]' '[:lower:]')
    if [[ "$lowered" =~ ^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([^\)]*\))?!?: ]]; then
        return 1
    fi

    # A path-like start: a slash before the first colon. No
    # whitespace is required after it — `Src/Module.php:fix`
    # is the same mistake as `Src/Module.php: fix`, and the
    # character class cannot cross a colon, so an ordinary
    # subject containing a later path is unaffected.
    if [[ "$subject" =~ ^[^:[:space:]]*/[^:[:space:]]*: ]]; then
        return 1
    fi

    # Keyed on the subject, not on the branch, so the rule stays
    # decidable for commits already on the default branch.
    if [[ "$subject" == GH-* ]]; then
        [[ "$subject" =~ ^GH-[0-9]+:\ [[:upper:]] ]]
    else
        [[ "$subject" =~ ^[[:upper:]] ]]
    fi
}

# Returns 0 when locale name "$1" selects a UTF-8 codeset. Matches the
# property subject_is_valid() depends on, not one spelling, so `C.UTF-8`,
# `C.utf8` and `en_US.UTF-8` (with or without an `@modifier`) all pass.
locale_is_utf8() {
    case "$1" in
        *.[Uu][Tt][Ff]-8|*.[Uu][Tt][Ff]8|*.[Uu][Tt][Ff]-8@*|*.[Uu][Tt][Ff]8@*) return 0 ;;
        *) return 1 ;;
    esac
}
