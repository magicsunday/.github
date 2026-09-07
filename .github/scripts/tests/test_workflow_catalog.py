#!/usr/bin/env python3
# Exercises workflow_catalog.py - the generated-artefact replacement for
# readme_catalog_check.py's rendered-HTML table extraction (issue #101,
# issue #116). Unlike its predecessor, this module never parses README.md's
# markdown/HTML - the freshness check is a plain string comparison against
# render_table()'s own output, so there is no decoy/nesting/homoglyph
# construct to pin fixtures against here; the fixtures instead cover the
# JSON schema's failure modes and the freshness comparison's edge cases.
import contextlib
import importlib.util
import io
import json
import os
import tempfile
import unittest

_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "lib", "workflow_catalog.py"
)
_spec = importlib.util.spec_from_file_location("workflow_catalog", _MODULE_PATH)
assert _spec is not None and _spec.loader is not None
workflow_catalog = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(workflow_catalog)

_ONE_ENTRY_CATALOG = {"real.yml": {"purpose": "Does the real thing", "permissions": ["contents: read"]}}


class _TempRepoTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.work_dir = self._tmp.name
        self.workflows_dir = os.path.join(self.work_dir, "workflows")
        os.makedirs(self.workflows_dir)
        self.readme_path = os.path.join(self.work_dir, "README.md")
        self.catalog_path = os.path.join(self.work_dir, "workflow-catalog.json")

    def _add_target(self, name, workflow_call=True):
        with open(os.path.join(self.workflows_dir, name), "w", encoding="utf-8") as handle:
            handle.write("on:\n    workflow_call:\n" if workflow_call else "on:\n    push:\n")

    def _write_catalog(self, catalog):
        with open(self.catalog_path, "w", encoding="utf-8") as handle:
            json.dump(catalog, handle)

    def _write_readme(self, text):
        with open(self.readme_path, "w", encoding="utf-8") as handle:
            handle.write(text)

    def _write_fresh_readme(self, catalog):
        self._write_readme(
            "# Title\n\n"
            "<!-- workflow-catalog:start -->\n"
            + workflow_catalog.render_table(catalog)
            + "\n<!-- workflow-catalog:end -->\n\nTrailing prose.\n"
        )

    def _check(self):
        return workflow_catalog.check(self.workflows_dir, self.readme_path, self.catalog_path)


