#!/usr/bin/env python3
# Exercises the pure core of labeler_eval.py: the sampling, the split, the gold
# reduction and the metrics (issue #192), and drives the commands with their
# boundaries mocked. No test here reaches the network or needs a key.
import contextlib
import importlib.util
import io
import json
import os
import tempfile
import threading
import time
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

    def test_the_hash_is_pinned_for_a_known_text(self):
        self.assertEqual(
            "45777c14d90fa79dc6ce71ceb6f81cced62c929c472199547cfd939a54e954c6",
            labeler_eval.content_hash("Title", "Body"),
        )

    def test_the_split_is_pinned_for_known_issues(self):
        self.assertEqual(
            ['dev', 'dev', 'holdout', 'holdout', 'dev', 'dev', 'dev', 'holdout', 'dev', 'dev', 'dev', 'holdout', 'dev', 'holdout', 'dev', 'holdout'],
            [labeler_eval.split_of("o/r", number, "seed-1", 33) for number in range(1, 17)],
        )

    def test_the_seed_changes_the_split(self):
        first = [labeler_eval.split_of("o/r", n, "one", 50) for n in range(1, 60)]
        second = [labeler_eval.split_of("o/r", n, "two", 50) for n in range(1, 60)]
        self.assertNotEqual(first, second)

    def test_a_missing_body_hashes_like_an_empty_one(self):
        self.assertEqual(labeler_eval.content_hash("t", ""), labeler_eval.content_hash("t", None))

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

    def test_improvement_wording_is_hard(self):
        self.assertTrue(labeler_eval.is_hard("Improve the output", ""))
        self.assertTrue(labeler_eval.is_hard("Title", "Make it possible to export"))

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

    def test_the_manifest_is_sorted_by_repository_and_number(self):
        candidates = [_issue("a/c", n) for n in (9, 2)] + [_issue("a/b", n) for n in (7, 3)]
        manifest = labeler_eval.sample_issues(candidates, "seed", 10, 33, 0)
        self.assertEqual([("a/b", 3), ("a/b", 7), ("a/c", 2), ("a/c", 9)],
                         [(e["repo"], e["number"]) for e in manifest])

    def test_plain_issues_do_not_use_up_the_hard_budget(self):
        candidates = [_issue("a/b", n, title="Typo {}".format(n)) for n in range(1, 6)]
        candidates += [_issue("a/b", n, title="Proposal {}".format(n)) for n in range(6, 9)]
        manifest = labeler_eval.sample_issues(candidates, "seed", 20, 33, 2)
        self.assertEqual(2, sum(1 for entry in manifest if entry["hard"]))

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

    def test_two_priorities_leave_the_priority_open(self):
        gold = labeler_eval.gold_from_labels(["priority: high", "priority: low"], self.OFFERED)
        self.assertIsNone(gold["priority"])

    def test_a_priority_outside_the_known_ones_is_no_gold(self):
        gold = labeler_eval.gold_from_labels(["priority: blocker"], {"priority: blocker"})
        self.assertIsNone(gold["priority"])
        self.assertEqual([], gold["topics"])

    def test_topics_are_sorted(self):
        gold = labeler_eval.gold_from_labels(["ui", "i18n"], self.OFFERED)
        self.assertEqual(["i18n", "ui"], gold["topics"])

    def test_the_fallback_label_is_no_gold(self):
        gold = labeler_eval.gold_from_labels(["bug", "needs-triage"], self.OFFERED)
        self.assertEqual([], gold["topics"])

    def test_the_priority_is_lowercased(self):
        gold = labeler_eval.gold_from_labels(["Priority: High"], {"Priority: High"})
        self.assertEqual("priority: high", gold["priority"])

    def test_the_prediction_keeps_all_its_labels(self):
        self.assertEqual(["bug", "ghost"], labeler_eval.predicted_shape(["bug", "ghost"])["labels"])

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

    def test_critical_over_calls_need_a_priority_gold_that_is_not_critical(self):
        metrics = labeler_eval.compute_metrics(
            [
                _pair(["bug"], ["bug", "priority: critical"]),
                _pair(["priority: critical"], ["priority: critical"]),
                _pair(["priority: high"], ["priority: critical"]),
            ]
        )
        self.assertEqual(1, metrics["critical_over_calls"])

    def test_critical_is_one_step_above_high(self):
        metrics = labeler_eval.compute_metrics([_pair(["priority: high"], ["priority: critical"])])
        self.assertEqual(1.0, metrics["priority_mean_distance"])

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

    def test_fallback_rate_and_labels_per_issue(self):
        metrics = labeler_eval.compute_metrics(
            [
                (
                    labeler_eval.gold_from_labels(["bug"], {"bug"}),
                    labeler_eval.predicted_shape(["needs-triage"]),
                ),
                (
                    labeler_eval.gold_from_labels(["bug"], {"bug"}),
                    labeler_eval.predicted_shape(["bug", "ghost"]),
                ),
            ]
        )
        self.assertEqual(0.5, metrics["fallback_rate"])
        self.assertEqual(1.5, metrics["labels_per_issue"])

    def test_a_referee_none_is_an_answer_for_the_type(self):
        gold = {"type": "none", "priority": None, "topics": []}
        wrong = labeler_eval.compute_metrics([(gold, labeler_eval.predicted_shape(["bug"]))])
        right = labeler_eval.compute_metrics([(gold, labeler_eval.predicted_shape(["i18n"]))])
        self.assertEqual(0.0, wrong["type_accuracy"])
        self.assertEqual(1.0, right["type_accuracy"])
        self.assertEqual({"none -> bug": 1}, wrong["type_confusion"])

    def test_a_referee_none_is_an_answer_for_the_priority(self):
        gold = {"type": None, "priority": "none", "topics": []}
        wrong = labeler_eval.compute_metrics(
            [(gold, labeler_eval.predicted_shape(["priority: high"]))]
        )
        right = labeler_eval.compute_metrics([(gold, labeler_eval.predicted_shape(["i18n"]))])
        self.assertEqual(0.0, wrong["priority_exact"])
        self.assertEqual(1.0, right["priority_exact"])
        self.assertIsNone(wrong["priority_mean_distance"])

    def test_no_gold_at_all_leaves_the_field_out(self):
        gold = {"type": None, "priority": None, "topics": []}
        metrics = labeler_eval.compute_metrics(
            [(gold, labeler_eval.predicted_shape(["bug", "priority: high"]))]
        )
        self.assertIsNone(metrics["type_accuracy"])
        self.assertIsNone(metrics["priority_exact"])

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

    def test_a_plain_issue_never_feeds_the_stability(self):
        results = dict([self._result(2, 0, ["bug"]), self._result(2, 1, ["bug"])])
        _, hard_runs = labeler_eval.pairs_for(self.MANIFEST, results, "convention", {}, "holdout")
        self.assertEqual({}, hard_runs)

    def test_a_pair_carries_the_prediction(self):
        results = dict([self._result(1, 0, ["bug", "ghost"])])
        (gold, predicted), = labeler_eval.pairs_for(self.MANIFEST, results, "convention", {}, "dev")[0]
        self.assertEqual(["bug", "ghost"], predicted["labels"])

    def test_the_text_gold_keeps_priority_and_topics(self):
        results = dict([self._result(1, 0, ["bug"])])
        gold = {"o/r#1": {"type": "none", "priority": "priority: low", "topics": ["i18n"]}}
        pairs, _ = labeler_eval.pairs_for(self.MANIFEST, results, "text", gold, "dev")
        self.assertEqual({"type": "none", "priority": "priority: low", "topics": ["i18n"]}, pairs[0][0])

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
        self.assertEqual(["i18n"], schema["properties"]["topics"]["items"]["enum"])
        self.assertIn("none", schema["properties"]["type"]["enum"])
        self.assertIn("- i18n", request["system"])
        self.assertIn("Issue title:\nTitle\n\nIssue body:\nBody", request["messages"][0]["content"])
        self.assertEqual({"type": "auto"}, request["tool_choice"])

    def test_the_request_is_complete(self):
        request = labeler_eval.judge_request("the-model", "T", "B", ["bug", "priority: low", "needs-triage", "ui"])
        tool = request["tools"][0]
        self.assertEqual("the-model", request["model"])
        self.assertGreater(request["max_tokens"], 0)
        self.assertTrue(tool["strict"])
        self.assertEqual(["type", "priority", "topics"], tool["input_schema"]["required"])
        self.assertFalse(tool["input_schema"]["additionalProperties"])
        properties = tool["input_schema"]["properties"]
        self.assertEqual(["bug", "none"], properties["type"]["enum"])
        self.assertEqual(["priority: low", "none"], properties["priority"]["enum"])
        self.assertEqual(["ui"], properties["topics"]["items"]["enum"])

    def test_the_referee_is_offered_only_the_types_and_priorities_the_repository_has(self):
        request = labeler_eval.judge_request("m", "T", "B", ["Bug", "priority: high", "ui"])
        properties = request["tools"][0]["input_schema"]["properties"]
        self.assertEqual(["bug", "none"], properties["type"]["enum"])
        self.assertEqual(["priority: high", "none"], properties["priority"]["enum"])

    def test_the_tool_input_is_found_by_name(self):
        answer = {"content": [{"type": "text", "text": "x"}, {"type": "tool_use", "name": "report_gold", "input": {"a": 1}}]}
        self.assertEqual({"a": 1}, labeler_eval.tool_input(answer, "report_gold"))

    def test_a_call_to_another_tool_is_not_taken(self):
        answer = {"content": [{"type": "tool_use", "name": "other", "input": {"a": 1}}], "stop_reason": "tool_use"}
        with self.assertRaisesRegex(RuntimeError, "no report_gold call"):
            labeler_eval.tool_input(answer, "report_gold")

    def test_an_answer_without_the_call_is_an_error(self):
        with self.assertRaisesRegex(RuntimeError, r"no report_gold call \(stop reason end_turn\)"):
            labeler_eval.tool_input({"content": [], "stop_reason": "end_turn"}, "report_gold")


