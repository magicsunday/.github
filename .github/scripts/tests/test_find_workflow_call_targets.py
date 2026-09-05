#!/usr/bin/env python3
# Exercises find_workflow_call_targets.py directly (issue #118) - the unit
# layer that pins _has_workflow_call_trigger()'s per-shape behaviour and the
# YAML-parse-error skip path, complementing rather than duplicating
# test-readme-catalog-check.sh's end-to-end coverage of the bash wrapper
# (sanitisation, NUL-record framing, the temp-file exit-code capture). Run
# via run-tests.sh through the test-find-workflow-call-targets.sh wrapper -
# this file has no bash logic of its own to test, so it is a plain stdlib
# unittest module rather than a test-*.sh script.
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "lib", "find_workflow_call_targets.py"
)
_spec = importlib.util.spec_from_file_location("find_workflow_call_targets", _MODULE_PATH)
# spec_from_file_location() is typed as returning Optional[ModuleSpec] for a
# path it cannot resolve at all - not a real possibility here, since
# _MODULE_PATH is computed from this test file's own known-good location,
# but the assert makes that guarantee explicit for the type checker rather
# than silently narrowing past it.
assert _spec is not None and _spec.loader is not None
find_workflow_call_targets = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(find_workflow_call_targets)


class HasWorkflowCallTriggerTest(unittest.TestCase):
    def test_block_form_with_trigger(self):
        # The realistic shape: PyYAML resolves the bare `on:` key to the
        # boolean True (the "Norway problem"), so this is what a real
        # `yaml.safe_load()` of a GitHub Actions workflow actually produces.
        doc = {True: {"workflow_call": None, "push": None}}
        self.assertTrue(find_workflow_call_targets._has_workflow_call_trigger(doc))

    def test_block_form_without_trigger(self):
        doc = {True: {"push": None}}
        self.assertFalse(find_workflow_call_targets._has_workflow_call_trigger(doc))

    def test_scalar_form_with_trigger(self):
        doc = {True: "workflow_call"}
        self.assertTrue(find_workflow_call_targets._has_workflow_call_trigger(doc))

    def test_scalar_form_without_trigger(self):
        doc = {True: "push"}
        self.assertFalse(find_workflow_call_targets._has_workflow_call_trigger(doc))

    def test_flow_sequence_form_with_trigger(self):
        doc = {True: ["push", "workflow_call"]}
        self.assertTrue(find_workflow_call_targets._has_workflow_call_trigger(doc))

    def test_flow_sequence_form_without_trigger(self):
        doc = {True: ["push"]}
        self.assertFalse(find_workflow_call_targets._has_workflow_call_trigger(doc))

    def test_quoted_on_key_falls_back_to_string_key(self):
        # The old sed/grep detector's own documented gap: a quoted `'on':`
        # key never starts a line with the literal text `on:`, so it was
        # silently invisible. yaml.safe_load() parses a quoted key as the
        # plain string "on", not the boolean True - the fallback this
        # function's own .get(True, .get("on")) chain exists for.
        doc = {"on": {"workflow_call": None}}
        self.assertTrue(find_workflow_call_targets._has_workflow_call_trigger(doc))

    def test_job_named_workflow_call_is_not_a_trigger(self):
        # A real YAML parse inherently keeps `jobs:` and `on:` as separate
        # dict keys, so a job literally named workflow_call can never be
        # misread as the trigger - unlike a flat text-pattern match.
        doc = {True: {"push": None}, "jobs": {"workflow_call": {"runs-on": "ubuntu-latest"}}}
        self.assertFalse(find_workflow_call_targets._has_workflow_call_trigger(doc))

    def test_no_on_key_at_all(self):
        doc = {"name": "No trigger key"}
        self.assertFalse(find_workflow_call_targets._has_workflow_call_trigger(doc))

    def test_non_dict_document_shapes(self):
        for doc in (None, "just a string", ["a", "list"], 42):
            with self.subTest(doc=doc):
                self.assertFalse(find_workflow_call_targets._has_workflow_call_trigger(doc))


