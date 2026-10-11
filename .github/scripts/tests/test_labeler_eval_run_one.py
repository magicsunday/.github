#!/usr/bin/env python3
# Exercises .github/scripts/eval/run-one.sh with a stub for curl: the label names
# it offers and the one line it prints for each way a call can end. The stub is a
# small Python script on PATH that records how it was called. No test here
# reaches the network.
import json
import os
import stat
import subprocess
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
RUN_ONE = os.path.join(_HERE, "..", "eval", "run-one.sh")

CURL_STUB = """#!/usr/bin/env python3
import json
import os
import sys

with open(os.environ["STUB_ARGV"], "w", encoding="utf-8") as handle:
    json.dump(sys.argv[1:], handle)
headers = []
arguments = sys.argv[1:]
for index, argument in enumerate(arguments):
    if argument == "-H" and arguments[index + 1].startswith("@"):
        with open(arguments[index + 1][1:], encoding="utf-8") as header_file:
            headers.append(header_file.read())
with open(os.environ["STUB_HEADERS"], "w", encoding="utf-8") as handle:
    json.dump(headers, handle)
with open(os.environ["STUB_STDIN"], "w", encoding="utf-8") as handle:
    handle.write(sys.stdin.read())
if os.environ.get("STUB_FAIL"):
    sys.exit(7)
with open(os.environ["STUB_RESPONSE"], encoding="utf-8") as handle:
    sys.stdout.write(handle.read())
sys.stdout.write("\\n" + os.environ["STUB_STATUS"])
"""

LABELS = [
    {"name": "bug", "description": "Something is broken"},
    {"name": "needs-triage", "description": "Not yet classified"},
    {"name": "i18n", "description": ""},
    {"name": "dependencies", "description": "Pull requests that update a dependency file"},
    {"name": "status: accepted", "description": "Set by maintainers after triage"},
]


def tool_response(label, confidence):
    return json.dumps({
        "stop_reason": "tool_use",
        "content": [{"type": "tool_use", "name": "assign_labels",
                     "input": {"labels": [{"label": label, "confidence": confidence}]}}],
        "usage": {"input_tokens": 10, "output_tokens": 5},
    })


class RunOneTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.work = self._tmp.name
        os.makedirs(os.path.join(self.work, "bin"))
        stub = os.path.join(self.work, "bin", "curl")
        with open(stub, "w", encoding="utf-8") as handle:
            handle.write(CURL_STUB)
        os.chmod(stub, os.stat(stub).st_mode | stat.S_IXUSR)
        self.paths = {name: os.path.join(self.work, name)
                      for name in ("labels.json", "title", "body", "argv", "headers", "stdin", "response")}
        self._write("labels.json", json.dumps(LABELS))
        self._write("title", "A title")
        self._write("body", "A body")

    def _write(self, name, text):
        with open(self.paths[name], "w", encoding="utf-8") as handle:
            handle.write(text)

    def _read(self, name):
        with open(self.paths[name], encoding="utf-8") as handle:
            return handle.read()

    def _run(self, *arguments, status="200", fail=False):
        environment = dict(
            os.environ,
            PATH=os.path.join(self.work, "bin") + os.pathsep + os.environ["PATH"],
            ANTHROPIC_API_KEY="key-test",
            STUB_ARGV=self.paths["argv"], STUB_HEADERS=self.paths["headers"], STUB_STDIN=self.paths["stdin"],
            STUB_RESPONSE=self.paths["response"], STUB_STATUS=status,
        )
        if fail:
            environment["STUB_FAIL"] = "1"
        return subprocess.run(["bash", RUN_ONE, *arguments], capture_output=True, text=True,
                              env=environment, check=False)

    def _classify(self, response, **options):
        self._write("response", response)
        completed = self._run("classify", "o/r", self.paths["title"], self.paths["body"],
                              self.paths["labels.json"], **options)
        self.assertEqual(0, completed.returncode, completed.stderr)
        return json.loads(completed.stdout)

    def test_offered_drops_the_pull_request_label_and_the_maintainer_label(self):
        completed = self._run("offered", self.paths["labels.json"])
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertEqual(["bug", "needs-triage", "i18n"], json.loads(completed.stdout))

    def test_a_confident_answer_gives_its_label_and_the_usage(self):
        result = self._classify(tool_response("bug", 0.95))
        self.assertEqual(
            {"status": "ok", "labels": ["bug"],
             "usage": "stop_reason=tool_use input_tokens=10 output_tokens=5 thinking_tokens=unknown"},
            result,
        )

    def test_a_label_below_its_floor_gives_the_fallback_label(self):
        self.assertEqual(["needs-triage"], self._classify(tool_response("bug", 0.1))["labels"])

    def test_a_topic_label_is_passed_on(self):
        self.assertEqual(["i18n"], self._classify(tool_response("i18n", 0.95))["labels"])

    def test_a_label_the_filters_hide_is_not_applied(self):
        result = self._classify(tool_response("dependencies", 0.95))
        self.assertEqual(["needs-triage"], result["labels"])

    def test_an_empty_selection_without_a_fallback_label_gives_no_label(self):
        self._write("labels.json", json.dumps([LABELS[0], LABELS[2]]))
        self.assertEqual([], self._classify(tool_response("bug", 0.1))["labels"])

    def test_a_failing_status_is_reported_with_its_code(self):
        self.assertEqual({"status": "error", "http": 529},
                         self._classify('{"type":"error"}', status="529"))

    def test_a_client_error_status_is_reported_with_its_code(self):
        self.assertEqual({"status": "error", "http": 400},
                         self._classify('{"type":"error"}', status="400"))

    def test_an_answer_without_a_tool_call_is_reported_with_the_usage(self):
        result = self._classify(json.dumps({"stop_reason": "max_tokens", "content": [],
                                            "usage": {"input_tokens": 10, "output_tokens": 1024}}))
        self.assertEqual("no_tool_call", result["status"])
        self.assertEqual(
            "stop_reason=max_tokens input_tokens=10 output_tokens=1024 thinking_tokens=unknown", result["usage"])

    def test_an_unreadable_answer_is_reported(self):
        answer = {"stop_reason": "tool_use", "usage": {"input_tokens": 1, "output_tokens": 1},
                  "content": [{"type": "tool_use", "name": "assign_labels", "input": {"labels": 5}}]}
        result = self._classify(json.dumps(answer))
        self.assertEqual("unreadable_answer", result["status"])
        self.assertIn("input_tokens=1", result["usage"])

    def test_a_failing_curl_is_reported_as_an_error_without_a_status(self):
        self.assertEqual({"status": "error", "http": 0}, self._classify("{}", fail=True))

    def test_the_request_carries_the_key_the_timeouts_and_the_issue_text(self):
        self._classify(tool_response("bug", 0.95))
        arguments = json.loads(self._read("argv"))
        self.assertNotIn("key-test", " ".join(arguments))
        self.assertEqual(["x-api-key: key-test\n"], json.loads(self._read("headers")))
        self.assertEqual("60", arguments[arguments.index("--max-time") + 1])
        self.assertEqual("https://api.anthropic.com/v1/messages", arguments[arguments.index("-w") + 2])
        request = json.loads(self._read("stdin"))
        self.assertIn("A title", request["messages"][0]["content"])
        self.assertIn("A body", request["messages"][0]["content"])
        self.assertIn("o/r", request["system"])

    def test_the_request_leaves_out_the_hidden_labels(self):
        self._classify(tool_response("bug", 0.95))
        request = self._read("stdin")
        self.assertIn("needs-triage", request)
        self.assertNotIn("dependencies", request)
        self.assertNotIn("status: accepted", request)

    def test_a_missing_key_stops_the_script_before_any_request(self):
        self._write("response", tool_response("bug", 0.95))
        environment = dict(
            os.environ,
            PATH=os.path.join(self.work, "bin") + os.pathsep + os.environ["PATH"],
            STUB_ARGV=self.paths["argv"], STUB_HEADERS=self.paths["headers"], STUB_STDIN=self.paths["stdin"],
            STUB_RESPONSE=self.paths["response"], STUB_STATUS="200",
        )
        environment.pop("ANTHROPIC_API_KEY", None)
        completed = subprocess.run(
            ["bash", RUN_ONE, "classify", "o/r", self.paths["title"], self.paths["body"], self.paths["labels.json"]],
            capture_output=True, text=True, env=environment, check=False,
        )
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("ANTHROPIC_API_KEY", completed.stderr)
        self.assertFalse(os.path.exists(self.paths["argv"]))

    def test_an_unknown_mode_fails_with_status_2(self):
        self.assertEqual(2, self._run("nonsense").returncode)


if __name__ == "__main__":
    unittest.main()