class WriteJsonTest(unittest.TestCase):
    def test_the_file_is_replaced_and_no_temporary_file_stays(self):
        with tempfile.TemporaryDirectory() as work:
            path = os.path.join(work, "out.json")
            labeler_eval.write_json(path, {"b": 1, "a": 2})
            labeler_eval.write_json(path, {"a": 3})
            self.assertEqual({"a": 3}, labeler_eval.read_json(path))
            self.assertEqual(["out.json"], os.listdir(work))

    def test_the_file_is_readable_for_others(self):
        with tempfile.TemporaryDirectory() as work:
            path = os.path.join(work, "out.json")
            labeler_eval.write_json(path, {"a": 1})
            self.assertEqual(0o644, os.stat(path).st_mode & 0o777)

    def test_a_value_that_cannot_be_encoded_leaves_the_old_file(self):
        with tempfile.TemporaryDirectory() as work:
            path = os.path.join(work, "out.json")
            labeler_eval.write_json(path, {"a": 1})
            with self.assertRaises(TypeError):
                labeler_eval.write_json(path, {"a": object()})
            self.assertEqual({"a": 1}, labeler_eval.read_json(path))
            self.assertEqual(["out.json"], os.listdir(work))


class ResultsFileTest(unittest.TestCase):
    def _write(self, work, text):
        path = os.path.join(work, "results.jsonl")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        return path

    def test_a_cut_off_last_line_is_ignored(self):
        with tempfile.TemporaryDirectory() as work:
            path = self._write(work, '{"id": "a", "status": "ok"}\n{"id": "b", "sta')
            self.assertEqual({"a"}, set(labeler_eval.read_results(path)))

    def test_a_broken_line_in_the_middle_is_an_error(self):
        with tempfile.TemporaryDirectory() as work:
            path = self._write(work, '{"id": "a"}\n{broken\n{"id": "c"}\n')
            with self.assertRaises(ValueError):
                labeler_eval.read_results(path)

    def test_the_last_line_of_an_id_wins(self):
        with tempfile.TemporaryDirectory() as work:
            path = self._write(work, '{"id": "a", "status": "error"}\n{"id": "a", "status": "ok"}\n')
            self.assertEqual("ok", labeler_eval.read_results(path)["a"]["status"])

    def test_a_missing_newline_is_added_before_appending(self):
        with tempfile.TemporaryDirectory() as work:
            path = self._write(work, '{"id": "a"}')
            labeler_eval.repair_results_tail(path)
            with open(path, encoding="utf-8") as handle:
                self.assertEqual('{"id": "a"}\n', handle.read())

    def test_a_cut_off_last_line_is_removed_before_appending(self):
        with tempfile.TemporaryDirectory() as work:
            path = self._write(work, '{"id": "a"}\n{"id": "b", "sta')
            labeler_eval.repair_results_tail(path)
            with open(path, "a", encoding="utf-8") as sink:
                sink.write('{"id": "c"}\n')
            self.assertEqual({"a", "c"}, set(labeler_eval.read_results(path)))

    def test_a_complete_file_and_a_missing_file_stay_as_they_are(self):
        with tempfile.TemporaryDirectory() as work:
            path = self._write(work, '{"id": "a"}\n')
            labeler_eval.repair_results_tail(path)
            labeler_eval.repair_results_tail(os.path.join(work, "missing.jsonl"))
            with open(path, encoding="utf-8") as handle:
                self.assertEqual('{"id": "a"}\n', handle.read())
            self.assertEqual(["results.jsonl"], os.listdir(work))