class SanitizeForStderrTest(unittest.TestCase):
    def test_embedded_newline_and_carriage_return_are_folded(self):
        # A git-tracked filename could carry a raw newline into the
        # per-file skip diagnostic on stderr, which readme-catalog-check.sh
        # never redirects - unlike sanitize_for_annotation()'s other
        # callers, nothing downstream would have caught this.
        self.assertEqual(
            find_workflow_call_targets._sanitize_for_stderr("legit\n::error::INJECTED"),
            "legit ::error::INJECTED",
        )
        self.assertEqual(
            find_workflow_call_targets._sanitize_for_stderr("legit\r::error::INJECTED"),
            "legit ::error::INJECTED",
        )

    def test_percent_escaped_before_control_fold(self):
        # Order matters: a literal `%0D` must become `%250D`, not `%0D`
        # left alone to be decoded by the runner as a real CR later.
        self.assertEqual(
            find_workflow_call_targets._sanitize_for_stderr("%0D%0A::error::forged"),
            "%250D%250A::error::forged",
        )

    def test_plain_text_is_unchanged(self):
        self.assertEqual(
            find_workflow_call_targets._sanitize_for_stderr("real.yml"),
            "real.yml",
        )


class FindTargetsExceptionDiagnosticTest(unittest.TestCase):
    def _assert_forged_name_does_not_split_stderr(self, forged_name):
        # Skips (rather than fails) on a filesystem that rejects the given
        # control byte in a filename, mirroring
        # test-readme-catalog-check.sh's own newline-filename test.
        with tempfile.TemporaryDirectory() as workflows_dir:
            try:
                with open(os.path.join(workflows_dir, forged_name), "w", encoding="utf-8") as handle:
                    handle.write("on: {workflow_call:")
            except OSError:
                self.skipTest("this filesystem rejects filenames containing this control byte")

            result = subprocess.run(
                [sys.executable, _MODULE_PATH, workflows_dir],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.stdout, b"")
            stderr_lines = result.stderr.decode("utf-8").splitlines()
            self.assertEqual(len(stderr_lines), 1)
            self.assertNotIn("\n::error::", result.stderr.decode("utf-8"))

    def test_stderr_diagnostic_does_not_forge_a_second_annotation_line(self):
        # End-to-end reproduction of the exact live exploit: a malformed
        # workflow file whose FILENAME carries an embedded newline followed
        # by a spoofed `::error::` line.
        self._assert_forged_name_does_not_split_stderr(
            "legit\n::error::INJECTED spoofed annotation.yml"
        )

    def test_stderr_diagnostic_does_not_forge_a_second_annotation_line_via_bare_cr(self):
        # Same exploit via a bare CR rather than LF - the channel
        # annotation-sanitize.sh's own header documents as independently
        # live-observed against a .NET-based runner's TextReader.ReadLine(),
        # which treats a bare CR as a line terminator too. splitlines()
        # below folds a lone CR the same way it folds LF, so this reuses the
        # same assertion shape as the LF case.
        self._assert_forged_name_does_not_split_stderr(
            "legit\r::error::INJECTED spoofed annotation.yml"
        )


