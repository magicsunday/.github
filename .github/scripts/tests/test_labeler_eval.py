#!/usr/bin/env python3
# Exercises the pure core of labeler_eval.py: the sampling, the split, the gold
# reduction and the metrics (issue #192). The commands that fetch issues or call
# the API are not run here, they need the network and a key.
import importlib.util
import json
import os
import tempfile
import unittest
from unittest import mock

_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "eval", "labeler_eval.py"
)
_spec = importlib.util.spec_from_file_location("labeler_eval", _MODULE_PATH)
assert _spec is not None and _spec.loader is not None
labeler_eval = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(labeler_eval)


def _issue(repo, number, labels=("bug",), title="A title", body="A body"):
    return {"repo": repo, "number": number, "title": title, "body": body, "labels": list(labels)}


class LabelKindTest(unittest.TestCase):
    def test_kinds_are_told_apart_without_regard_to_case(self):
        self.assertEqual("type", labeler_eval.label_kind("Bug"))
        self.assertEqual("type", labeler_eval.label_kind("documentation"))
        self.assertEqual("priority", labeler_eval.label_kind("Priority: High"))
        self.assertEqual("topic", labeler_eval.label_kind("i18n"))
        self.assertEqual("topic", labeler_eval.label_kind("priority"))


class HashAndSplitTest(unittest.TestCase):
    def test_hash_changes_with_title_and_body(self):
        base = labeler_eval.content_hash("t", "b")
        self.assertNotEqual(base, labeler_eval.content_hash("t2", "b"))
        self.assertNotEqual(base, labeler_eval.content_hash("t", "b2"))

    def test_a_missing_body_hashes_like_an_empty_one(self):
        self.assertEqual(labeler_eval.content_hash("t", ""), labeler_eval.content_hash("t", None))

    def test_split_depends_on_the_issue_alone(self):
        first = labeler_eval.split_of("a/b", 7, "seed", 33)
        self.assertEqual(first, labeler_eval.split_of("a/b", 7, "seed", 33))

    def test_split_follows_the_holdout_share(self):
        splits = [labeler_eval.split_of("a/b", n, "seed", 33) for n in range(1, 2001)]
        share = splits.count("holdout") / len(splits)
        self.assertGreater(share, 0.28)
        self.assertLess(share, 0.38)

    def test_zero_percent_keeps_everything_in_dev(self):
        splits = {labeler_eval.split_of("a/b", n, "seed", 0) for n in range(1, 200)}
        self.assertEqual({"dev"}, splits)


class HardCaseTest(unittest.TestCase):
    def test_proposal_wording_is_hard(self):
        self.assertTrue(labeler_eval.is_hard("Proposal: new option", ""))

    def test_failing_build_is_hard_in_either_order(self):
        self.assertTrue(labeler_eval.is_hard("The CI build fails", ""))
        self.assertTrue(labeler_eval.is_hard("Failing build on main", ""))

    def test_plain_text_is_not_hard(self):
        self.assertFalse(labeler_eval.is_hard("Typo in the readme", "Fix a typo."))

    def test_a_missing_body_is_tolerated(self):
        self.assertFalse(labeler_eval.is_hard("Typo", None))


