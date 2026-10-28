#!/usr/bin/env python3
# Exercises i18n_core_overlap.py. Every violation case has a legitimate
# neighbour that must pass, because a false positive blocks a contributor and a
# missed case lets a module override core texts.
import contextlib
import importlib.util
import io
import os
import tempfile
import unittest

import polib

_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "lib", "i18n_core_overlap.py"
)
_spec = importlib.util.spec_from_file_location("i18n_core_overlap", _MODULE_PATH)
assert _spec is not None and _spec.loader is not None
overlap = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(overlap)

_TAGS = ["2.1.27", "2.2.0", "2.2.1", "2.2.6", "2.3.0", "2.2.6-rc1", "v2.2.5", "3.0.0"]


def _entry(msgid, msgstr="", msgctxt=None, msgid_plural="", plural=None):
    entry = polib.POEntry(msgid=msgid, msgstr=msgstr, msgctxt=msgctxt, msgid_plural=msgid_plural)

    if plural is not None:
        entry.msgstr_plural = dict(enumerate(plural))

    return entry


def _write(path, entries):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    catalogue = polib.POFile()
    catalogue.metadata = {"Content-Type": "text/plain; charset=UTF-8"}

    for entry in entries:
        catalogue.append(entry)

    catalogue.save(path)


class SelectTagsTest(unittest.TestCase):
    def test_tilde_with_patch_keeps_the_minor_line(self):
        self.assertEqual(["2.2.0", "2.2.1", "2.2.6"], overlap.select_tags("~2.2.0", _TAGS))

    def test_tilde_raises_the_lower_bound(self):
        self.assertEqual(["2.2.1", "2.2.6"], overlap.select_tags("~2.2.1", _TAGS))

    def test_tilde_with_minor_allows_later_minors(self):
        self.assertEqual(
            ["2.2.0", "2.2.1", "2.2.6", "2.3.0"], overlap.select_tags("~2.2", _TAGS)
        )

    def test_caret_keeps_the_major(self):
        self.assertEqual(
            ["2.1.27", "2.2.0", "2.2.1", "2.2.6", "2.3.0"], overlap.select_tags("^2.1", _TAGS)
        )

    def test_alternatives_are_united(self):
        self.assertEqual(
            ["2.1.27", "2.2.0", "2.2.1", "2.2.6"],
            overlap.select_tags("~2.1.0 || ~2.2.0", _TAGS),
        )

    def test_caret_on_a_zero_major_keeps_the_minor(self):
        self.assertEqual(["0.2.0", "0.2.5"], overlap.select_tags("^0.2.0", ["0.1.9", "0.2.0", "0.2.5", "0.3.0"]))

    def test_a_partial_exact_version_names_a_release_line(self):
        self.assertEqual(["2.2.0", "2.2.1", "2.2.6"], overlap.select_tags("2.2", _TAGS))

    def test_exact_version(self):
        self.assertEqual(["2.2.1"], overlap.select_tags("2.2.1", _TAGS))

    def test_prereleases_and_prefixed_tags_are_ignored(self):
        self.assertNotIn("2.2.6-rc1", overlap.select_tags("~2.2.0", _TAGS))
        self.assertNotIn("v2.2.5", overlap.select_tags("~2.2.0", _TAGS))

    def test_unsupported_syntax_is_refused(self):
        with self.assertRaises(overlap.InputError):
            overlap.select_tags(">=2.2.0 <2.3", _TAGS)

    def test_a_constraint_without_a_tag_is_refused(self):
        with self.assertRaises(overlap.InputError):
            overlap.select_tags("~9.9.0", _TAGS)


class FindViolationsTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.lang = os.path.join(self._tmp.name, "lang")
        self.core = os.path.join(self._tmp.name, "core")

    def _core(self, tag, locale, entries):
        _write(os.path.join(self.core, tag, locale, "messages.po"), entries)

    def _module(self, locale, entries):
        _write(os.path.join(self.lang, locale, "messages.po"), entries)

    def test_a_filled_core_text_is_a_violation(self):
        self._core("2.2.6", "nn", [_entry("Details", "Detaljar")])
        self._module("nn", [_entry("Details", "Detaljar")])

        violations = overlap.find_violations(self.lang, self.core)

        self.assertEqual(1, len(violations))
        self.assertEqual("Details", violations[0]["msgid"])
        self.assertEqual(["2.2.6"], violations[0]["tags"])
        self.assertTrue(violations[0]["file"].endswith("nn/messages.po"))

    def test_a_different_translation_of_a_core_text_is_still_a_violation(self):
        self._core("2.2.6", "nn", [_entry("General", "Allment")])
        self._module("nn", [_entry("General", "Generelt")])

        self.assertEqual(1, len(overlap.find_violations(self.lang, self.core)))

    def test_an_empty_entry_for_a_core_text_passes(self):
        self._core("2.2.6", "nn", [_entry("Details", "Detaljar")])
        self._module("nn", [_entry("Details", "")])

        self.assertEqual([], overlap.find_violations(self.lang, self.core))

    def test_a_module_only_text_passes(self):
        self._core("2.2.6", "nn", [_entry("Details", "Detaljar")])
        self._module("nn", [_entry("Colors", "Fargar")])

        self.assertEqual([], overlap.find_violations(self.lang, self.core))

    def test_a_text_core_leaves_untranslated_in_that_locale_passes(self):
        self._core("2.2.6", "nn", [_entry("Details", "")])
        self._module("nn", [_entry("Details", "Detaljar")])

        self.assertEqual([], overlap.find_violations(self.lang, self.core))

    def test_the_locale_decides_which_core_catalogue_applies(self):
        self._core("2.2.6", "de", [_entry("Details", "Details")])
        self._core("2.2.6", "nn", [])
        self._module("nn", [_entry("Details", "Detaljar")])

        self.assertEqual([], overlap.find_violations(self.lang, self.core))

    def test_a_locale_without_a_core_catalogue_passes(self):
        self._core("2.2.6", "de", [_entry("Details", "Details")])
        self._module("xx", [_entry("Details", "Detaljar")])

        self.assertEqual([], overlap.find_violations(self.lang, self.core))

    def test_a_text_that_only_an_older_release_translates_is_found(self):
        self._core("2.2.0", "nn", [_entry("Old text", "Gammal tekst")])
        self._core("2.2.6", "nn", [])
        self._module("nn", [_entry("Old text", "Gammal tekst")])

        violations = overlap.find_violations(self.lang, self.core)

        self.assertEqual(["2.2.0"], violations[0]["tags"])

    def test_the_context_is_part_of_the_key(self):
        self._core("2.2.6", "nn", [_entry("Death", "Dødsfall", msgctxt="EVENT")])
        self._module("nn", [_entry("Death", "Dauden"), _entry("Death", "Dødsfall", msgctxt="EVENT")])

        violations = overlap.find_violations(self.lang, self.core)

        self.assertEqual(1, len(violations))

    def test_a_singular_entry_does_not_shadow_a_core_plural_entry(self):
        self._core(
            "2.2.6",
            "nn",
            [_entry("%s child", msgid_plural="%s children", plural=["%s barn", "%s born"])],
        )
        self._module("nn", [_entry("%s child", "%s barn")])

        self.assertEqual([], overlap.find_violations(self.lang, self.core))

    def test_a_filled_plural_entry_of_a_core_plural_is_a_violation(self):
        entry = _entry("%s child", msgid_plural="%s children", plural=["%s barn", "%s born"])
        self._core("2.2.6", "nn", [entry])
        self._module("nn", [entry])

        self.assertEqual(1, len(overlap.find_violations(self.lang, self.core)))

    def test_a_plural_entry_with_only_empty_forms_passes(self):
        self._core(
            "2.2.6",
            "nn",
            [_entry("%s child", msgid_plural="%s children", plural=["%s barn", "%s born"])],
        )
        self._module("nn", [_entry("%s child", msgid_plural="%s children", plural=["", ""])])

        self.assertEqual([], overlap.find_violations(self.lang, self.core))

    def test_an_obsolete_entry_is_ignored(self):
        self._core("2.2.6", "nn", [_entry("Details", "Detaljar")])
        obsolete = _entry("Details", "Detaljar")
        obsolete.obsolete = True
        self._module("nn", [obsolete])

        self.assertEqual([], overlap.find_violations(self.lang, self.core))

    def test_an_unreadable_catalogue_is_an_input_error(self):
        os.makedirs(os.path.join(self.lang, "nn"))
        with open(os.path.join(self.lang, "nn", "messages.po"), "w", encoding="utf-8") as handle:
            handle.write('msgid "a"\nmsgstr "x"\nbogus line\n')
        self._core("2.2.6", "nn", [_entry("Details", "Detaljar")])

        with self.assertRaises(overlap.InputError):
            overlap.find_violations(self.lang, self.core)

    def test_an_obsolete_core_entry_does_not_count(self):
        obsolete = _entry("Details", "Detaljar")
        obsolete.obsolete = True
        self._core("2.2.6", "nn", [obsolete])
        self._module("nn", [_entry("Details", "Detaljar")])

        self.assertEqual([], overlap.find_violations(self.lang, self.core))

    def test_a_missing_catalogue_directory_is_an_input_error(self):
        with self.assertRaises(overlap.InputError):
            overlap.find_violations(os.path.join(self._tmp.name, "absent"), self.core)

    def test_a_missing_core_root_is_an_input_error(self):
        self._module("nn", [_entry("Details", "Detaljar")])

        with self.assertRaises(overlap.InputError):
            overlap.find_violations(self.lang, os.path.join(self._tmp.name, "absent"))


class CheckCommandTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.lang = os.path.join(self._tmp.name, "lang")
        self.core = os.path.join(self._tmp.name, "core")
        _write(os.path.join(self.core, "2.2.6", "nn", "messages.po"), [_entry("Details", "Detaljar")])

    def _run(self):
        out = io.StringIO()
        err = io.StringIO()

        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = overlap.main(["check", "--lang-dir", self.lang, "--core-root", self.core])

        return status, out.getvalue(), err.getvalue()

    def test_a_violation_fails_with_file_line_and_reason(self):
        _write(os.path.join(self.lang, "nn", "messages.po"), [_entry("Details", "Detaljar")])

        status, out, _ = self._run()

        self.assertEqual(1, status)
        self.assertRegex(out, r"::error file=.*nn/messages\.po,line=\d+::The text 'Details' is translated by webtrees core in nn")

    def test_a_clean_catalogue_passes(self):
        _write(os.path.join(self.lang, "nn", "messages.po"), [_entry("Details", "")])

        status, out, _ = self._run()

        self.assertEqual(0, status)
        self.assertNotIn("::error", out)

    def test_several_violations_are_counted_in_the_plural(self):
        _write(
            os.path.join(self.lang, "nn", "messages.po"),
            [_entry("Details", "Detaljar"), _entry("Details", "Detaljar", msgctxt="x")],
        )
        _write(os.path.join(self.core, "2.2.6", "nn", "messages.po"), [_entry("Details", "Detaljar"), _entry("Details", "Detaljar", msgctxt="x")])

        status, _, err = self._run()

        self.assertEqual(1, status)
        self.assertIn("2 catalogue entries override", err)

    def test_one_violation_is_counted_in_the_singular(self):
        _write(os.path.join(self.lang, "nn", "messages.po"), [_entry("Details", "Detaljar")])

        _, _, err = self._run()

        self.assertIn("1 catalogue entry override", err)

    def test_annotation_text_is_escaped_and_capped(self):
        text = overlap._annotation_text("50%\nline" + "x" * 200)

        self.assertNotIn("\n", text)
        self.assertIn("%25", text)
        self.assertIn("%0A", text)
        self.assertLessEqual(len(text), 90)

    def test_an_unusable_input_exits_with_two(self):
        self.lang = os.path.join(self._tmp.name, "absent")

        status, out, _ = self._run()

        self.assertEqual(2, status)
        self.assertIn("::error::", out)


class TagsCommandTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tags_file = os.path.join(self._tmp.name, "tags")

        with open(self.tags_file, "w", encoding="utf-8") as handle:
            handle.write("\n".join(_TAGS) + "\n")

    def _composer(self, content):
        path = os.path.join(self._tmp.name, "composer.json")

        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)

        return path

    def _run(self, composer):
        out = io.StringIO()

        with contextlib.redirect_stdout(out):
            status = overlap.main(["tags", "--composer", composer, "--tags-file", self.tags_file])

        return status, out.getvalue()

    def test_the_tags_of_the_composer_constraint_are_printed(self):
        status, out = self._run(self._composer('{"require": {"fisharebest/webtrees": "~2.2.0"}}'))

        self.assertEqual(0, status)
        self.assertEqual(["2.2.0", "2.2.1", "2.2.6"], out.split())

    def test_a_composer_file_without_the_requirement_exits_with_two(self):
        status, out = self._run(self._composer('{"require": {"php": "^8.3"}}'))

        self.assertEqual(2, status)
        self.assertIn("::error::", out)

    def test_an_unsupported_constraint_exits_with_two(self):
        status, _ = self._run(self._composer('{"require": {"fisharebest/webtrees": ">=2.2"}}'))

        self.assertEqual(2, status)


if __name__ == "__main__":
    unittest.main()