class PlanJobsTest(unittest.TestCase):
    ENTRIES = [
        {"repo": "o/r", "number": 1, "hard": False},
        {"repo": "o/r", "number": 2, "hard": True},
    ]

    def test_repeats_follow_the_hard_flag(self):
        jobs = labeler_eval.plan_jobs(self.ENTRIES, 1, 3, {})
        self.assertEqual([("o/r", 1, 0), ("o/r", 2, 0), ("o/r", 2, 1), ("o/r", 2, 2)],
                         [(e["repo"], e["number"], i) for e, i in jobs])

    def test_a_finished_call_is_not_planned_again(self):
        results = {"o/r#1@0": {"status": "ok"}}
        jobs = labeler_eval.plan_jobs(self.ENTRIES, 1, 1, results)
        self.assertEqual([2], [e["number"] for e, _ in jobs])

    def test_a_failed_call_is_planned_again(self):
        for first, second in (("error", "exception"), ("no_tool_call", "unreadable_answer")):
            with self.subTest(statuses=(first, second)):
                results = {"o/r#1@0": {"status": first}, "o/r#2@0": {"status": second}}
                jobs = labeler_eval.plan_jobs(self.ENTRIES, 1, 1, results)
                self.assertEqual([1, 2], [e["number"] for e, _ in jobs])