class SampleIssuesTest(unittest.TestCase):
    def test_issues_without_a_type_label_are_left_out(self):
        manifest = labeler_eval.sample_issues(
            [_issue("a/b", 1, labels=("i18n",)), _issue("a/b", 2, labels=("bug", "i18n"))],
            "seed", 10, 33, 10,
        )
        self.assertEqual([2], [entry["number"] for entry in manifest])

    def test_the_cap_applies_per_repository(self):
        candidates = [_issue("a/b", n) for n in range(1, 11)] + [_issue("a/c", n) for n in range(1, 4)]
        manifest = labeler_eval.sample_issues(candidates, "seed", 4, 33, 0)
        counts = {}
        for entry in manifest:
            counts[entry["repo"]] = counts.get(entry["repo"], 0) + 1
        self.assertEqual({"a/b": 4, "a/c": 3}, counts)

    def test_the_sample_is_reproducible_and_independent_of_input_order(self):
        candidates = [_issue("a/b", n) for n in range(1, 30)]
        first = labeler_eval.sample_issues(candidates, "seed", 5, 33, 0)
        second = labeler_eval.sample_issues(list(reversed(candidates)), "seed", 5, 33, 0)
        self.assertEqual(first, second)

    def test_another_seed_picks_another_sample(self):
        candidates = [_issue("a/b", n) for n in range(1, 60)]
        first = {e["number"] for e in labeler_eval.sample_issues(candidates, "one", 5, 33, 0)}
        second = {e["number"] for e in labeler_eval.sample_issues(candidates, "two", 5, 33, 0)}
        self.assertNotEqual(first, second)

    def test_the_hard_budget_is_respected(self):
        candidates = [_issue("a/b", n, title="Proposal {}".format(n)) for n in range(1, 8)]
        manifest = labeler_eval.sample_issues(candidates, "seed", 10, 33, 3)
        self.assertEqual(3, sum(1 for entry in manifest if entry["hard"]))

    def test_an_entry_carries_hash_split_and_labels(self):
        manifest = labeler_eval.sample_issues(
            [_issue("a/b", 5, labels=("enhancement", "Alpha"), title="t", body="b")], "seed", 10, 33, 0
        )
        entry = manifest[0]
        self.assertEqual(labeler_eval.content_hash("t", "b"), entry["sha256"])
        self.assertEqual(labeler_eval.split_of("a/b", 5, "seed", 33), entry["split"])
        self.assertEqual(["Alpha", "enhancement"], entry["maintainer_labels"])


class GoldTest(unittest.TestCase):
    OFFERED = {"bug", "enhancement", "priority: high", "priority: low", "i18n", "ui", "needs-triage"}

    def test_labels_outside_the_offered_set_do_not_count(self):
        gold = labeler_eval.gold_from_labels(["bug", "i18n", "wontfix"], self.OFFERED)
        self.assertEqual({"type": "bug", "priority": None, "topics": ["i18n"]}, gold)

    def test_two_types_leave_the_type_open(self):
        gold = labeler_eval.gold_from_labels(["bug", "enhancement"], self.OFFERED)
        self.assertIsNone(gold["type"])

    def test_the_fallback_label_is_no_gold(self):
        gold = labeler_eval.gold_from_labels(["bug", "needs-triage"], self.OFFERED)
        self.assertEqual([], gold["topics"])

    def test_the_priority_is_lowercased(self):
        gold = labeler_eval.gold_from_labels(["Priority: High"], {"Priority: High"})
        self.assertEqual("priority: high", gold["priority"])

    def test_the_prediction_notes_the_fallback(self):
        shape = labeler_eval.predicted_shape(["needs-triage"])
        self.assertTrue(shape["fallback"])
        self.assertEqual([], shape["topics"])
        self.assertFalse(labeler_eval.predicted_shape(["bug"])["fallback"])


def _pair(gold_labels, predicted_labels, offered=None):
    offered = offered or set(gold_labels) | set(predicted_labels)
    return (
        labeler_eval.gold_from_labels(gold_labels, offered),
        labeler_eval.predicted_shape(predicted_labels),
        offered,
        len(predicted_labels),
    )


