#!/usr/bin/env python3
# Exercises i18n_source_copies.py. Every violation case has a legitimate
# neighbour that must pass, because a false positive blocks a contributor and a
# missed case lets a copy of the source text stay in a catalogue.
import contextlib
import importlib.util
import io
import os
import sys
import tempfile
import unittest

import polib

_LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib")
sys.path.insert(0, _LIB)

_spec = importlib.util.spec_from_file_location(
    "i18n_source_copies", os.path.join(_LIB, "i18n_source_copies.py")
)
assert _spec is not None and _spec.loader is not None
copies = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(copies)


def _entry(msgid, msgstr="", msgctxt=None, msgid_plural="", plural=None, flags=None, obsolete=False):
    entry = polib.POEntry(
        msgid=msgid,
        msgstr=msgstr,
        msgctxt=msgctxt,
        msgid_plural=msgid_plural,
        flags=flags or [],
        obsolete=obsolete,
    )

    if plural is not None:
        entry.msgstr_plural = dict(enumerate(plural))

    return entry


def _write(lang_dir, locale, entries):
    path = os.path.join(lang_dir, locale, "messages.po")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    catalogue = polib.POFile()
    catalogue.metadata = {"Content-Type": "text/plain; charset=UTF-8"}

    for entry in entries:
        catalogue.append(entry)

    catalogue.save(path)

    return path


def _line_of(path, text):
    with open(path, encoding="utf-8") as handle:
        return handle.read().split("\n").index(text) + 1


class IsCopyTest(unittest.TestCase):
    def test_singular_translation_equal_to_the_source_is_a_copy(self):
        self.assertTrue(copies.is_copy(_entry("Portal", "Portal")))

    def test_singular_translation_that_differs_is_no_copy(self):
        self.assertFalse(copies.is_copy(_entry("Portal", "Zugang")))

    def test_case_difference_is_no_copy(self):
        self.assertFalse(copies.is_copy(_entry("Portal", "portal")))

    def test_empty_translation_is_no_copy(self):
        self.assertFalse(copies.is_copy(_entry("Portal", "")))

    def test_plural_with_every_form_equal_to_a_source_text_is_a_copy(self):
        entry = _entry("%s man", msgid_plural="%s men", plural=["%s man", "%s men"])

        self.assertTrue(copies.is_copy(entry))

    def test_plural_forms_may_both_repeat_the_singular_source(self):
        entry = _entry("%s man", msgid_plural="%s men", plural=["%s man", "%s man"])

        self.assertTrue(copies.is_copy(entry))

    def test_plural_with_one_differing_form_is_no_copy(self):
        entry = _entry("%s man", msgid_plural="%s men", plural=["%s man", "%s mannen"])

        self.assertFalse(copies.is_copy(entry))

    def test_plural_with_an_empty_form_is_no_copy(self):
        entry = _entry("%s man", msgid_plural="%s men", plural=["%s man", ""])

        self.assertFalse(copies.is_copy(entry))

    def test_plural_with_every_form_empty_is_no_copy(self):
        entry = _entry("%s man", msgid_plural="%s men", plural=["", ""])

        self.assertFalse(copies.is_copy(entry))

    def test_fuzzy_copy_is_ignored(self):
        self.assertFalse(copies.is_copy(_entry("Portal", "Portal", flags=["fuzzy"])))

    def test_obsolete_copy_is_ignored(self):
        self.assertFalse(copies.is_copy(_entry("Portal", "Portal", obsolete=True)))

    def test_context_does_not_hide_a_copy(self):
        self.assertTrue(copies.is_copy(_entry("Statistics", "Statistics", msgctxt="menu")))


class FindCopiesTest(unittest.TestCase):
    def test_reports_each_copy_with_locale_and_line_in_every_locale(self):
        with tempfile.TemporaryDirectory() as lang_dir:
            _write(lang_dir, "de", [_entry("Portal", "Portal"), _entry("Home", "Start")])
            _write(lang_dir, "en-GB", [_entry("Colorful", "Colorful")])

            found = copies.find_copies(lang_dir)

        self.assertEqual(
            [("de", "Portal"), ("en-GB", "Colorful")],
            [(record["locale"], record["msgid"]) for record in found],
        )

    def test_reports_the_line_of_each_copy(self):
        with tempfile.TemporaryDirectory() as lang_dir:
            path = _write(
                lang_dir,
                "de",
                [_entry("Home", "Start"), _entry("Portal", "Portal"), _entry("Menu", "Menu")],
            )

            with open(path, encoding="utf-8") as handle:
                lines = handle.read().split("\n")

            expected = [lines.index('msgid "Portal"') + 1, lines.index('msgid "Menu"') + 1]
            found = copies.find_copies(lang_dir)

        self.assertEqual(expected, [record["line"] for record in found])
        self.assertNotEqual(expected[0], expected[1])

    def test_clean_catalogues_report_nothing(self):
        with tempfile.TemporaryDirectory() as lang_dir:
            _write(lang_dir, "de", [_entry("Portal", ""), _entry("Home", "Start")])
            _write(lang_dir, "en-GB", [_entry("Colorful", "Colourful")])

            self.assertEqual([], copies.find_copies(lang_dir))

    def test_missing_directory_is_an_input_error(self):
        with self.assertRaises(copies.overlap.InputError):
            copies.find_copies("/nonexistent/catalogues")


class MainTest(unittest.TestCase):
    def _run(self, lang_dir):
        out = io.StringIO()
        err = io.StringIO()

        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = copies.main(["check", "--lang-dir", lang_dir])

        return status, out.getvalue(), err.getvalue()

    def test_copy_fails_with_an_annotation_naming_file_and_line(self):
        with tempfile.TemporaryDirectory() as lang_dir:
            path = _write(lang_dir, "de", [_entry("Portal", "Portal")])

            status, out, err = self._run(lang_dir)
            portal_line = _line_of(path, 'msgid "Portal"')

        self.assertEqual(1, status)
        self.assertIn("::error file=%s,line=" % path.replace(":", "%3A").replace(",", "%2C"), out)
        self.assertIn("'Portal'", out)
        self.assertIn("line=%d::" % portal_line, out)
        self.assertIn("Catalogue entries that copy their source text: 1", err)

    def test_clean_catalogue_passes(self):
        with tempfile.TemporaryDirectory() as lang_dir:
            _write(lang_dir, "de", [_entry("Portal", "")])

            status, out, _ = self._run(lang_dir)

        self.assertEqual(0, status)
        self.assertNotIn("::error", out)

    def test_missing_directory_exits_two_with_an_error_annotation(self):
        status, out, _ = self._run("/nonexistent/catalogues")

        self.assertEqual(2, status)
        self.assertIn("::error::", out)

    def test_annotation_text_is_escaped_for_a_workflow_command(self):
        with tempfile.TemporaryDirectory() as lang_dir:
            _write(lang_dir, "de", [_entry("100% sure\nreally", "100% sure\nreally")])

            _, out, _ = self._run(lang_dir)

        self.assertIn("100%25 sure%0Areally", out)
        self.assertEqual(1, out.count("\n"))


if __name__ == "__main__":
    unittest.main()
