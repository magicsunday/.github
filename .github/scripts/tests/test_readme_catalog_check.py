#!/usr/bin/env python3
# Exercises readme_catalog_check.py - the structural replacement for
# readme-catalog-check.sh's bash/regex mechanism (issue #101, issue #116).
# Every fixture here pins a real defect or a documented design decision
# from that mechanism's review history, re-expressed against the
# tokenizer that replaced it, so the coverage this repo already paid for
# is not lost in the rewrite.
import contextlib
import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import unittest

_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "lib", "readme_catalog_check.py"
)
_spec = importlib.util.spec_from_file_location("readme_catalog_check", _MODULE_PATH)
assert _spec is not None and _spec.loader is not None
readme_catalog_check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(readme_catalog_check)

_HEADER = "| Workflow | Purpose | Permissions |\n| --- | --- | --- |\n"

_TWO_TABLE_README = (
    _HEADER
    + "| `real.yml` | Does the real thing | `contents: read` |\n"
    "\n"
    "### Inputs\n"
    "\n"
    "| Workflow | Input | Default |\n"
    "| --- | --- | --- |\n"
    "| `gone.yml` | `some-input` | `false` |\n"
)


class _TempRepoTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.work_dir = self._tmp.name
        self.workflows_dir = os.path.join(self.work_dir, "workflows")
        os.makedirs(self.workflows_dir)
        self.readme_path = os.path.join(self.work_dir, "README.md")

    def _add_target(self, name, workflow_call=True):
        with open(os.path.join(self.workflows_dir, name), "w", encoding="utf-8") as handle:
            handle.write("on:\n    workflow_call:\n" if workflow_call else "on:\n    push:\n")

    def _write_readme(self, text):
        with open(self.readme_path, "w", encoding="utf-8") as handle:
            handle.write(text)

    def _check(self):
        return readme_catalog_check.check(self.workflows_dir, self.readme_path)


class SplitTableRowTest(unittest.TestCase):
    def test_not_a_row(self):
        self.assertIsNone(readme_catalog_check.split_table_row("prose, not a table row"))

    def test_leading_and_trailing_pipe(self):
        self.assertEqual(
            readme_catalog_check.split_table_row("| a | b | c |"), ["a", "b", "c"]
        )

    def test_leading_pipe_only(self):
        self.assertEqual(readme_catalog_check.split_table_row("| a | b | c"), ["a", "b", "c"])

    def test_zero_spaces_around_delimiters(self):
        self.assertEqual(readme_catalog_check.split_table_row("|a|b|c|"), ["a", "b", "c"])

    def test_backslash_has_no_special_meaning(self):
        # No escape handling at all - every `|` is a column boundary,
        # full stop (see split_table_row's own docstring for why).
        self.assertEqual(readme_catalog_check.split_table_row(r"| a\ | b |"), ["a\\", "b"])

    def test_tab_indented_line_is_still_a_row(self):
        self.assertEqual(readme_catalog_check.split_table_row("\t| a | b | c |"), ["a", "b", "c"])

    def test_four_space_indented_line_is_still_a_row(self):
        # Indentation no longer excludes a line from row recognition at
        # all (round 22): parse_catalog_table() closes the whole
        # "decoy hidden in some GFM construct" bug class structurally, by
        # treating ANY second header-shaped line anywhere in the file as
        # an ambiguity error, rather than by trying to tell a real header
        # apart from one hidden in an indented/fenced/commented block one
        # construct at a time - see readme_catalog_check.py's own header
        # comment for why. split_table_row() itself is back to a pure,
        # indentation-agnostic pipe splitter.
        self.assertEqual(readme_catalog_check.split_table_row("    | a | b | c |"), ["a", "b", "c"])