class MetricsTest(unittest.TestCase):
    def test_type_accuracy_and_confusion(self):
        metrics = labeler_eval.compute_metrics(
            [_pair(["bug"], ["bug"]), _pair(["bug"], ["enhancement"]), _pair(["enhancement"], ["enhancement"])]
        )
        self.assertEqual(0.6667, metrics["type_accuracy"])
        self.assertEqual(
            {"bug -> bug": 1, "bug -> enhancement": 1, "enhancement -> enhancement": 1},
            metrics["type_confusion"],
        )

    def test_a_missing_predicted_type_counts_as_a_miss(self):
        metrics = labeler_eval.compute_metrics([_pair(["bug"], ["i18n"], {"bug", "i18n"})])
        self.assertEqual(0.0, metrics["type_accuracy"])
        self.assertEqual({"bug -> none": 1}, metrics["type_confusion"])

    def test_issues_without_a_type_gold_do_not_enter_the_type_accuracy(self):
        metrics = labeler_eval.compute_metrics([_pair(["i18n"], ["bug"], {"i18n", "bug"})])
        self.assertIsNone(metrics["type_accuracy"])

    def test_priority_exact_and_distance(self):
        metrics = labeler_eval.compute_metrics(
            [
                _pair(["priority: low"], ["priority: low"]),
                _pair(["priority: low"], ["priority: high"]),
            ]
        )
        self.assertEqual(0.5, metrics["priority_exact"])
        self.assertEqual(1.0, metrics["priority_mean_distance"])

    def test_the_distance_skips_issues_without_a_predicted_priority(self):
        metrics = labeler_eval.compute_metrics(
            [_pair(["priority: low"], ["bug"], {"priority: low", "bug"}), _pair(["priority: low"], ["priority: medium"])]
        )
        self.assertEqual(1.0, metrics["priority_mean_distance"])
        self.assertEqual(0.0, metrics["priority_exact"])

    def test_critical_over_calls_count_even_without_a_priority_gold(self):
        metrics = labeler_eval.compute_metrics(
            [
                _pair(["bug"], ["bug", "priority: critical"]),
                _pair(["priority: critical"], ["priority: critical"]),
                _pair(["priority: high"], ["priority: critical"]),
            ]
        )
        self.assertEqual(2, metrics["critical_over_calls"])

    def test_topic_precision_and_recall(self):
        metrics = labeler_eval.compute_metrics(
            [_pair(["i18n", "ui"], ["i18n", "build"], {"i18n", "ui", "build"})]
        )
        self.assertEqual(0.5, metrics["topic_precision"])
        self.assertEqual(0.5, metrics["topic_recall"])

    def test_no_topics_give_no_ratio(self):
        metrics = labeler_eval.compute_metrics([_pair(["bug"], ["bug"])])
        self.assertIsNone(metrics["topic_precision"])
        self.assertIsNone(metrics["topic_recall"])

    def test_fallback_rate_forbidden_labels_and_labels_per_issue(self):
        metrics = labeler_eval.compute_metrics(
            [
                (
                    labeler_eval.gold_from_labels(["bug"], {"bug"}),
                    labeler_eval.predicted_shape(["needs-triage"]),
                    {"bug", "needs-triage"},
                    1,
                ),
                (
                    labeler_eval.gold_from_labels(["bug"], {"bug"}),
                    labeler_eval.predicted_shape(["bug", "ghost"]),
                    {"bug"},
                    2,
                ),
            ]
        )
        self.assertEqual(0.5, metrics["fallback_rate"])
        self.assertEqual(1, metrics["forbidden_labels"])
        self.assertEqual(1.5, metrics["labels_per_issue"])

    def test_an_empty_input_gives_no_ratios(self):
        metrics = labeler_eval.compute_metrics([])
        self.assertEqual(0, metrics["issues"])
        self.assertIsNone(metrics["fallback_rate"])


class StabilityTest(unittest.TestCase):
    def test_identical_runs_are_fully_stable(self):
        self.assertEqual(1.0, labeler_eval.stability({"a#1": [["bug"], ["bug"], ["bug"]]}))

    def test_the_share_of_the_most_common_set_is_reported(self):
        self.assertEqual(0.6667, labeler_eval.stability({"a#1": [["bug"], ["bug"], ["enhancement"]]}))

    def test_label_order_does_not_matter(self):
        self.assertEqual(1.0, labeler_eval.stability({"a#1": [["bug", "ui"], ["ui", "bug"]]}))

    def test_single_runs_are_skipped(self):
        self.assertIsNone(labeler_eval.stability({"a#1": [["bug"]]}))

    def test_the_mean_runs_over_issues(self):
        runs = {"a#1": [["bug"], ["bug"]], "a#2": [["bug"], ["enhancement"]]}
        self.assertEqual(0.75, labeler_eval.stability(runs))


