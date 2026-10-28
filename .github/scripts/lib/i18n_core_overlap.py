#!/usr/bin/env python3
"""Reject module catalogue entries that override webtrees core texts.

webtrees merges the compiled catalogue of every custom module over its own, so
a non-empty translation in a module replaces the core text of the same key in
the whole installation. An entry with an empty translation is not compiled and
lets core apply, so it is fine.

Two subcommands:

  tags     Print the webtrees release tags that a composer constraint covers.
  check    Compare module catalogues with the core catalogues of those tags.

Exit status: 0 clean, 1 violations found, 2 unusable input.
"""
import argparse
import glob
import json
import os
import re
import sys

import polib

# Annotation text is capped so a long msgid cannot flood the log.
_MAX_TEXT = 80

# A locale directory name ends up in a workflow command and in a URL, so only
# the characters of a real locale tag are accepted.
_LOCALE_RE = re.compile(r"^[A-Za-z0-9_@-]+$")

_TAG_RE = re.compile(r"^\d+\.\d+\.\d+$")
_CONSTRAINT_RE = re.compile(r"^(?P<op>[~^]?)(?P<ver>\d+(?:\.\d+){0,2})$")


class InputError(Exception):
    """The input cannot be evaluated, which is distinct from a violation."""


def _version(text):
    return tuple(int(part) for part in text.split("."))


def _tag_matches(tag, op, bound):
    """Match one release tag against a single ~, ^ or exact constraint."""
    version = _version(tag)
    padded = bound + (0,) * (3 - len(bound))

    if version < padded:
        return False

    if op == "":
        # composer reads a partial version such as 2.2 as the exact release 2.2.0.
        return version == padded

    if op == "~":
        # ~X.Y.Z allows patch releases of X.Y, ~X.Y allows minor releases of X.
        keep = 2 if len(bound) == 3 else 1
        return version[:keep] == padded[:keep]

    # ^ keeps the left-most non-zero component.
    if padded[0] > 0:
        return version[0] == padded[0]

    return version[:2] == padded[:2]


def select_tags(constraint, available_tags):
    """Return the stable tags covered by a composer constraint, sorted.

    Supports the ~, ^ and exact forms, joined by `||`. Any other syntax raises
    InputError, so the caller names the tags explicitly instead of getting a
    silently wrong selection.
    """
    alternatives = []

    for alternative in constraint.split("||"):
        alternative = alternative.strip()
        match = _CONSTRAINT_RE.match(alternative)

        if match is None:
            raise InputError(
                "Unsupported webtrees constraint '%s', pass the core tags explicitly." % alternative
            )

        alternatives.append((match.group("op"), _version(match.group("ver"))))

    tags = sorted(
        (tag for tag in available_tags if _TAG_RE.match(tag)),
        key=_version,
    )
    selected = [
        tag
        for tag in tags
        if any(_tag_matches(tag, op, bound) for op, bound in alternatives)
    ]

    if not selected:
        raise InputError("The constraint '%s' matches none of the webtrees tags." % constraint)

    return selected


def _entry_key(entry):
    return (entry.msgctxt or "", entry.msgid, entry.msgid_plural or "")


def _is_translated(entry):
    """Core side: its catalogue reader keeps a plural entry with any filled form."""
    if entry.msgstr_plural:
        return any(form != "" for form in entry.msgstr_plural.values())

    return entry.msgstr != ""


def _is_compiled(entry):
    """Module side: what the module build compiles into its catalogue.

    The build leaves out obsolete and fuzzy entries and every plural entry
    whose first form is empty.
    """
    if entry.obsolete or entry.fuzzy:
        return False

    if entry.msgstr_plural:
        return entry.msgstr_plural.get(0, "") != ""

    return entry.msgstr != ""


def _load(path):
    try:
        return polib.pofile(path)
    except (OSError, ValueError) as error:
        raise InputError("Cannot read catalogue %s: %s" % (path, error))


