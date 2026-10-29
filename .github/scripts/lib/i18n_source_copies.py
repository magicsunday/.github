#!/usr/bin/env python3
"""Reject module catalogue entries that are copies of their own source text.

The message ids of a module are its source texts, so a translation that equals
its message id carries no translation. An empty translation shows the same
text through the gettext fallback, so the copy only adds weight and goes stale
when the source text is reworded.

A singular entry is a copy when its translation equals the message id. A
plural entry is a copy only when every form is filled and each one equals the
message id or the plural message id. A plural entry in which one form differs
from both source texts is a translation, because a language may spell a single
form like the source language.

Exit status: 0 clean, 1 copies found, 2 unusable input.
"""
import argparse
import os
import sys

import i18n_core_overlap as overlap


def is_copy(entry):
    """Tell whether a catalogue entry repeats its source text as its translation."""
    if entry.obsolete or entry.fuzzy:
        return False

    if entry.msgstr_plural:
        sources = {entry.msgid, entry.msgid_plural}
        forms = list(entry.msgstr_plural.values())

        return all(form != "" and form in sources for form in forms)

    return entry.msgstr != "" and entry.msgstr == entry.msgid


def find_copies(lang_dir):
    """Return one record per catalogue entry that is a copy of its source text."""
    copies = []

    for locale in overlap.list_locales(lang_dir):
        path = os.path.join(lang_dir, locale, "messages.po")

        for entry in overlap._load(path):
            if is_copy(entry):
                copies.append(
                    {
                        "file": path,
                        "line": entry.linenum,
                        "locale": locale,
                        "msgid": entry.msgid,
                    }
                )

    return copies


def _cmd_check(args):
    copies = find_copies(args.lang_dir)

    for copy in copies:
        print(
            "::error file=%s,line=%d::The translation of '%s' in %s repeats its source text. "
            "Leave the translation empty, the source text shows without it."
            % (
                overlap._annotation_property(copy["file"]),
                copy["line"],
                overlap._annotation_text(copy["msgid"]),
                copy["locale"],
            )
        )

    if copies:
        print(
            "%d catalogue entr%s repeat their source text."
            % (len(copies), "y" if len(copies) == 1 else "ies"),
            file=sys.stderr,
        )

        return 1

    print("No catalogue entry repeats its source text.")

    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Reject catalogue entries that copy their source text.")
    commands = parser.add_subparsers(dest="command", required=True)

    check = commands.add_parser("check")
    check.add_argument("--lang-dir", required=True)
    check.set_defaults(handler=_cmd_check)

    args = parser.parse_args(argv)

    try:
        return args.handler(args)
    except overlap.InputError as error:
        print("::error::%s" % overlap._escape(str(error)))

        return 2


if __name__ == "__main__":
    sys.exit(main())