class ParseCatalogTableTest(_TempRepoTestCase):
    def _kinds(self, text):
        self._write_readme(text)
        return list(readme_catalog_check.parse_catalog_table(self.readme_path))

    def test_well_formed_table(self):
        kinds = self._kinds(
            _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        self.assertEqual(
            kinds,
            [("header", None), ("separator", None), ("row", "real.yml")],
        )

    def test_colon_alignment_separator_is_recognised(self):
        kinds = self._kinds(
            "| Workflow | Purpose | Permissions |\n"
            "|:---|:---:|---:|\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        self.assertEqual(kinds[1], ("separator", None))

    def test_header_tolerates_real_world_trailing_text(self):
        # This repo's own README.md header carries trailing text after
        # "Permissions" rather than the bare "...Permissions |" every
        # other fixture in this file uses (re-derive:
        # `grep -m1 '| Workflow | Purpose | Permissions' README.md`).
        kinds = self._kinds(
            "| Workflow | Purpose | Permissions the caller must grant |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        self.assertEqual(kinds[0], ("header", None))

    def test_near_miss_header_prefix_is_not_a_header(self):
        # Shares "Workflow"/"Purpose" but the third cell does not start
        # with "Permissions" at all - must fall through as an ordinary
        # (here: malformed) line, not be mistaken for the real header.
        kinds = self._kinds(
            "| Workflow | Purpose | Permission Level |\n"
            "\n"
            + _HEADER
            + "| `gone.yml` | Removed long ago | `contents: read` |\n"
        )
        # The decoy line never opens the table at all (started stays
        # False until the REAL header is seen), so only the real table's
        # three lines are yielded.
        self.assertEqual(
            kinds,
            [("header", None), ("separator", None), ("row", "gone.yml")],
        )

    def test_two_real_headers_anywhere_in_the_file_is_an_ambiguity_error(self):
        # A second, later occurrence of the real header text (e.g. two
        # catalog-shaped tables separated by a blank line) is no longer
        # silently ignored - with no way to tell which one is real, this
        # refuses to guess (issue #116, round 22).
        with self.assertRaises(ValueError) as ctx:
            self._kinds(
                _HEADER
                + "| `real.yml` | Does the real thing | `contents: read` |\n"
                "\n"
                + _HEADER
                + "| `real.yml` | Does the real thing | `contents: read` |\n"
            )
        self.assertIn("2 lines that look like the workflow catalog header", str(ctx.exception))

    def test_header_text_substring_in_prose_before_the_table_is_excluded(self):
        kinds = self._kinds(
            "See the catalog below (a decoy: | Workflow | Purpose | Permissions | "
            "is not a real header here).\n"
            "\n"
            + _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        self.assertEqual(
            kinds,
            [("header", None), ("separator", None), ("row", "real.yml")],
        )

    def test_duplicated_header_line_inside_the_table_body_is_an_ambiguity_error(self):
        with self.assertRaises(ValueError):
            self._kinds(
                _HEADER
                + "| `real.yml` | Does the real thing | `contents: read` |\n"
                "| Workflow | Purpose | Permissions |\n"
                "| `gone.yml` | Removed long ago | `contents: read` |\n"
            )

    def test_missing_separator_row_still_validates_the_next_row(self):
        kinds = self._kinds(
            "| Workflow | Purpose | Permissions |\n"
            "| `gone.yml` | Removed long ago | `contents: read` |\n"
        )
        self.assertEqual(kinds, [("header", None), ("row", "gone.yml")])

    def test_two_consecutive_separator_shaped_lines(self):
        # The second one is no longer immediately after the header, so it
        # must fail as malformed rather than being silently accepted as
        # furniture a second time.
        kinds = self._kinds(
            _HEADER
            + "| --- | --- | --- |\n"
        )
        self.assertEqual(kinds, [("header", None), ("separator", None), ("malformed", "| --- | --- | --- |")])

    def test_2_cell_and_4_cell_separators_are_malformed(self):
        for separator in ("| --- | --- |", "| --- | --- | --- | --- |"):
            with self.subTest(separator=separator):
                kinds = self._kinds(f"| Workflow | Purpose | Permissions |\n{separator}\n")
                self.assertEqual(kinds, [("header", None), ("malformed", separator)])

    def test_dashless_row_right_after_header_is_malformed(self):
        kinds = self._kinds(
            "| Workflow | Purpose | Permissions |\n"
            "| | | |\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        self.assertEqual(
            kinds,
            [("header", None), ("malformed", "| | | |"), ("row", "real.yml")],
        )

    def test_name_cell_without_its_own_closing_backtick(self):
        kinds = self._kinds(
            _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
            "| `sloppy.yml | Applies the canonical set from `other.yml` | `contents: read` |\n"
        )
        self.assertEqual(kinds[2], ("row", "real.yml"))
        self.assertEqual(kinds[3][0], "malformed")

    def test_plain_text_stale_row_with_no_backticks(self):
        kinds = self._kinds(
            _HEADER
            + "| gone.yml | Removed long ago | contents: read |\n"
        )
        self.assertEqual(kinds[2][0], "malformed")

    def test_row_with_multiple_backtick_quoted_permissions_segments(self):
        kinds = self._kinds(
            _HEADER
            + "| `real.yml` | Does the real thing | `contents: read`, `security-events: write` |\n"
        )
        self.assertEqual(kinds[2], ("row", "real.yml"))

    def test_name_cell_with_embedded_pipe_is_malformed(self):
        # The pipe splits the cell in two, well before the name's own
        # closing backtick is ever reached - the correct, structural
        # reason this fails, rather than a hand-tuned character class.
        kinds = self._kinds(
            _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
            "| `gone.yml | fake-suffix` | Purpose text | `contents: read` |\n"
        )
        self.assertEqual(kinds[3][0], "malformed")

    def test_no_trailing_column_pipe_is_malformed(self):
        # A row shaped like a bare, single-cell fragment (no second or
        # third column at all) does not have the table's fixed 3-column
        # shape, even though its one cell is itself backtick-clean.
        kinds = self._kinds(
            _HEADER
            + "| `truncated.yml`\n"
        )
        self.assertEqual(kinds[2][0], "malformed")

    def test_zero_spaces_before_the_column_pipe_is_well_formed(self):
        kinds = self._kinds(
            _HEADER
            + "| `real.yml`| Does the real thing | `contents: read` |\n"
        )
        self.assertEqual(kinds[2], ("row", "real.yml"))

    def test_a_row_in_a_different_table_is_never_reached(self):
        kinds = self._kinds(_TWO_TABLE_README)
        self.assertEqual(
            kinds,
            [("header", None), ("separator", None), ("row", "real.yml")],
        )

    def test_header_with_wrong_first_cell_never_opens_the_table(self):
        kinds = self._kinds("| NotWorkflow | Purpose | Permissions |\n| --- | --- | --- |\n")
        self.assertEqual(kinds, [])

    def test_header_with_wrong_second_cell_never_opens_the_table(self):
        kinds = self._kinds("| Workflow | NotPurpose | Permissions |\n| --- | --- | --- |\n")
        self.assertEqual(kinds, [])

    def test_header_with_a_fourth_cell_never_opens_the_table(self):
        kinds = self._kinds("| Workflow | Purpose | Permissions | Extra |\n| --- | --- | --- | --- |\n")
        self.assertEqual(kinds, [])

    def test_whitespace_only_line_ends_the_table_too(self):
        kinds = self._kinds(
            _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
            "   \n"
            "| `gone.yml` | Removed long ago | `contents: read` |\n"
        )
        self.assertEqual(
            kinds,
            [("header", None), ("separator", None), ("row", "real.yml")],
        )

    def test_four_cell_data_row_is_malformed(self):
        kinds = self._kinds(
            _HEADER
            + "| `real.yml` | x | y | extra |\n"
        )
        self.assertEqual(kinds[2][0], "malformed")

    def test_non_pipe_line_mid_table_is_malformed_not_a_crash(self):
        kinds = self._kinds(
            _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
            "not a pipe row at all\n"
        )
        self.assertEqual(kinds[-1], ("malformed", "not a pipe row at all"))

    def test_name_cell_with_a_leading_character_before_the_backtick_is_malformed(self):
        kinds = self._kinds(
            _HEADER
            + "| x`real.yml` | x | `c` |\n"
        )
        self.assertEqual(kinds[2][0], "malformed")

    def test_name_cell_with_a_trailing_character_after_the_backtick_is_malformed(self):
        kinds = self._kinds(
            _HEADER
            + "| `real.yml`x | x | `c` |\n"
        )
        self.assertEqual(kinds[2][0], "malformed")

    def test_name_cell_with_a_third_embedded_backtick_is_malformed(self):
        kinds = self._kinds(
            _HEADER
            + "| `re`al.yml` | x | `c` |\n"
        )
        self.assertEqual(kinds[2][0], "malformed")

    def test_separator_cell_with_trailing_garbage_is_not_recognised(self):
        kinds = self._kinds("| Workflow | Purpose | Permissions |\n| ---junk | --- | --- |\n")
        self.assertEqual(kinds[1][0], "malformed")

    def test_partially_separator_shaped_row_after_header_is_malformed(self):
        kinds = self._kinds(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | Not a real separator | `contents: read` |\n"
        )
        self.assertEqual(kinds[1][0], "malformed")

    def test_after_header_flag_resets_even_when_the_next_line_is_a_data_row(self):
        # after_header must reset unconditionally on the line right after
        # a header, not only when that line happens to be a separator -
        # otherwise a later dash-shaped line gets misclassified as
        # furniture instead of malformed.
        kinds = self._kinds(
            "| Workflow | Purpose | Permissions |\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
            "| --- | --- | --- |\n"
        )
        self.assertEqual(
            kinds,
            [("header", None), ("row", "real.yml"), ("malformed", "| --- | --- | --- |")],
        )

    def test_multibyte_utf8_content_is_parsed_correctly(self):
        kinds = self._kinds(
            _HEADER
            + "| `real.yml` | Uses an em dash — in its purpose text | `contents: read` |\n"
        )
        self.assertEqual(kinds, [("header", None), ("separator", None), ("row", "real.yml")])

    def test_decoy_header_in_an_indented_code_block_is_an_ambiguity_error(self):
        # Rounds 20-21 tried to tell a real header apart from one hidden
        # in an indented code block, a fenced code block, or an HTML
        # comment - one construct at a time, and every round found
        # another way to hide one (see readme_catalog_check.py's own
        # header comment). Round 22 stopped enumerating GFM constructs:
        # ANY second header-shaped line, wherever it is, is now an
        # ambiguity error - this is the representative case for an
        # indented decoy; the fenced and HTML-comment cases below are the
        # same mechanism, not separate code paths anymore.
        with self.assertRaises(ValueError):
            self._kinds(
                "    | Workflow | Purpose | Permissions |\n"
                "    | --- | --- | --- |\n"
                "    | `decoy.yml` | example only | `contents: read` |\n"
                "\n"
                + _HEADER
                + "| `real.yml` | Does the real thing | `contents: read` |\n"
            )

    def test_decoy_header_in_a_fenced_code_block_is_an_ambiguity_error(self):
        with self.assertRaises(ValueError):
            self._kinds(
                "```\n"
                + _HEADER
                + "| `decoy.yml` | example only | `contents: read` |\n"
                "```\n"
                "\n"
                + _HEADER
                + "| `real.yml` | Does the real thing | `contents: read` |\n"
            )

    def test_decoy_header_in_an_html_comment_is_an_ambiguity_error(self):
        with self.assertRaises(ValueError):
            self._kinds(
                "<!--\n"
                + _HEADER
                + "| `decoy.yml` | example only | `contents: read` |\n"
                "-->\n"
                "\n"
                + _HEADER
                + "| `real.yml` | Does the real thing | `contents: read` |\n"
            )


class CheckTest(_TempRepoTestCase):
    def test_fully_documented_catalog_passes(self):
        self._add_target("real.yml")
        self._write_readme(
            _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        self.assertEqual(self._check(), [])

    def test_undocumented_target_fails(self):
        self._add_target("real.yml")
        self._write_readme(_HEADER)
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("real.yml", errors[0])
        self.assertIn("is not listed", errors[0])

    def test_stale_row_for_removed_file_fails(self):
        self._write_readme(
            _HEADER
            + "| `gone.yml` | Removed long ago | `contents: read` |\n"
        )
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("gone.yml", errors[0])
        self.assertIn("is missing under", errors[0])

    def test_stale_row_for_de_reusabled_file_names_the_cause(self):
        self._add_target("gone.yml", workflow_call=False)
        self._write_readme(
            _HEADER
            + "| `gone.yml` | Removed long ago | `contents: read` |\n"
        )
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("declares no workflow_call", errors[0])

    def test_half_fixed_rename_reports_both_directions(self):
        self._add_target("new-name.yml")
        self._write_readme(
            _HEADER
            + "| `old-name.yml` | Row left behind by a rename | `contents: read` |\n"
        )
        errors = self._check()
        self.assertEqual(len(errors), 2)
        self.assertTrue(any("new-name.yml" in e and "is not listed" in e for e in errors))
        self.assertTrue(any("old-name.yml" in e and "is missing under" in e for e in errors))

    def test_empty_backtick_cell_fails_alongside_a_real_target(self):
        self._add_target("real.yml")
        self._write_readme(
            _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
            "| `` | Empty name | `contents: read` |\n"
        )
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("names no workflow", errors[0])

    def test_malformed_row_fails_alongside_a_real_target(self):
        self._add_target("real.yml")
        self._write_readme(
            _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
            "| malformed row with no backticks at all | text | here |\n"
        )
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("not a single backtick-quoted name", errors[0])

    def test_target_with_ere_metacharacters_in_its_name(self):
        # Plain string equality (`name in targets`), never a regex or a
        # shell glob built from the name - every ERE/glob metacharacter is
        # just an ordinary character to `==`/`in`, structurally closing the
        # entire bug class the bash predecessor fought (a target filename
        # interpolated into a live shell glob/regex pattern).
        for name in (
            "plus+name.yml",
            "star*name.yml",
            "quest?name.yml",
            "brack[1].yml",
            "paren(1).yml",
            "caret^name.yml",
            "dollar$name.yml",
            "brace{1}.yml",
            'quote".yml',
        ):
            with self.subTest(name=name):
                self._add_target(name)
                try:
                    self._write_readme(
                        _HEADER
                        + f"| `{name}` | Documented | `contents: read` |\n"
                    )
                    self.assertEqual(self._check(), [])
                finally:
                    os.remove(os.path.join(self.workflows_dir, name))

    def test_undocumented_bracket_named_target_is_not_masked_by_an_unrelated_row(self):
        # The bash predecessor's fail-open regression: an undocumented
        # target whose name contains a metacharacter must never be
        # silently matched by an unrelated row.
        self._add_target("brack[name.yml")
        self._add_target("brack.yml")
        self._write_readme(
            _HEADER
            + "| `brack.yml` | Documented | `contents: read` |\n"
        )
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("brack[name.yml", errors[0])
        self.assertIn("is not listed", errors[0])

    def test_target_name_as_substring_of_an_unrelated_row_does_not_satisfy_it(self):
        # Mirrors the bash predecessor's own leading-`^`-anchor necessity
        # test: a target must have its OWN row, not merely appear as a
        # substring inside a different row's other columns.
        self._add_target("real.yml")
        self._add_target("sneaky.yml")
        self._write_readme(
            _HEADER
            + "| `real.yml` | Consolidates `sneaky.yml` for legacy reasons | `contents: read` |\n"
        )
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("sneaky.yml", errors[0])
        self.assertIn("is not listed", errors[0])

    def test_a_row_in_a_different_table_is_not_reported_as_stale(self):
        self._add_target("real.yml")
        self._write_readme(_TWO_TABLE_README)
        self.assertEqual(self._check(), [])

    def test_forward_direction_sanitizes_a_target_filename_with_an_embedded_newline(self):
        name = "evil\n::error::forged.yml"
        self._add_target(name)
        self._write_readme(_HEADER)
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertNotIn("\n", errors[0])

    def test_reverse_direction_sanitizes_a_percent_encoded_control_sequence_in_a_stale_row_name(self):
        name = "gone%0D%0A::error::forged.yml"
        self._write_readme(
            _HEADER
            + f"| `{name}` | Stale row | `contents: read` |\n"
        )
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("%25", errors[0])
        self.assertIn("gone", errors[0])

    def test_non_utf8_readme_fails_closed_with_a_clear_message_instead_of_crashing(self):
        with open(self.readme_path, "wb") as handle:
            handle.write(
                b"| Workflow | Purpose | Permissions |\n"
                b"| --- | --- | --- |\n"
                b"| `real.yml` \xff | Does the real thing | `contents: read` |\n"
            )
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("could not be read", errors[0])

    def test_non_utf8_readme_with_targets_present_reports_only_the_read_failure(self):
        # With targets declared, a read failure must not ALSO cascade into
        # "target is not listed" for every one of them - the unreadable
        # file is the one actionable message.
        self._add_target("real.yml")
        with open(self.readme_path, "wb") as handle:
            handle.write(b"\xff")
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("could not be read", errors[0])

    def test_missing_readme_fails_closed_with_a_clear_message_instead_of_crashing(self):
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("could not be read", errors[0])

    def test_read_failure_message_is_sanitized(self):
        # A FileNotFoundError's str() already backslash-escapes an
        # embedded newline in its filename via repr() before _sanitize()
        # ever sees it, so that path cannot discriminate whether
        # _sanitize() is actually applied here. The symlink guard's own
        # OSError(f"{readme_path} is a symlink, ...") is a plain
        # f-string, NOT repr-escaped, so a hazardous README path combined
        # with a real symlink is the one input that actually exercises
        # this call site's sanitize() call (mutation-confirmed: removing
        # it makes exactly this case leak a raw newline).
        hazardous_readme_path = os.path.join(self.work_dir, "evil\n::error::forged.md")
        target_path = os.path.join(self.work_dir, "secret.txt")
        with open(target_path, "w", encoding="utf-8") as handle:
            handle.write("placeholder")
        os.symlink(target_path, hazardous_readme_path)

        errors = readme_catalog_check.check(self.workflows_dir, hazardous_readme_path)

        self.assertEqual(len(errors), 1)
        self.assertNotIn("\n", errors[0])

    def test_symlinked_readme_is_refused_not_followed(self):
        target_path = os.path.join(self.work_dir, "secret.txt")
        with open(target_path, "w", encoding="utf-8") as handle:
            handle.write(
                _HEADER
                + "| `leaked-name.yml` | leaked info | `contents: read` |\n"
            )
        os.symlink(target_path, self.readme_path)
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("could not be read", errors[0])
        self.assertNotIn("leaked-name.yml", errors[0])

    def test_pipe_in_a_target_name_is_the_documented_known_limitation(self):
        # Known limitation (issue #116): no workflow file in this
        # repository currently uses `|` in its name (re-derive:
        # `ls .github/workflows | grep -c '|'` should print 0), so this
        # row-splitting-in-two is an accepted, still-fail-closed residual,
        # not a live bug.
        self._add_target("a|b.yml")
        self._write_readme(
            _HEADER
            + "| `a|b.yml` | Has a literal pipe in its name | `contents: read` |\n"
        )
        errors = self._check()
        self.assertTrue(len(errors) >= 1)
        self.assertTrue(all("not a single backtick-quoted name" in e or "is not listed" in e for e in errors))

    def test_ambiguous_catalog_reports_one_clear_error_not_a_cascade(self):
        # Same early-return rationale as the read-failure case: with no
        # trustworthy row_names extracted, every declared target would
        # otherwise ALSO be reported as undocumented, burying the one
        # actionable message.
        self._add_target("real.yml")
        self._write_readme(
            _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
            "\n"
            + _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("2 lines that look like the workflow catalog header", errors[0])


class MainTest(_TempRepoTestCase):
    # main() prints its ::error:: annotations (and usage errors) straight
    # to real stdout/stderr - captured here so a red/expected-red run of
    # THESE tests doesn't spam the actual test runner's console with
    # annotation text that belongs to the fixture, not to the test result.
    def _run_main(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = readme_catalog_check.main(argv)
        return rc, out.getvalue(), err.getvalue()

    def test_returns_zero_for_a_complete_catalog(self):
        self._add_target("real.yml")
        self._write_readme(
            _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        rc, out, _ = self._run_main(["prog", self.workflows_dir, self.readme_path])
        self.assertEqual(rc, 0)
        self.assertEqual(out, "")

    def test_returns_one_and_prints_annotations_for_an_incomplete_catalog(self):
        self._add_target("real.yml")
        self._write_readme(_HEADER)
        rc, out, _ = self._run_main(["prog", self.workflows_dir, self.readme_path])
        self.assertEqual(rc, 1)
        self.assertIn("::error::real.yml", out)

    def test_non_utf8_workflow_filename_does_not_crash_the_annotation_print(self):
        # print(f"::error::{message}") encodes to the real stdout stream,
        # unlike _run_main()'s io.StringIO() redirect above (a text buffer
        # that never encodes at all) - reproducing the encode-boundary
        # crash needs the real encode step, so this test runs the script
        # as a subprocess rather than calling main() in-process.
        self._add_target("real.yml")
        forged_name = b"bad-\xffname.yml"
        path = os.path.join(os.fsencode(self.workflows_dir), forged_name)
        try:
            with open(path, "wb") as handle:
                handle.write(b"on:\n    workflow_call:\n")
        except OSError:
            self.skipTest("this filesystem rejects filenames containing this byte")
        self._write_readme(_HEADER)

        result = subprocess.run(
            [sys.executable, _MODULE_PATH, self.workflows_dir, self.readme_path],
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn(b"::error::", result.stdout)

    def test_usage_error_on_wrong_argc(self):
        rc, _, err = self._run_main(["prog", "onlyone"])
        self.assertEqual(rc, 2)
        self.assertIn("usage:", err)

    def test_ambiguous_catalog_prints_one_clear_annotation(self):
        self._write_readme(
            _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
            "\n"
            + _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        rc, out, _ = self._run_main(["prog", self.workflows_dir, self.readme_path])
        self.assertEqual(rc, 1)
        self.assertIn("::error::README.md contains 2 lines", out)


if __name__ == "__main__":
    unittest.main()