class ClassifyRetryTest(unittest.TestCase):
    ENTRY = {"repo": "o/r", "number": 3, "sha256": labeler_eval.content_hash("t", "b")}

    def _run(self, answers):
        with tempfile.TemporaryDirectory() as cache:
            labeler_eval.write_json(labeler_eval.issue_path(cache, "o/r", 3), {"title": "t", "body": "b"})
            with mock.patch.object(labeler_eval, "run_helper", side_effect=answers) as helper, \
                    mock.patch.object(labeler_eval.time, "sleep") as sleep:
                result = labeler_eval.classify(cache, self.ENTRY)
        return result, helper.call_count, sleep.call_count

    def test_a_dropped_connection_is_retried(self):
        result, calls, sleeps = self._run([{"status": "error", "http": 0}, {"status": "ok", "labels": []}])
        self.assertEqual("ok", result["status"])
        self.assertEqual((2, 1), (calls, sleeps))

    def test_each_server_side_status_is_retried(self):
        for status in (500, 502, 503, 504):
            with self.subTest(status=status):
                result, calls, _ = self._run([{"status": "error", "http": status}, {"status": "ok", "labels": []}])
                self.assertEqual(("ok", 2), (result["status"], calls))

    def test_a_rate_limit_status_is_retried(self):
        result, calls, _ = self._run([{"status": "error", "http": 429}, {"status": "ok", "labels": []}])
        self.assertEqual(("ok", 2), (result["status"], calls))

    def test_a_transient_status_is_retried(self):
        result, calls, _ = self._run([{"status": "error", "http": 529}, {"status": "ok", "labels": []}])
        self.assertEqual("ok", result["status"])
        self.assertEqual(2, calls)

    def test_another_status_is_not_retried(self):
        result, calls, sleeps = self._run([{"status": "error", "http": 400}])
        self.assertEqual("error", result["status"])
        self.assertEqual((1, 0), (calls, sleeps))

    def test_the_last_attempt_does_not_sleep(self):
        result, calls, sleeps = self._run([{"status": "error", "http": 0}] * labeler_eval.ATTEMPTS)
        self.assertEqual("error", result["status"])
        self.assertEqual((labeler_eval.ATTEMPTS, labeler_eval.ATTEMPTS - 1), (calls, sleeps))