class FetchRepoLabelsTest(unittest.TestCase):
    def test_pages_printed_back_to_back_are_merged(self):
        pages = '[{"name": "a", "description": "x"}]\n[{"name": "b", "description": null}]\n'
        with mock.patch.object(labeler_eval, "run_gh", return_value=pages):
            labels = labeler_eval.fetch_repo_labels("o/r")
        self.assertEqual([{"name": "a", "description": "x"}, {"name": "b", "description": ""}], labels)

    def test_no_labels_give_an_empty_list(self):
        with mock.patch.object(labeler_eval, "run_gh", return_value="[]\n"):
            self.assertEqual([], labeler_eval.fetch_repo_labels("o/r"))


class LoadIssueTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.cache = self._tmp.name

    def _store(self, title, body):
        labeler_eval.write_json(labeler_eval.issue_path(self.cache, "o/r", 3), {"title": title, "body": body})

    def test_the_cached_text_is_returned_when_the_hash_matches(self):
        self._store("t", "b")
        entry = {"repo": "o/r", "number": 3, "sha256": labeler_eval.content_hash("t", "b")}
        self.assertEqual(("t", "b"), labeler_eval.load_issue(self.cache, entry))

    def test_an_edited_issue_is_refused(self):
        self._store("t", "edited")
        entry = {"repo": "o/r", "number": 3, "sha256": labeler_eval.content_hash("t", "b")}
        with self.assertRaisesRegex(RuntimeError, "o/r#3 changed"):
            labeler_eval.load_issue(self.cache, entry)

    def test_a_null_body_matches_an_empty_one(self):
        self._store("t", None)
        entry = {"repo": "o/r", "number": 3, "sha256": labeler_eval.content_hash("t", "")}
        self.assertEqual(("t", ""), labeler_eval.load_issue(self.cache, entry))


class ResultsTest(unittest.TestCase):
    def test_results_are_read_by_id_and_blank_lines_are_skipped(self):
        with tempfile.TemporaryDirectory() as work:
            path = os.path.join(work, "results.jsonl")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(json.dumps({"id": "o/r#1@0", "status": "ok"}) + "\n\n")
            self.assertEqual({"o/r#1@0": {"id": "o/r#1@0", "status": "ok"}}, labeler_eval.read_results(path))

    def test_a_missing_file_gives_no_results(self):
        self.assertEqual({}, labeler_eval.read_results("/nonexistent/results.jsonl"))

    def test_the_result_key_names_issue_and_run(self):
        self.assertEqual("o/r#4@2", labeler_eval.result_key({"repo": "o/r", "number": 4}, 2))


class SelectedTest(unittest.TestCase):
    MANIFEST = {"issues": [{"split": "dev", "number": 1}, {"split": "holdout", "number": 2}]}

    def test_a_split_picks_its_issues(self):
        self.assertEqual([2], [e["number"] for e in labeler_eval.selected(self.MANIFEST, "holdout")])

    def test_all_picks_everything(self):
        self.assertEqual(2, len(labeler_eval.selected(self.MANIFEST, "all")))