class LoadCatalogTest(_TempRepoTestCase):
    def test_well_formed_catalog_loads(self):
        self._write_catalog(_ONE_ENTRY_CATALOG)
        self.assertEqual(workflow_catalog.load_catalog(self.catalog_path), _ONE_ENTRY_CATALOG)

    def test_order_is_preserved(self):
        catalog = {
            "b.yml": {"purpose": "B", "permissions": ["contents: read"]},
            "a.yml": {"purpose": "A", "permissions": ["contents: read"]},
        }
        self._write_catalog(catalog)
        self.assertEqual(list(workflow_catalog.load_catalog(self.catalog_path)), ["b.yml", "a.yml"])

    def test_top_level_must_be_an_object(self):
        self._write_catalog(["not", "an", "object"])
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_entry_missing_permissions_key_is_rejected(self):
        self._write_catalog({"real.yml": {"purpose": "x"}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_entry_with_an_extra_key_is_rejected(self):
        self._write_catalog({"real.yml": {"purpose": "x", "permissions": ["contents: read"], "extra": 1}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_empty_purpose_is_rejected(self):
        self._write_catalog({"real.yml": {"purpose": "", "permissions": ["contents: read"]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_non_string_purpose_is_rejected(self):
        self._write_catalog({"real.yml": {"purpose": 123, "permissions": ["contents: read"]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_permissions_must_be_a_list_not_a_bare_string(self):
        # A bare string is iterable character-by-character - exactly the
        # trap a `permissions: "contents: read"` typo would fall into
        # without this check.
        self._write_catalog({"real.yml": {"purpose": "x", "permissions": "contents: read"}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_empty_permissions_list_is_rejected(self):
        self._write_catalog({"real.yml": {"purpose": "x", "permissions": []}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_empty_string_permission_entry_is_rejected(self):
        self._write_catalog({"real.yml": {"purpose": "x", "permissions": ["contents: read", ""]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_malformed_json_raises(self):
        self._write_readme("")  # unrelated, just to have the dir populated
        with open(self.catalog_path, "w", encoding="utf-8") as handle:
            handle.write("{not json")
        with self.assertRaises(json.JSONDecodeError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_missing_file_raises(self):
        with self.assertRaises(OSError):
            workflow_catalog.load_catalog(self.catalog_path)


class RenderTableTest(unittest.TestCase):
    def test_single_entry(self):
        table = workflow_catalog.render_table(_ONE_ENTRY_CATALOG)
        self.assertEqual(
            table,
            "| Workflow | Purpose | Permissions the caller must grant |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Does the real thing | `contents: read` |\n",
        )

    def test_multiple_permissions_are_each_backtick_quoted_and_comma_joined(self):
        catalog = {"real.yml": {"purpose": "x", "permissions": ["contents: read", "issues: write"]}}
        table = workflow_catalog.render_table(catalog)
        self.assertIn("| `contents: read`, `issues: write` |", table)

    def test_row_order_follows_catalog_order(self):
        catalog = {
            "b.yml": {"purpose": "B", "permissions": ["contents: read"]},
            "a.yml": {"purpose": "A", "permissions": ["contents: read"]},
        }
        table = workflow_catalog.render_table(catalog)
        self.assertLess(table.index("b.yml"), table.index("a.yml"))

    def test_purpose_text_with_backticks_and_em_dash_passes_through_unmodified(self):
        catalog = {
            "real.yml": {
                "purpose": "Uses `make lang` — see below",
                "permissions": ["contents: read"],
            }
        }
        table = workflow_catalog.render_table(catalog)
        self.assertIn("Uses `make lang` — see below", table)


class CheckFreshnessTest(_TempRepoTestCase):
    def test_matching_content_has_no_errors(self):
        self._write_fresh_readme(_ONE_ENTRY_CATALOG)
        self.assertEqual(workflow_catalog.check_freshness(self.readme_path, _ONE_ENTRY_CATALOG), [])

    def test_missing_begin_marker_is_reported(self):
        self._write_readme("no markers here\n<!-- workflow-catalog:end -->\n")
        errors = workflow_catalog.check_freshness(self.readme_path, _ONE_ENTRY_CATALOG)
        self.assertEqual(len(errors), 1)
        self.assertIn("markers", errors[0])

    def test_missing_end_marker_is_reported(self):
        self._write_readme("<!-- workflow-catalog:start -->\nno end marker\n")
        errors = workflow_catalog.check_freshness(self.readme_path, _ONE_ENTRY_CATALOG)
        self.assertEqual(len(errors), 1)
        self.assertIn("markers", errors[0])

    def test_end_marker_before_begin_marker_is_treated_as_missing(self):
        self._write_readme("<!-- workflow-catalog:end -->\n...\n<!-- workflow-catalog:start -->\n")
        errors = workflow_catalog.check_freshness(self.readme_path, _ONE_ENTRY_CATALOG)
        self.assertEqual(len(errors), 1)
        self.assertIn("markers", errors[0])

    def test_stale_table_is_reported_with_the_regen_command(self):
        self._write_fresh_readme(_ONE_ENTRY_CATALOG)
        stale_catalog = {
            "real.yml": {"purpose": "Does the real thing", "permissions": ["contents: read"]},
            "extra.yml": {"purpose": "New", "permissions": ["contents: read"]},
        }
        errors = workflow_catalog.check_freshness(self.readme_path, stale_catalog)
        self.assertEqual(len(errors), 1)
        self.assertIn("workflow_catalog.py --write", errors[0])

    def test_a_single_extra_trailing_space_is_flagged(self):
        # The comparison is byte-exact, not whitespace-tolerant - a manual
        # hand-edit of the generated block (rather than running --write)
        # must still be caught.
        self._write_readme(
            "<!-- workflow-catalog:start -->\n" + workflow_catalog.render_table(_ONE_ENTRY_CATALOG) + " \n"
            "<!-- workflow-catalog:end -->\n"
        )
        errors = workflow_catalog.check_freshness(self.readme_path, _ONE_ENTRY_CATALOG)
        self.assertEqual(len(errors), 1)


class WriteGeneratedBlockTest(_TempRepoTestCase):
    def test_regenerates_the_block_in_place(self):
        self._write_readme(
            "Intro.\n\n<!-- workflow-catalog:start -->\nstale content\n<!-- workflow-catalog:end -->\n\nOutro.\n"
        )
        workflow_catalog.write_generated_block(self.readme_path, _ONE_ENTRY_CATALOG)
        self.assertEqual(workflow_catalog.check_freshness(self.readme_path, _ONE_ENTRY_CATALOG), [])

    def test_content_outside_the_markers_is_untouched(self):
        self._write_readme(
            "Intro paragraph.\n\n<!-- workflow-catalog:start -->\nstale\n<!-- workflow-catalog:end -->\n\n"
            "Outro paragraph.\n"
        )
        workflow_catalog.write_generated_block(self.readme_path, _ONE_ENTRY_CATALOG)
        with open(self.readme_path, encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn("Intro paragraph.", text)
        self.assertIn("Outro paragraph.", text)

    def test_missing_markers_raises_instead_of_silently_appending(self):
        self._write_readme("No markers at all.\n")
        with self.assertRaises(ValueError):
            workflow_catalog.write_generated_block(self.readme_path, _ONE_ENTRY_CATALOG)


class CheckTest(_TempRepoTestCase):
    def test_fully_documented_and_fresh_catalog_passes(self):
        self._add_target("real.yml")
        self._write_catalog(_ONE_ENTRY_CATALOG)
        self._write_fresh_readme(_ONE_ENTRY_CATALOG)
        self.assertEqual(self._check(), [])

    def test_undocumented_target_fails(self):
        self._add_target("real.yml")
        self._write_catalog({})
        self._write_fresh_readme({})
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("real.yml", errors[0])
        self.assertIn("issue #101", errors[0])

    def test_stale_entry_for_removed_file_fails(self):
        self._write_catalog(_ONE_ENTRY_CATALOG)
        self._write_fresh_readme(_ONE_ENTRY_CATALOG)
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("is missing", errors[0])

    def test_stale_entry_for_de_reusabled_file_names_the_cause(self):
        self._add_target("real.yml", workflow_call=False)
        self._write_catalog(_ONE_ENTRY_CATALOG)
        self._write_fresh_readme(_ONE_ENTRY_CATALOG)
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("declares no workflow_call", errors[0])

    def test_malformed_catalog_reports_one_message_not_a_cascade(self):
        self._add_target("real.yml")
        with open(self.catalog_path, "w", encoding="utf-8") as handle:
            handle.write("{not json")
        self._write_readme("<!-- workflow-catalog:start -->\n<!-- workflow-catalog:end -->\n")
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("could not be read", errors[0])

    def test_missing_catalog_file_reports_one_message(self):
        self._add_target("real.yml")
        self._write_readme("<!-- workflow-catalog:start -->\n<!-- workflow-catalog:end -->\n")
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("could not be read", errors[0])

    def test_catalog_and_targets_agree_but_readme_is_stale(self):
        self._add_target("real.yml")
        self._write_catalog(_ONE_ENTRY_CATALOG)
        self._write_readme("<!-- workflow-catalog:start -->\nstale\n<!-- workflow-catalog:end -->\n")
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("does not match", errors[0])

    def test_forward_direction_sanitizes_a_target_filename_with_an_embedded_newline(self):
        self._add_target("real\r\x0a.yml")
        self._write_catalog({})
        self._write_fresh_readme({})
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertNotIn("\n", errors[0])

    def test_reverse_direction_sanitizes_a_percent_sign_in_a_stale_entry_name(self):
        self._write_catalog({"100%.yml": {"purpose": "x", "permissions": ["contents: read"]}})
        self._write_fresh_readme({"100%.yml": {"purpose": "x", "permissions": ["contents: read"]}})
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("100%25.yml", errors[0])


class MainTest(_TempRepoTestCase):
    def _run_main(self, argv):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            code = workflow_catalog.main(["workflow_catalog.py"] + argv)
        return code, stdout.getvalue()

    def test_usage_error_on_wrong_argc(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = workflow_catalog.main(["workflow_catalog.py", "only-one-arg"])
        self.assertEqual(code, 2)
        self.assertIn("usage:", stderr.getvalue())

    def test_returns_zero_for_a_complete_and_fresh_catalog(self):
        self._add_target("real.yml")
        self._write_catalog(_ONE_ENTRY_CATALOG)
        self._write_fresh_readme(_ONE_ENTRY_CATALOG)
        code, out = self._run_main([self.workflows_dir, self.readme_path, self.catalog_path])
        self.assertEqual(code, 0)
        self.assertEqual(out, "")

    def test_returns_one_and_prints_an_annotation_for_an_incomplete_catalog(self):
        self._add_target("real.yml")
        self._write_catalog({})
        self._write_fresh_readme({})
        code, out = self._run_main([self.workflows_dir, self.readme_path, self.catalog_path])
        self.assertEqual(code, 1)
        self.assertIn("::error::", out)

    def test_write_mode_regenerates_and_returns_zero(self):
        self._write_readme("<!-- workflow-catalog:start -->\nstale\n<!-- workflow-catalog:end -->\n")
        self._write_catalog(_ONE_ENTRY_CATALOG)
        code, _ = self._run_main(["--write", self.readme_path, self.catalog_path])
        self.assertEqual(code, 0)
        self.assertEqual(workflow_catalog.check_freshness(self.readme_path, _ONE_ENTRY_CATALOG), [])

    def test_write_mode_reports_missing_markers_on_stderr_and_returns_one(self):
        self._write_readme("no markers\n")
        self._write_catalog(_ONE_ENTRY_CATALOG)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = workflow_catalog.main(["workflow_catalog.py", "--write", self.readme_path, self.catalog_path])
        self.assertEqual(code, 1)
        self.assertIn("markers", stderr.getvalue())

    def test_non_utf8_workflow_filename_does_not_crash_the_annotation_print(self):
        # Mirrors readme_catalog_check.py's identical regression test: a
        # workflow filename decoded from raw POSIX bytes via glob()'s
        # surrogateescape can carry a lone surrogate codepoint into an
        # ::error:: annotation.
        bad_name = os.fsencode("real-\udcff.yml")
        with open(os.path.join(self.workflows_dir, os.fsdecode(bad_name)), "w", encoding="utf-8", errors="surrogateescape") as handle:
            handle.write("on:\n    workflow_call:\n")
        self._write_catalog({})
        self._write_fresh_readme({})
        code, out = self._run_main([self.workflows_dir, self.readme_path, self.catalog_path])
        self.assertEqual(code, 1)
        self.assertIn("::error::", out)


if __name__ == "__main__":
    unittest.main()