class CallMessagesTest(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(os.environ, {"ANTHROPIC_API_KEY": "key-test"})
        patcher.start()
        self.addCleanup(patcher.stop)
        sleeper = mock.patch.object(labeler_eval.time, "sleep")
        self.sleep = sleeper.start()
        self.addCleanup(sleeper.stop)

    def _http_error(self, code):
        return labeler_eval.urllib.error.HTTPError("u", code, "m", {}, io.BytesIO(b"the reason"))

    def test_a_dropped_connection_is_retried(self):
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = b'{"ok": true}'
        with mock.patch.object(labeler_eval.urllib.request, "urlopen",
                               side_effect=[labeler_eval.urllib.error.URLError("down"), response]):
            self.assertEqual({"ok": True}, labeler_eval.call_messages({}))
        self.assertEqual(1, self.sleep.call_count)

    def test_the_wait_grows_between_attempts(self):
        with mock.patch.object(labeler_eval.urllib.request, "urlopen",
                               side_effect=TimeoutError("slow")):
            with self.assertRaises(RuntimeError):
                labeler_eval.call_messages({})
        delays = [call.args[0] for call in self.sleep.call_args_list]
        self.assertTrue(all(delay > 0 for delay in delays))
        self.assertEqual(sorted(set(delays)), delays)

    def test_a_transient_status_that_stays_is_an_error_with_its_code(self):
        with mock.patch.object(labeler_eval.urllib.request, "urlopen",
                               side_effect=[self._http_error(529)] * labeler_eval.ATTEMPTS):
            with self.assertRaisesRegex(RuntimeError, "HTTP 529"):
                labeler_eval.call_messages({})

    def test_a_connection_that_stays_down_is_an_error(self):
        with mock.patch.object(labeler_eval.urllib.request, "urlopen",
                               side_effect=TimeoutError("slow")) as opener:
            with self.assertRaisesRegex(RuntimeError, "API not reachable"):
                labeler_eval.call_messages({})
        self.assertEqual(labeler_eval.ATTEMPTS, opener.call_count)
        self.assertEqual(labeler_eval.ATTEMPTS - 1, self.sleep.call_count)

    def test_a_client_error_is_not_retried_and_carries_the_reason(self):
        with mock.patch.object(labeler_eval.urllib.request, "urlopen",
                               side_effect=self._http_error(400)) as opener:
            with self.assertRaisesRegex(RuntimeError, "HTTP 400: the reason"):
                labeler_eval.call_messages({})
        self.assertEqual(1, opener.call_count)

    def test_a_transient_status_is_retried(self):
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = b"{}"
        with mock.patch.object(labeler_eval.urllib.request, "urlopen",
                               side_effect=[self._http_error(529), response]):
            self.assertEqual({}, labeler_eval.call_messages({}))


class RunHelperTest(unittest.TestCase):
    def _completed(self, code, out, err=""):
        return mock.Mock(returncode=code, stdout=out, stderr=err)

    def test_the_last_output_line_is_decoded(self):
        with mock.patch.object(labeler_eval.subprocess, "run", return_value=self._completed(0, 'noise\n{"a": 1}\n')):
            self.assertEqual({"a": 1}, labeler_eval.run_helper(["x"]))

    def test_a_failure_carries_the_error_output(self):
        with mock.patch.object(labeler_eval.subprocess, "run", return_value=self._completed(2, "", "boom")):
            with self.assertRaisesRegex(RuntimeError, "boom"):
                labeler_eval.run_helper(["x"])

    def test_a_failing_helper_is_an_error_even_with_output(self):
        with mock.patch.object(labeler_eval.subprocess, "run", return_value=self._completed(1, '{"a": 1}\n', "bad")):
            with self.assertRaisesRegex(RuntimeError, "bad"):
                labeler_eval.run_helper(["x"])

    def test_a_line_separator_inside_a_value_does_not_split_the_line(self):
        output = '{"a": "x\u2028y\u0085z"}\n'
        with mock.patch.object(labeler_eval.subprocess, "run", return_value=self._completed(0, output)):
            self.assertEqual({"a": "x\u2028y\u0085z"}, labeler_eval.run_helper(["x"]))

    def test_empty_output_is_an_error(self):
        with mock.patch.object(labeler_eval.subprocess, "run", return_value=self._completed(0, "\n")):
            with self.assertRaisesRegex(RuntimeError, "no output"):
                labeler_eval.run_helper(["x"])


class CommandRunTest(unittest.TestCase):
    def test_one_broken_call_does_not_lose_the_others(self):
        manifest = {"issues": [
            {"repo": "o/r", "number": 1, "hard": False, "split": "dev"},
            {"repo": "o/r", "number": 2, "hard": False, "split": "dev"},
        ]}

        def classify(_cache, entry):
            if entry["number"] == 1:
                raise RuntimeError("edited")
            return {"status": "ok", "labels": ["bug"]}

        with tempfile.TemporaryDirectory() as work:
            manifest_path = os.path.join(work, "set.json")
            results_path = os.path.join(work, "results.jsonl")
            labeler_eval.write_json(manifest_path, manifest)
            args = mock.Mock(manifest=manifest_path, results=results_path, cache_dir=work, split="dev",
                             repeats=1, hard_repeats=1, workers=2)
            with mock.patch.object(labeler_eval, "offered_labels", return_value=["bug"]), \
                    mock.patch.object(labeler_eval, "classify", side_effect=classify), \
                    contextlib.redirect_stdout(io.StringIO()):
                labeler_eval.command_run(args)
            results = labeler_eval.read_results(results_path)
        self.assertEqual("exception", results["o/r#1@0"]["status"])
        self.assertIn("edited", results["o/r#1@0"]["error"])
        self.assertEqual("ok", results["o/r#2@0"]["status"])


class CommandRunRepeatsTest(unittest.TestCase):
    def test_each_repeat_of_a_hard_case_is_recorded_under_its_own_run(self):
        manifest = {"issues": [{"repo": "o/r", "number": 1, "hard": True, "split": "dev"}]}
        with tempfile.TemporaryDirectory() as work:
            manifest_path = os.path.join(work, "set.json")
            results_path = os.path.join(work, "results.jsonl")
            labeler_eval.write_json(manifest_path, manifest)
            args = mock.Mock(manifest=manifest_path, results=results_path, cache_dir=work, split="dev",
                             repeats=1, hard_repeats=3, workers=1)
            with mock.patch.object(labeler_eval, "offered_labels", return_value=["bug"]), \
                    mock.patch.object(labeler_eval, "classify", return_value={"status": "ok", "labels": ["bug"]}), \
                    contextlib.redirect_stdout(io.StringIO()):
                labeler_eval.command_run(args)
            results = labeler_eval.read_results(results_path)
        self.assertEqual({"o/r#1@0", "o/r#1@1", "o/r#1@2"}, set(results))
        self.assertEqual([0, 1, 2], sorted(record["run"] for record in results.values()))


class CommandJudgeTest(unittest.TestCase):
    def test_a_failed_issue_stays_open_and_the_others_are_kept(self):
        manifest = {"issues": [{"repo": "o/r", "number": 1, "sha256": "x"}, {"repo": "o/r", "number": 2, "sha256": "x"}]}

        def load(_cache, entry):
            if entry["number"] == 1:
                raise RuntimeError("edited")
            return "t", "b"

        answer = {"type": "none", "priority": "priority: low", "topics": ["ui", "i18n"]}
        with tempfile.TemporaryDirectory() as work:
            manifest_path = os.path.join(work, "set.json")
            gold_path = os.path.join(work, "gold.json")
            labeler_eval.write_json(manifest_path, manifest)
            args = mock.Mock(manifest=manifest_path, gold=gold_path, cache_dir=work, model="m", workers=2)
            with mock.patch.object(labeler_eval, "offered_labels", return_value=["ui", "i18n"]), \
                    mock.patch.object(labeler_eval, "load_issue", side_effect=load), \
                    mock.patch.object(labeler_eval, "call_messages", return_value={}), \
                    mock.patch.object(labeler_eval, "tool_input", return_value=answer), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                labeler_eval.command_judge(args)
            gold = labeler_eval.read_json(gold_path)
        self.assertEqual({"o/r#2"}, set(gold))
        self.assertEqual({"type": "none", "priority": "priority: low", "topics": ["i18n", "ui"]}, gold["o/r#2"])


class RunPoolTest(unittest.TestCase):
    def test_an_interruption_cancels_the_queued_calls_and_is_raised(self):
        started = []
        never = threading.Event()

        def work(item):
            started.append(item)
            if item:
                never.wait(0.3)
            return item

        def handle(_future):
            raise KeyboardInterrupt

        with self.assertRaises(KeyboardInterrupt):
            labeler_eval.run_pool(1, list(range(8)), work, handle)
        self.assertLessEqual(len(started), 2)


class TokenTotalsTest(unittest.TestCase):
    def test_the_tokens_of_every_call_are_summed(self):
        results = {
            "a": {"usage": "stop_reason=tool_use input_tokens=10 output_tokens=5 thinking_tokens=unknown"},
            "b": {"usage": "stop_reason=tool_use input_tokens=7 output_tokens=3 thinking_tokens=unknown"},
            "c": {"status": "error"},
        }
        self.assertEqual({"input": 17, "output": 8}, labeler_eval.token_totals(results))


class HardPatternTest(unittest.TestCase):
    def test_a_long_line_without_a_failure_word_is_matched_in_bounded_time(self):
        started = time.monotonic()
        self.assertFalse(labeler_eval.is_hard("x", "ci " * 30000))
        self.assertTrue(labeler_eval.is_hard("x", "ci " * 30000 + "failed"))
        self.assertLess(time.monotonic() - started, 5.0)

    def test_the_failing_build_pattern_stays_on_one_line(self):
        self.assertFalse(labeler_eval.is_hard("x", "the build ran\nthen it failed"))
        self.assertTrue(labeler_eval.is_hard("x", "the build ran and then failed"))

    def test_red_is_a_word_of_its_own(self):
        self.assertTrue(labeler_eval.is_hard("The build is red", ""))
        self.assertFalse(labeler_eval.is_hard("The build log is required", ""))


class IssuePathTest(unittest.TestCase):
    def test_an_identifier_that_could_leave_the_cache_is_refused(self):
        for repo, number in (("o/r", "../../x"), ("o/r", True), ("../r", 1), ("o/r/s", 1), ("o", 1)):
            with self.subTest(repo=repo, number=number):
                with self.assertRaises(ValueError):
                    labeler_eval.issue_path("/cache", repo, number)

    def test_two_identifiers_never_share_a_file(self):
        for repo in ("a__b/c", "a_/b", "a/_b"):
            with self.subTest(repo=repo):
                with self.assertRaises(ValueError):
                    labeler_eval.issue_path("/cache", repo, 1)

    def test_a_repository_name_that_could_leave_the_cache_is_refused_for_labels(self):
        with self.assertRaises(ValueError):
            labeler_eval.labels_path("/cache", "../x")


class TypeCaseTest(unittest.TestCase):
    def test_a_capitalised_type_label_matches_the_lowercase_referee_answer(self):
        gold = labeler_eval.gold_from_labels(["Bug"], {"Bug"})
        metrics = labeler_eval.compute_metrics([(gold, labeler_eval.predicted_shape(["bug"]))])
        self.assertEqual("bug", gold["type"])
        self.assertEqual(1.0, metrics["type_accuracy"])


class CommandResumeTest(unittest.TestCase):
    MANIFEST = {"issues": [
        {"repo": "o/r", "number": 1, "hard": False, "split": "dev"},
        {"repo": "o/r", "number": 2, "hard": False, "split": "dev"},
    ]}

    def _run(self, work, existing):
        manifest_path = os.path.join(work, "set.json")
        results_path = os.path.join(work, "results.jsonl")
        labeler_eval.write_json(manifest_path, self.MANIFEST)
        with open(results_path, "w", encoding="utf-8") as handle:
            handle.write(existing)
        args = mock.Mock(manifest=manifest_path, results=results_path, cache_dir=work, split="dev",
                         repeats=1, hard_repeats=1, workers=1)
        with mock.patch.object(labeler_eval, "offered_labels", return_value=["bug"]), \
                mock.patch.object(labeler_eval, "classify",
                                  return_value={"status": "ok", "labels": ["bug"]}) as classify, \
                contextlib.redirect_stdout(io.StringIO()):
            labeler_eval.command_run(args)
        return labeler_eval.read_results(results_path), classify

    def test_a_call_that_ended_ok_is_not_run_again(self):
        done = json.dumps({"id": "o/r#1@0", "key": "o/r#1", "run": 0, "status": "ok", "labels": ["bug"]})
        with tempfile.TemporaryDirectory() as work:
            results, classify = self._run(work, done + "\n")
        self.assertEqual(1, classify.call_count)
        self.assertEqual({"o/r#1@0", "o/r#2@0"}, set(results))

    def test_a_cut_off_last_line_does_not_break_the_resumed_file(self):
        with tempfile.TemporaryDirectory() as work:
            results, _ = self._run(work, '{"id": "o/r#1@0", "key": "o/r#1", "run": 0, "stat')
        self.assertEqual({"o/r#1@0", "o/r#2@0"}, set(results))


class CommandReportTest(unittest.TestCase):
    def _report(self, with_gold, split="dev"):
        manifest = {"issues": [
            {"repo": "o/r", "number": 1, "hard": False, "split": "dev", "maintainer_labels": ["bug"]},
            {"repo": "o/r", "number": 9, "hard": False, "split": "dev", "maintainer_labels": []},
        ]}
        error = {"id": "o/r#1@0", "key": "o/r#1", "run": 0, "status": "error", "http": 529}
        ok = {"id": "o/r#1@0", "key": "o/r#1", "run": 0, "status": "ok", "labels": ["bug"],
              "offered": ["bug"]}
        failed_other = {"id": "o/r#9@0", "key": "o/r#9", "run": 0, "status": "error", "http": 0}
        with tempfile.TemporaryDirectory() as work:
            manifest_path = os.path.join(work, "set.json")
            results_path = os.path.join(work, "results.jsonl")
            gold_path = os.path.join(work, "gold.json")
            labeler_eval.write_json(manifest_path, manifest)
            labeler_eval.write_json(gold_path, {"o/r#1": {"type": "bug", "priority": None, "topics": []}})
            with open(results_path, "w", encoding="utf-8") as handle:
                for record in (error, ok, failed_other):
                    handle.write(json.dumps(record) + "\n")
            args = mock.Mock(manifest=manifest_path, results=results_path, split=split,
                             gold=gold_path if with_gold else None)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                labeler_eval.command_report(args)
        return json.loads(out.getvalue())

    def test_not_ok_counts_the_calls_whose_latest_result_failed(self):
        report = self._report(with_gold=False)
        self.assertEqual((2, 1), (report["calls"], report["not_ok"]))

    def test_the_report_counts_only_the_calls_of_its_split(self):
        report = self._report(with_gold=False, split="holdout")
        self.assertEqual((0, 0), (report["calls"], report["not_ok"]))
        self.assertEqual({"input": 0, "output": 0}, report["tokens"])

    def test_the_text_kind_needs_a_gold_file(self):
        self.assertNotIn("text", self._report(with_gold=False))
        report = self._report(with_gold=True)
        self.assertEqual(1.0, report["text"]["type_accuracy"])
        self.assertIn("hard_case_stability", report["convention"])


class MetricsTopicsTest(unittest.TestCase):
    def test_a_repeated_topic_counts_once(self):
        gold = {"type": None, "priority": None, "topics": ["ui", "ui"]}
        metrics = labeler_eval.compute_metrics([(gold, labeler_eval.predicted_shape(["ui"]))])
        self.assertEqual((1.0, 1.0), (metrics["topic_precision"], metrics["topic_recall"]))
        once = {"type": None, "priority": None, "topics": ["ui"]}
        metrics = labeler_eval.compute_metrics([(once, labeler_eval.predicted_shape(["ui", "ui"]))])
        self.assertEqual((1.0, 1.0), (metrics["topic_precision"], metrics["topic_recall"]))


class CommandBuildTest(unittest.TestCase):
    def test_an_existing_manifest_is_not_replaced_without_force(self):
        with tempfile.TemporaryDirectory() as work:
            path = os.path.join(work, "set.json")
            labeler_eval.write_json(path, {"issues": []})
            with mock.patch.object(labeler_eval, "fetch_candidates", side_effect=AssertionError("fetched")):
                with self.assertRaisesRegex(SystemExit, "exists"):
                    labeler_eval.main(["build", "--owner", "o", "--manifest", path, "--cache-dir", work])
            self.assertEqual({"issues": []}, labeler_eval.read_json(path))


class TopicsSchemaTest(unittest.TestCase):
    def test_an_empty_topic_set_gives_an_array_that_must_stay_empty(self):
        self.assertEqual({"type": "array", "maxItems": 0}, labeler_eval.topics_schema({"bug", "enhancement"}))

    def test_topics_give_an_enum_of_their_names(self):
        schema = labeler_eval.topics_schema({"bug", "i18n"})
        self.assertEqual(["i18n"], schema["items"]["enum"])


class CommandFetchTest(unittest.TestCase):
    def _manifest(self, work, sha):
        path = os.path.join(work, "set.json")
        labeler_eval.write_json(path, {"issues": [{"repo": "o/r", "number": 1, "sha256": sha}]})
        return path

    def _gh(self, arguments):
        if arguments[1].endswith("/issues/1"):
            return json.dumps({"title": "t", "body": None})
        return "[]"

    def test_a_fresh_cache_is_filled_and_checked(self):
        with tempfile.TemporaryDirectory() as work:
            manifest = self._manifest(work, labeler_eval.content_hash("t", ""))
            args = mock.Mock(manifest=manifest, cache_dir=os.path.join(work, "cache"))
            with mock.patch.object(labeler_eval, "run_gh", side_effect=self._gh), \
                    contextlib.redirect_stdout(io.StringIO()) as out:
                labeler_eval.command_fetch(args)
            self.assertIn("1 issues, 0 changed", out.getvalue())
            self.assertTrue(os.path.exists(labeler_eval.issue_path(args.cache_dir, "o/r", 1)))
            self.assertTrue(os.path.exists(labeler_eval.labels_path(args.cache_dir, "o/r")))

    def test_an_edited_issue_fails_the_command_and_keeps_the_manifest(self):
        with tempfile.TemporaryDirectory() as work:
            manifest = self._manifest(work, "0" * 64)
            args = mock.Mock(manifest=manifest, cache_dir=os.path.join(work, "cache"))
            with mock.patch.object(labeler_eval, "run_gh", side_effect=self._gh), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as err:
                with self.assertRaises(SystemExit):
                    labeler_eval.command_fetch(args)
            self.assertIn("o/r#1 changed", err.getvalue())
            self.assertEqual("0" * 64, labeler_eval.read_json(manifest)["issues"][0]["sha256"])


if __name__ == "__main__":
    unittest.main()
