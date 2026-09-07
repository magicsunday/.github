#!/usr/bin/env python3
# Exercises readme_catalog_check.py - the structural replacement for
# readme-catalog-check.sh's bash/regex mechanism (issue #101, issue #116).
# Every fixture here pins a real defect or a documented design decision
# from that mechanism's 17-round review history, re-expressed against the
# tokenizer that replaced it, so the coverage this repo already paid for
# is not lost in the rewrite.
import contextlib
import importlib.util
import io
import os
import tempfile
import unittest

_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "lib", "readme_catalog_check.py"
)
_spec = importlib.util.spec_from_file_location("readme_catalog_check", _MODULE_PATH)
assert _spec is not None and _spec.loader is not None
readme_catalog_check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(readme_catalog_check)


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


class ParseCatalogTableTest(_TempRepoTestCase):
    def _kinds(self, text):
        self._write_readme(text)
        return list(readme_catalog_check.parse_catalog_table(self.readme_path))

    def test_well_formed_table(self):
        kinds = self._kinds(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
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
        # This repo's own README.md header reads "...Permissions the
        # caller must grant |", not the bare "...Permissions |" every
        # other fixture in this file uses.
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
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `gone.yml` | Removed long ago | `contents: read` |\n"
        )
        # The decoy line never opens the table at all (started stays
        # False until the REAL header is seen), so only the real table's
        # three lines are yielded.
        self.assertEqual(
            kinds,
            [("header", None), ("separator", None), ("row", "gone.yml")],
        )

    def test_table_ends_at_first_blank_line_for_good(self):
        # A second, later occurrence of the real header text (e.g. two
        # catalog-shaped tables separated by a blank line) must never
        # reopen the table - there is exactly one catalog table.
        kinds = self._kinds(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
            "\n"
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        self.assertEqual(
            kinds,
            [("header", None), ("separator", None), ("row", "real.yml")],
        )

    def test_header_text_substring_in_prose_before_the_table_is_excluded(self):
        kinds = self._kinds(
            "See the catalog below (a decoy: | Workflow | Purpose | Permissions | "
            "is not a real header here).\n"
            "\n"
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        self.assertEqual(
            kinds,
            [("header", None), ("separator", None), ("row", "real.yml")],
        )

    def test_duplicated_header_line_inside_the_table_body(self):
        kinds = self._kinds(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
            "| Workflow | Purpose | Permissions |\n"
            "| `gone.yml` | Removed long ago | `contents: read` |\n"
        )
        self.assertEqual(
            kinds,
            [
                ("header", None),
                ("separator", None),
                ("row", "real.yml"),
                ("header", None),
                ("row", "gone.yml"),
            ],
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
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| --- | --- | --- |\n"
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
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
            "| `sloppy.yml | Applies the canonical set from `other.yml` | `contents: read` |\n"
        )
        self.assertEqual(kinds[2], ("row", "real.yml"))
        self.assertEqual(kinds[3][0], "malformed")

    def test_plain_text_stale_row_with_no_backticks(self):
        kinds = self._kinds(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| gone.yml | Removed long ago | contents: read |\n"
        )
        self.assertEqual(kinds[2][0], "malformed")

    def test_row_with_multiple_backtick_quoted_permissions_segments(self):
        kinds = self._kinds(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Does the real thing | `contents: read`, `security-events: write` |\n"
        )
        self.assertEqual(kinds[2], ("row", "real.yml"))

    def test_name_cell_with_embedded_pipe_is_malformed(self):
        # The pipe splits the cell in two, well before the name's own
        # closing backtick is ever reached - the correct, structural
        # reason this fails, rather than a hand-tuned character class.
        kinds = self._kinds(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
            "| `gone.yml | fake-suffix` | Purpose text | `contents: read` |\n"
        )
        self.assertEqual(kinds[3][0], "malformed")

    def test_no_trailing_column_pipe_is_malformed(self):
        # A row shaped like a bare, single-cell fragment (no second or
        # third column at all) does not have the table's fixed 3-column
        # shape, even though its one cell is itself backtick-clean.
        kinds = self._kinds(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `truncated.yml`\n"
        )
        self.assertEqual(kinds[2][0], "malformed")

    def test_zero_spaces_before_the_column_pipe_is_well_formed(self):
        kinds = self._kinds(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `real.yml`| Does the real thing | `contents: read` |\n"
        )
        self.assertEqual(kinds[2], ("row", "real.yml"))

    def test_a_row_in_a_different_table_is_never_reached(self):
        kinds = self._kinds(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
            "\n"
            "### Inputs\n"
            "\n"
            "| Workflow | Input | Default |\n"
            "| --- | --- | --- |\n"
            "| `gone.yml` | `some-input` | `false` |\n"
        )
        self.assertEqual(
            kinds,
            [("header", None), ("separator", None), ("row", "real.yml")],
        )


class CheckTest(_TempRepoTestCase):
    def test_fully_documented_catalog_passes(self):
        self._add_target("real.yml")
        self._write_readme(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        self.assertEqual(self._check(), [])

    def test_undocumented_target_fails(self):
        self._add_target("real.yml")
        self._write_readme("| Workflow | Purpose | Permissions |\n| --- | --- | --- |\n")
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("real.yml", errors[0])
        self.assertIn("is not listed", errors[0])

    def test_stale_row_for_removed_file_fails(self):
        self._write_readme(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `gone.yml` | Removed long ago | `contents: read` |\n"
        )
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("gone.yml", errors[0])
        self.assertIn("is missing under", errors[0])

    def test_stale_row_for_de_reusabled_file_names_the_cause(self):
        self._add_target("gone.yml", workflow_call=False)
        self._write_readme(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `gone.yml` | Removed long ago | `contents: read` |\n"
        )
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("declares no workflow_call", errors[0])

    def test_half_fixed_rename_reports_both_directions(self):
        self._add_target("new-name.yml")
        self._write_readme(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `old-name.yml` | Row left behind by a rename | `contents: read` |\n"
        )
        errors = self._check()
        self.assertEqual(len(errors), 2)
        self.assertTrue(any("new-name.yml" in e and "is not listed" in e for e in errors))
        self.assertTrue(any("old-name.yml" in e and "is missing under" in e for e in errors))

    def test_empty_backtick_cell_fails_alongside_a_real_target(self):
        self._add_target("real.yml")
        self._write_readme(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
            "| `` | Empty name | `contents: read` |\n"
        )
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("names no workflow", errors[0])

    def test_malformed_row_fails_alongside_a_real_target(self):
        self._add_target("real.yml")
        self._write_readme(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
            "| malformed row with no backticks at all | text | here |\n"
        )
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("not a single backtick-quoted name", errors[0])

    def test_target_with_ere_metacharacters_in_its_name(self):
        # Plain string equality (`name in targets`), never a regex or a
        # shell glob built from the name - every ERE/glob metacharacter is
        # just an ordinary character to `==`/`in`, structurally closing the
        # entire bug class rounds 15-17 fought in the bash predecessor.
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
                        "| Workflow | Purpose | Permissions |\n"
                        "| --- | --- | --- |\n"
                        f"| `{name}` | Documented | `contents: read` |\n"
                    )
                    self.assertEqual(self._check(), [])
                finally:
                    os.remove(os.path.join(self.workflows_dir, name))

    def test_undocumented_bracket_named_target_is_not_masked_by_an_unrelated_row(self):
        # The exact round-16 fail-open regression: an undocumented target
        # whose name contains a metacharacter must never be silently
        # matched by an unrelated row.
        self._add_target("brack[name.yml")
        self._add_target("brack.yml")
        self._write_readme(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `brack.yml` | Documented | `contents: read` |\n"
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
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Consolidates `sneaky.yml` for legacy reasons | `contents: read` |\n"
        )
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("sneaky.yml", errors[0])
        self.assertIn("is not listed", errors[0])

    def test_a_row_in_a_different_table_is_not_reported_as_stale(self):
        self._add_target("real.yml")
        self._write_readme(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
            "\n"
            "### Inputs\n"
            "\n"
            "| Workflow | Input | Default |\n"
            "| --- | --- | --- |\n"
            "| `gone.yml` | `some-input` | `false` |\n"
        )
        self.assertEqual(self._check(), [])

    def test_pipe_in_a_target_name_is_the_documented_known_limitation(self):
        # Known limitation (issue #116), unchanged from the bash
        # predecessor: a workflow filename cannot contain `|` in GitHub
        # Actions practice, so this row-splitting-in-two is an accepted,
        # still-fail-closed residual, not a live bug.
        self._add_target("a|b.yml")
        self._write_readme(
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `a|b.yml` | Has a literal pipe in its name | `contents: read` |\n"
        )
        errors = self._check()
        self.assertTrue(len(errors) >= 1)
        self.assertTrue(all("not a single backtick-quoted name" in e or "is not listed" in e for e in errors))


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
            "| Workflow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        rc, out, _ = self._run_main(["prog", self.workflows_dir, self.readme_path])
        self.assertEqual(rc, 0)
        self.assertEqual(out, "")

    def test_returns_one_and_prints_annotations_for_an_incomplete_catalog(self):
        self._add_target("real.yml")
        self._write_readme("| Workflow | Purpose | Permissions |\n| --- | --- | --- |\n")
        rc, out, _ = self._run_main(["prog", self.workflows_dir, self.readme_path])
        self.assertEqual(rc, 1)
        self.assertIn("::error::real.yml", out)

    def test_usage_error_on_wrong_argc(self):
        rc, _, err = self._run_main(["prog", "onlyone"])
        self.assertEqual(rc, 2)
        self.assertIn("usage:", err)


if __name__ == "__main__":
    unittest.main()
