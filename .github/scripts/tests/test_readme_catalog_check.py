#!/usr/bin/env python3
# Exercises readme_catalog_check.py - the structural replacement for
# readme-catalog-check.sh's bash/regex mechanism (issue #101, issue #116).
# Every fixture here pins a real defect or a documented design decision
# from that mechanism's review history, re-expressed against the
# cmarkgfm-rendering-based parser that replaced two prior hand-rolled
# tokenizer designs (see readme_catalog_check.py's own header comment for
# why), so the coverage this repo already paid for is not lost.
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


class ParseCatalogTableTest(_TempRepoTestCase):
    def _kinds(self, text):
        self._write_readme(text)
        return list(readme_catalog_check.parse_catalog_table(self.readme_path))

    def test_well_formed_table(self):
        kinds = self._kinds(
            _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        self.assertEqual(kinds, [("header", None), ("row", "real.yml")])

    def test_colon_alignment_separator_is_recognised(self):
        kinds = self._kinds(
            "| Workflow | Purpose | Permissions |\n"
            "|:---|:---:|---:|\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        self.assertEqual(kinds, [("header", None), ("row", "real.yml")])

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
        self.assertEqual(kinds, [("header", None), ("row", "real.yml")])

    def test_near_miss_header_prefix_is_not_a_header(self):
        # Shares "Workflow"/"Purpose" but the third cell does not start
        # with "Permissions" at all - a genuinely rendered table, but not
        # recognised as the catalog, so this counts as "no catalog found"
        # rather than opening on it.
        kinds = self._kinds("| Workflow | Purpose | Permission Level |\n| --- | --- | --- |\n")
        self.assertEqual(kinds, [])

    def test_a_row_in_a_different_table_is_never_reached(self):
        kinds = self._kinds(_TWO_TABLE_README)
        self.assertEqual(kinds, [("header", None), ("row", "real.yml")])

    def test_header_with_wrong_first_cell_is_not_a_catalog(self):
        kinds = self._kinds("| NotWorkflow | Purpose | Permissions |\n| --- | --- | --- |\n")
        self.assertEqual(kinds, [])

    def test_header_with_wrong_second_cell_is_not_a_catalog(self):
        kinds = self._kinds("| Workflow | NotPurpose | Permissions |\n| --- | --- | --- |\n")
        self.assertEqual(kinds, [])

    def test_missing_separator_row_is_not_a_table_at_all(self):
        # Without a GFM alignment row, cmark-gfm never recognises this as
        # a table at all (renders as a plain paragraph) - correctly "no
        # catalog found", matching what a human sees on the rendered
        # page. The old hand-rolled tokenizer used to tolerate this and
        # parse the row anyway, which was more lenient than real GFM
        # rendering, not a feature worth keeping.
        kinds = self._kinds(
            "| Workflow | Purpose | Permissions |\n"
            "| `gone.yml` | Removed long ago | `contents: read` |\n"
        )
        self.assertEqual(kinds, [])

    def test_2_cell_separator_is_not_a_table_at_all(self):
        # A delimiter row must have the same cell count as the header;
        # cmark-gfm does not recognise a mismatched one as a table.
        kinds = self._kinds("| Workflow | Purpose | Permissions |\n| --- | --- |\n")
        self.assertEqual(kinds, [])

    def test_4_cell_separator_is_not_a_table_at_all(self):
        kinds = self._kinds("| Workflow | Purpose | Permissions |\n| --- | --- | --- | --- |\n")
        self.assertEqual(kinds, [])

    def test_name_cell_without_its_own_closing_backtick_is_malformed(self):
        kinds = self._kinds(
            _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
            "| `sloppy.yml | Applies the canonical set from `other.yml` | `contents: read` |\n"
        )
        self.assertEqual(kinds, [("header", None), ("row", "real.yml"), ("malformed", None)])

    def test_plain_text_stale_row_with_no_backticks_is_malformed(self):
        kinds = self._kinds(_HEADER + "| gone.yml | Removed long ago | contents: read |\n")
        self.assertEqual(kinds, [("header", None), ("malformed", None)])

    def test_row_with_multiple_backtick_quoted_permissions_segments(self):
        kinds = self._kinds(
            _HEADER
            + "| `real.yml` | Does the real thing | `contents: read`, `security-events: write` |\n"
        )
        self.assertEqual(kinds, [("header", None), ("row", "real.yml")])

    def test_name_cell_with_embedded_pipe_is_malformed(self):
        # No backslash-escaping is written for the pipe, so cmark-gfm
        # splits the cell in two - one more column than the 3-column
        # header has, so GFM's own "extra cells are ignored" rule drops
        # the last one, leaving a name cell that is not a single code
        # span either way.
        kinds = self._kinds(
            _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
            "| `gone.yml | fake-suffix` | Purpose text | `contents: read` |\n"
        )
        self.assertEqual(kinds, [("header", None), ("row", "real.yml"), ("malformed", None)])

    def test_zero_spaces_before_the_column_pipe_is_well_formed(self):
        kinds = self._kinds(_HEADER + "| `real.yml`| Does the real thing | `contents: read` |\n")
        self.assertEqual(kinds, [("header", None), ("row", "real.yml")])

    def test_indented_decoy_is_rendered_as_code_not_a_table(self):
        # cmark-gfm gives an indented code block precedence over table
        # recognition the same way GitHub's real renderer does - the
        # decoy never becomes a `<table>` element at all, so it needs no
        # special-casing here; only the genuine table is ever extracted.
        kinds = self._kinds(
            "    | Workflow | Purpose | Permissions |\n"
            "    | --- | --- | --- |\n"
            "    | `decoy.yml` | example only | `contents: read` |\n"
            "\n"
            + _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        self.assertEqual(kinds, [("header", None), ("row", "real.yml")])

    def test_fenced_decoy_is_rendered_as_code_not_a_table(self):
        kinds = self._kinds(
            "```\n"
            + _HEADER
            + "| `decoy.yml` | example only | `contents: read` |\n"
            "```\n"
            "\n"
            + _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        self.assertEqual(kinds, [("header", None), ("row", "real.yml")])

    def test_html_comment_decoy_is_omitted_from_rendered_output_entirely(self):
        # cmark-gfm's safe rendering mode omits raw HTML block content -
        # comments included - from the output entirely (verified live,
        # 2026-09-07: the rendered HTML contains no trace of the comment's
        # text at all, not even literally), so a decoy hidden inside one
        # never produces a `<table>` element to find in the first place.
        kinds = self._kinds(
            "<!--\n"
            + _HEADER
            + "| `decoy.yml` | example only | `contents: read` |\n"
            "-->\n"
            "\n"
            + _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
        )
        self.assertEqual(kinds, [("header", None), ("row", "real.yml")])

    def test_entire_catalog_hidden_in_an_html_comment_is_not_documented(self):
        # The mirror case: if the ONLY catalog-shaped table in the file
        # is inside a comment, it renders as nothing at all - correctly
        # "no catalog found" (every declared target reported
        # undocumented by check()), matching what a human reviewer
        # actually sees on the page. A prior "ambiguity-only" design
        # (round 22) missed this: with no SECOND header-shaped line
        # anywhere, its uniqueness check never fired, and the hidden
        # table was silently trusted as real (round 23 finding).
        kinds = self._kinds(
            "<!--\n"
            + _HEADER
            + "| `real.yml` | hidden | `contents: read` |\n"
            "-->\n"
        )
        self.assertEqual(kinds, [])

    def test_indented_row_under_a_real_header_never_joins_the_table(self):
        # GFM table rows must be contiguous, non-indented lines
        # immediately following the header/separator - an indented line
        # breaks the table there, so cmark-gfm renders the header alone
        # (empty body) and the "row" separately as a code block. The
        # round-23 codex:codex-rescue finding that broke the old
        # ambiguity-only design (a hidden row under one genuine,
        # unambiguous header) cannot occur here: the row simply never
        # becomes part of the table's body.
        kinds = self._kinds(
            _HEADER
            + "    | `real.yml` | Shown as indented code, not a table row | `contents: read` |\n"
        )
        self.assertEqual(kinds, [("header", None)])

    def test_two_genuinely_rendered_catalog_tables_is_an_ambiguity_error(self):
        # The one case that still needs a hard error: two fully visible,
        # independently rendered tables both matching the catalog header
        # - a real ambiguity a human has to resolve, not something
        # cmark-gfm's rendering alone can disambiguate.
        with self.assertRaises(ValueError) as ctx:
            self._kinds(
                _HEADER
                + "| `real.yml` | Does the real thing | `contents: read` |\n"
                "\n"
                + _HEADER
                + "| `real.yml` | Does the real thing | `contents: read` |\n"
            )
        self.assertIn("2 tables that look like the workflow catalog", str(ctx.exception))

    def test_disguised_real_header_with_a_hidden_comment_decoy_is_not_documented(self):
        # A zero-width space in the real, visible header's text (renders
        # pixel-identical to "Workflow" in any browser) makes this
        # checker's exact-text match fail to recognise it, while a
        # byte-exact decoy hidden in a comment vanishes entirely from the
        # rendered output (see the comment-omission test above) rather
        # than being promoted to "the" catalog - fails closed (nothing
        # recognised as the catalog) rather than trusting the hidden
        # decoy, unlike the round-23 security-lane finding against the
        # ambiguity-only design, where exactly this input made the hidden
        # decoy the sole, silently-trusted "catalog".
        kinds = self._kinds(
            "<!--\n"
            + _HEADER
            + "| `evil.yml` | hidden | `contents: read` |\n"
            "-->\n\n"
            "| Work​flow | Purpose | Permissions |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | visible | `contents: read` |\n"
        )
        self.assertEqual(kinds, [])

    def test_details_wrapped_table_is_still_a_real_table(self):
        # A collapsible <details> section is a common, legitimate GitHub
        # README pattern - the table inside it is still discoverable by
        # a human (one click to expand), not hidden the way a comment or
        # code block is, and cmark-gfm renders it as a genuine <table>
        # (only the <details>/<summary> tags themselves are the omitted
        # raw HTML) - so it must count as a real catalog, not be treated
        # like the opaque constructs above.
        kinds = self._kinds(
            "<details>\n<summary>Click to expand</summary>\n\n"
            + _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n\n"
            "</details>\n"
        )
        self.assertEqual(kinds, [("header", None), ("row", "real.yml")])


class CheckTest(_TempRepoTestCase):
    def test_fully_documented_catalog_passes(self):
        self._add_target("real.yml")
        self._write_readme(_HEADER + "| `real.yml` | Does the real thing | `contents: read` |\n")
        self.assertEqual(self._check(), [])

    def test_undocumented_target_fails(self):
        self._add_target("real.yml")
        self._write_readme(_HEADER)
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("real.yml", errors[0])
        self.assertIn("is not listed", errors[0])

    def test_stale_row_for_removed_file_fails(self):
        self._write_readme(_HEADER + "| `gone.yml` | Removed long ago | `contents: read` |\n")
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("gone.yml", errors[0])
        self.assertIn("is missing under", errors[0])

    def test_stale_row_for_de_reusabled_file_names_the_cause(self):
        self._add_target("gone.yml", workflow_call=False)
        self._write_readme(_HEADER + "| `gone.yml` | Removed long ago | `contents: read` |\n")
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("declares no workflow_call", errors[0])

    def test_half_fixed_rename_reports_both_directions(self):
        self._add_target("new-name.yml")
        self._write_readme(_HEADER + "| `old-name.yml` | Row left behind by a rename | `contents: read` |\n")
        errors = self._check()
        self.assertEqual(len(errors), 2)
        self.assertTrue(any("new-name.yml" in e and "is not listed" in e for e in errors))
        self.assertTrue(any("old-name.yml" in e and "is missing under" in e for e in errors))

    def test_empty_backtick_pair_is_malformed_not_a_named_row(self):
        # `` `` `` renders as literal double-backtick text, not an empty
        # code span (CommonMark's own code-span rule never produces an
        # empty <code> element) - so this falls into the generic
        # malformed-row path, not a dedicated "empty name" case.
        self._add_target("real.yml")
        self._write_readme(
            _HEADER
            + "| `real.yml` | Does the real thing | `contents: read` |\n"
            "| `` | Empty name | `contents: read` |\n"
        )
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("not a single backtick-quoted name", errors[0])

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
                    self._write_readme(_HEADER + f"| `{name}` | Documented | `contents: read` |\n")
                    self.assertEqual(self._check(), [])
                finally:
                    os.remove(os.path.join(self.workflows_dir, name))

    def test_undocumented_bracket_named_target_is_not_masked_by_an_unrelated_row(self):
        # The bash predecessor's fail-open regression: an undocumented
        # target whose name contains a metacharacter must never be
        # silently matched by an unrelated row.
        self._add_target("brack[name.yml")
        self._add_target("brack.yml")
        self._write_readme(_HEADER + "| `brack.yml` | Documented | `contents: read` |\n")
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
            _HEADER + "| `real.yml` | Consolidates `sneaky.yml` for legacy reasons | `contents: read` |\n"
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
        self._write_readme(_HEADER + f"| `{name}` | Stale row | `contents: read` |\n")
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
            handle.write(_HEADER + "| `leaked-name.yml` | leaked info | `contents: read` |\n")
        os.symlink(target_path, self.readme_path)
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("could not be read", errors[0])
        self.assertNotIn("leaked-name.yml", errors[0])

    def test_pipe_in_a_target_name_is_the_documented_known_limitation(self):
        # Known limitation (issue #116): no workflow file in this
        # repository currently uses `|` in its name (re-derive:
        # `ls .github/workflows | grep -c '|'` should print 0). GFM
        # itself has no way to escape a literal pipe without breaking a
        # cell in two, so a name containing one still fails closed via
        # the malformed-row path, just with a generic diagnosis.
        self._add_target("a|b.yml")
        self._write_readme(_HEADER + "| `a|b.yml` | Has a literal pipe in its name | `contents: read` |\n")
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
        self.assertIn("2 tables that look like the workflow catalog", errors[0])


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
        self._write_readme(_HEADER + "| `real.yml` | Does the real thing | `contents: read` |\n")
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
        self.assertIn("::error::README.md renders 2 tables", out)


if __name__ == "__main__":
    unittest.main()