class PairsForTest(unittest.TestCase):
    MANIFEST = {
        "issues": [
            {"repo": "o/r", "number": 1, "split": "dev", "hard": True, "maintainer_labels": ["bug", "i18n", "wontfix"]},
            {"repo": "o/r", "number": 2, "split": "holdout", "hard": False, "maintainer_labels": ["bug"]},
        ]
    }

    def _result(self, number, run, labels, status="ok"):
        record = {"id": "o/r#{}@{}".format(number, run), "key": "o/r#{}".format(number), "run": run,
                  "offered": ["bug", "i18n"], "status": status, "labels": labels}
        return record["id"], record

    def test_convention_gold_uses_the_offered_labels_only(self):
        results = dict([self._result(1, 0, ["bug"])])
        pairs, _ = labeler_eval.pairs_for(self.MANIFEST, results, "convention", {}, "dev")
        self.assertEqual(["i18n"], pairs[0][0]["topics"])

    def test_other_splits_and_failed_calls_are_skipped(self):
        results = dict([self._result(1, 0, ["bug"], status="error"), self._result(2, 0, ["bug"])])
        pairs, _ = labeler_eval.pairs_for(self.MANIFEST, results, "convention", {}, "dev")
        self.assertEqual([], pairs)

    def test_hard_cases_collect_their_repeated_runs(self):
        results = dict([self._result(1, 0, ["bug"]), self._result(1, 1, ["bug", "i18n"])])
        _, hard_runs = labeler_eval.pairs_for(self.MANIFEST, results, "convention", {}, "dev")
        self.assertEqual({"o/r#1": [["bug"], ["bug", "i18n"]]}, {k: sorted(v) for k, v in hard_runs.items()})

    def test_only_the_first_run_of_an_issue_enters_the_metrics(self):
        results = dict([self._result(1, 0, ["bug"]), self._result(1, 1, ["bug"]), self._result(1, 2, ["bug"])])
        pairs, hard_runs = labeler_eval.pairs_for(self.MANIFEST, results, "convention", {}, "dev")
        self.assertEqual(1, len(pairs))
        self.assertEqual(3, len(hard_runs["o/r#1"]))

    def test_a_failed_first_run_leaves_the_issue_out_of_the_metrics(self):
        results = dict([self._result(1, 0, ["bug"], status="error"), self._result(1, 1, ["bug"])])
        pairs, _ = labeler_eval.pairs_for(self.MANIFEST, results, "convention", {}, "dev")
        self.assertEqual([], pairs)

    def test_text_gold_is_taken_from_the_referee_and_missing_ones_are_skipped(self):
        results = dict([self._result(1, 0, ["bug"])])
        gold = {"o/r#1": {"type": "enhancement", "priority": None, "topics": []}}
        pairs, _ = labeler_eval.pairs_for(self.MANIFEST, results, "text", gold, "dev")
        self.assertEqual("enhancement", pairs[0][0]["type"])
        pairs, _ = labeler_eval.pairs_for(self.MANIFEST, results, "text", {}, "dev")
        self.assertEqual([], pairs)


class RefereeTest(unittest.TestCase):
    def test_the_request_offers_the_labels_and_the_text(self):
        request = labeler_eval.judge_request("m", "Title", "Body", ["bug", "i18n"])
        schema = request["tools"][0]["input_schema"]
        self.assertEqual(["bug", "i18n"], schema["properties"]["topics"]["items"]["enum"])
        self.assertIn("none", schema["properties"]["type"]["enum"])
        self.assertIn("- i18n", request["system"])
        self.assertIn("Issue title:\nTitle\n\nIssue body:\nBody", request["messages"][0]["content"])
        self.assertEqual({"type": "auto"}, request["tool_choice"])

    def test_the_tool_input_is_found_by_name(self):
        answer = {"content": [{"type": "text", "text": "x"}, {"type": "tool_use", "name": "report_gold", "input": {"a": 1}}]}
        self.assertEqual({"a": 1}, labeler_eval.tool_input(answer, "report_gold"))

    def test_an_answer_without_the_call_is_an_error(self):
        with self.assertRaisesRegex(RuntimeError, "no report_gold call"):
            labeler_eval.tool_input({"content": [], "stop_reason": "end_turn"}, "report_gold")


if __name__ == "__main__":
    unittest.main()