class FindTargetsTest(unittest.TestCase):
    def test_returns_yml_then_yaml_sorted_within_each_group(self):
        with tempfile.TemporaryDirectory() as workflows_dir:
            fixtures = {
                "z.yml": "on:\n    workflow_call:\n",
                "a.yml": "on:\n    workflow_call:\n",
                "b.yaml": "on:\n    workflow_call:\n",
            }
            for name, content in fixtures.items():
                with open(os.path.join(workflows_dir, name), "w", encoding="utf-8") as handle:
                    handle.write(content)

            targets = list(find_workflow_call_targets.find_targets(workflows_dir))

            self.assertEqual(targets, ["a.yml", "z.yml", "b.yaml"])

    def test_skips_a_file_without_the_trigger(self):
        with tempfile.TemporaryDirectory() as workflows_dir:
            with open(os.path.join(workflows_dir, "push-only.yml"), "w", encoding="utf-8") as handle:
                handle.write("on:\n    push:\n")

            self.assertEqual(list(find_workflow_call_targets.find_targets(workflows_dir)), [])

    def test_malformed_yaml_is_skipped_not_raised(self):
        with tempfile.TemporaryDirectory() as workflows_dir:
            with open(os.path.join(workflows_dir, "broken.yml"), "w", encoding="utf-8") as handle:
                # An unterminated flow mapping - a genuine YAML syntax error,
                # not merely an unusual-but-valid document shape.
                handle.write("on: {workflow_call:\n")
            with open(os.path.join(workflows_dir, "real.yml"), "w", encoding="utf-8") as handle:
                handle.write("on:\n    workflow_call:\n")

            targets = list(find_workflow_call_targets.find_targets(workflows_dir))

            self.assertEqual(targets, ["real.yml"])

    def test_empty_directory_yields_nothing(self):
        with tempfile.TemporaryDirectory() as workflows_dir:
            self.assertEqual(list(find_workflow_call_targets.find_targets(workflows_dir)), [])

    def test_non_utf8_file_is_skipped_not_raised(self):
        # A yaml.YAMLError-only except clause does not catch this: a raw
        # non-UTF-8 byte makes `open(..., encoding="utf-8")` raise
        # UnicodeDecodeError instead, which propagates out of this
        # generator uncaught unless the except clause is broad enough -
        # exactly the gap that let a real workflow_call trigger in a later
        # file go unreported (verified live during the issue #118 audit).
        with tempfile.TemporaryDirectory() as workflows_dir:
            with open(os.path.join(workflows_dir, "a-bad-encoding.yml"), "wb") as handle:
                handle.write(b"name: bad byte \xff here\non:\n    push:\n")
            with open(os.path.join(workflows_dir, "z-real.yml"), "w", encoding="utf-8") as handle:
                handle.write("on:\n    workflow_call:\n")

            targets = list(find_workflow_call_targets.find_targets(workflows_dir))

            self.assertEqual(targets, ["z-real.yml"])


class MainTest(unittest.TestCase):
    def test_wrong_argument_count_returns_2(self):
        for argv in (["prog"], ["prog", "a", "b"]):
            with self.subTest(argv=argv):
                self.assertEqual(find_workflow_call_targets.main(argv), 2)

    def test_success_writes_nul_terminated_records_and_returns_0(self):
        # Run as a real subprocess rather than calling main() in-process:
        # this is the actual invocation shape readme-catalog-check.sh uses
        # (`python3 find_workflow_call_targets.py <dir>`), and it exercises
        # the real sys.stdout.buffer rather than a substitute object.
        with tempfile.TemporaryDirectory() as workflows_dir:
            with open(os.path.join(workflows_dir, "real.yml"), "w", encoding="utf-8") as handle:
                handle.write("on:\n    workflow_call:\n")
            with open(os.path.join(workflows_dir, "other.yml"), "w", encoding="utf-8") as handle:
                handle.write("on:\n    push:\n")

            result = subprocess.run(
                [sys.executable, _MODULE_PATH, workflows_dir],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"real.yml\x00")

    def test_no_targets_writes_empty_stdout_and_returns_0(self):
        with tempfile.TemporaryDirectory() as workflows_dir:
            with open(os.path.join(workflows_dir, "other.yml"), "w", encoding="utf-8") as handle:
                handle.write("on:\n    push:\n")

            result = subprocess.run(
                [sys.executable, _MODULE_PATH, workflows_dir],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")


if __name__ == "__main__":
    unittest.main()