def _core_index(core_root, locale):
    """Map every translated core key of a locale to the tags that translate it."""
    index = {}

    for tag in sorted(os.listdir(core_root)):
        path = os.path.join(core_root, tag, locale, "messages.po")

        if not os.path.isfile(path):
            continue

        for entry in _load(path):
            if entry.obsolete or not _is_translated(entry):
                continue

            index.setdefault(_entry_key(entry), []).append(tag)

    return index


def _escape(text):
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def _annotation_text(text):
    return _escape(text if len(text) <= _MAX_TEXT else text[: _MAX_TEXT - 3] + "...")


def _annotation_property(text):
    """Escape a value for a property of a workflow command, such as file=."""
    return _escape(text).replace(":", "%3A").replace(",", "%2C")


def find_violations(lang_dir, core_root):
    """Return one record per module entry that overrides a core translation."""
    if not os.path.isdir(lang_dir):
        raise InputError("Catalogue directory %s does not exist." % lang_dir)

    if not os.path.isdir(core_root):
        raise InputError("Core catalogue root %s does not exist." % core_root)

    # Without any core catalogue every module entry would pass, so a mistyped
    # release tag must not read as a clean result.
    if not glob.glob(os.path.join(glob.escape(core_root), "*", "*", "messages.po")):
        raise InputError("No webtrees core catalogue was found in %s." % core_root)

    violations = []

    for locale in sorted(os.listdir(lang_dir)):
        path = os.path.join(lang_dir, locale, "messages.po")

        if not os.path.isfile(path):
            continue

        if _LOCALE_RE.fullmatch(locale) is None:
            raise InputError("The catalogue directory name '%s' is not a locale tag." % _annotation_text(locale))

        core = _core_index(core_root, locale)

        if not core:
            continue

        for entry in _load(path):
            if not _is_compiled(entry):
                continue

            tags = core.get(_entry_key(entry))

            if tags is None:
                continue

            violations.append(
                {
                    "file": path,
                    "line": entry.linenum,
                    "locale": locale,
                    "msgid": entry.msgid,
                    "tags": tags,
                }
            )

    return violations


def _cmd_tags(args):
    try:
        with open(args.composer, encoding="utf-8") as handle:
            composer = json.load(handle)
    except (OSError, ValueError) as error:
        raise InputError("Cannot read %s: %s" % (args.composer, error))

    require = composer.get("require") if isinstance(composer, dict) else None
    constraint = require.get("fisharebest/webtrees") if isinstance(require, dict) else None

    if not isinstance(constraint, str) or not constraint:
        raise InputError("%s does not require fisharebest/webtrees." % args.composer)

    with open(args.tags_file, encoding="utf-8") as handle:
        available = [line.strip() for line in handle if line.strip()]

    print("\n".join(select_tags(constraint, available)))

    return 0


def _cmd_check(args):
    violations = find_violations(args.lang_dir, args.core_root)

    for violation in violations:
        print(
            "::error file=%s,line=%d::The text '%s' is translated by webtrees core in %s "
            "(release %s). Leave the translation empty so core applies. A filled entry "
            "replaces the core text in the whole installation."
            % (
                _annotation_property(violation["file"]),
                violation["line"],
                _annotation_text(violation["msgid"]),
                violation["locale"],
                ", ".join(violation["tags"]),
            )
        )

    if violations:
        print(
            "%d catalogue entr%s override webtrees core texts."
            % (len(violations), "y" if len(violations) == 1 else "ies"),
            file=sys.stderr,
        )

        return 1

    print("No catalogue entry overrides a webtrees core text.")

    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Reject module catalogue entries that override webtrees core texts.")
    commands = parser.add_subparsers(dest="command", required=True)

    tags = commands.add_parser("tags")
    tags.add_argument("--composer", required=True)
    tags.add_argument("--tags-file", required=True)
    tags.set_defaults(handler=_cmd_tags)

    check = commands.add_parser("check")
    check.add_argument("--lang-dir", required=True)
    check.add_argument("--core-root", required=True)
    check.set_defaults(handler=_cmd_check)

    args = parser.parse_args(argv)

    try:
        return args.handler(args)
    except InputError as error:
        print("::error::%s" % _escape(str(error)))

        return 2


if __name__ == "__main__":
    sys.exit(main())
