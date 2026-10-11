#!/usr/bin/env python3
"""Frozen evaluation set and metrics for the AI issue labeler (issue #192).

Four subcommands share one manifest, `.github/eval/labeler-set.json`:

  build   samples issues of the public repositories of an account and freezes
          them as a manifest of numbers, content hashes, splits and the labels
          the maintainers set. The texts themselves stay in a cache directory
          outside the repository.
  judge   asks a referee model what the title and the body alone establish, the
          second kind of gold. The referee sees the same input as the labeler.
  run     sends every frozen issue through the labeler pipeline of
          `.github/scripts/lib/ai-issue-labeler.sh`, hard cases several times,
          and appends one result line per call.
  report  compares the results with both kinds of gold and prints the metrics.

Only the standard library is used, so there is nothing to pin.
"""

import argparse
import concurrent.futures
import hashlib
import json
import os
import random
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

TYPE_LABELS = ("bug", "enhancement", "documentation")
PRIORITY_ORDER = {
    "priority: low": 1,
    "priority: medium": 2,
    "priority: high": 3,
    "priority: critical": 4,
}
FALLBACK_LABEL = "needs-triage"

# Texts that tend to confuse the labeler: proposals that read like features,
# failing builds, and wording that sits between a bug and an enhancement.
HARD_PATTERNS = (
    re.compile(r"\b(proposal|propose|idea|rfc|should we|consider)\b", re.IGNORECASE),
    re.compile(r"\b(build|ci|pipeline|workflow)\b.*\b(fail|broken|red)", re.IGNORECASE),
    re.compile(r"\b(fail(s|ed|ing)?|broken|regression)\b.*\b(build|ci|pipeline)", re.IGNORECASE),
    re.compile(r"\b(improve|support|allow|make it possible)\b", re.IGNORECASE),
)

MESSAGES_URL = "https://api.anthropic.com/v1/messages"

# The referee answers "none" where the text establishes no type or priority.
NO_ANSWER = "none"


def label_kind(name):
    """Returns "type", "priority" or "topic", matched without regard to case."""
    lowered = name.lower()
    if lowered.startswith("priority:"):
        return "priority"
    if lowered in TYPE_LABELS:
        return "type"
    return "topic"


def content_hash(title, body):
    """Hash of the text the labeler sees, so an edited issue can be told."""
    text = title + "\n\n" + (body or "")
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def issue_key(repo, number):
    return "{}#{}".format(repo, number)


def split_of(repo, number, seed, holdout_percent):
    """Assigns an issue to dev or holdout from its identity alone, so adding or
    dropping other issues never moves it."""
    digest = hashlib.sha256("{}:{}".format(seed, issue_key(repo, number)).encode()).hexdigest()
    return "holdout" if int(digest, 16) % 100 < holdout_percent else "dev"


def is_hard(title, body):
    text = title + "\n" + (body or "")
    return any(pattern.search(text) for pattern in HARD_PATTERNS)


def sample_issues(candidates, seed, per_repo_cap, holdout_percent, hard_cap):
    """Picks at most per_repo_cap issues per repository, reproducibly.

    candidates is a list of dicts with repo, number, title, body and labels.
    An issue needs a type label, otherwise there is no convention gold.
    """
    by_repo = {}
    for candidate in candidates:
        if not any(label_kind(label) == "type" for label in candidate["labels"]):
            continue
        by_repo.setdefault(candidate["repo"], []).append(candidate)

    chosen = []
    for repo in sorted(by_repo):
        pool = sorted(by_repo[repo], key=lambda item: item["number"])
        random.Random("{}:{}".format(seed, repo)).shuffle(pool)
        chosen.extend(pool[:per_repo_cap])

    chosen.sort(key=lambda item: (item["repo"], item["number"]))
    hard_budget = hard_cap
    manifest = []
    for item in chosen:
        hard = hard_budget > 0 and is_hard(item["title"], item["body"])
        if hard:
            hard_budget -= 1
        manifest.append(
            {
                "repo": item["repo"],
                "number": item["number"],
                "sha256": content_hash(item["title"], item["body"]),
                "split": split_of(item["repo"], item["number"], seed, holdout_percent),
                "hard": hard,
                "maintainer_labels": sorted(item["labels"]),
            }
        )
    return manifest


def gold_from_labels(labels, offered):
    """Reduces a label list to the shape the metrics compare.

    Only labels the labeler was offered count, so a label that the filters hide
    from the request is no gold either.
    """
    kept = [label for label in labels if label in offered and label != FALLBACK_LABEL]
    types = [label for label in kept if label_kind(label) == "type"]
    priorities = [label for label in kept if label_kind(label) == "priority"]
    topics = sorted(label for label in kept if label_kind(label) == "topic")
    return {
        "type": types[0] if len(types) == 1 else None,
        "priority": priorities[0].lower() if len(priorities) == 1 else None,
        "topics": topics,
    }


def predicted_shape(labels):
    """The same reduction for the labels the pipeline produced."""
    shape = gold_from_labels(labels, set(labels))
    shape["fallback"] = FALLBACK_LABEL in labels
    return shape


def _ratio(numerator, denominator):
    return round(numerator / denominator, 4) if denominator else None


def compute_metrics(pairs):
    """Computes the metrics over pairs of (gold, predicted, offered, label_count).

    gold and predicted come from gold_from_labels and predicted_shape.
    """
    type_hits = type_total = 0
    confusion = {}
    priority_hits = priority_total = 0
    distance_total = 0
    critical_over_calls = 0
    topic_true_positive = topic_predicted = topic_gold = 0
    fallbacks = 0
    labels_total = 0
    forbidden = 0

    for gold, predicted, offered, label_count in pairs:
        labels_total += label_count
        if predicted["fallback"]:
            fallbacks += 1
        forbidden += sum(1 for label in predicted["topics"] if label not in offered)

        if gold["type"] is not None:
            type_total += 1
            cell = (gold["type"], predicted["type"] or "none")
            confusion[cell] = confusion.get(cell, 0) + 1
            type_hits += 1 if gold["type"] == predicted["type"] else 0

        if gold["priority"] is not None:
            priority_total += 1
            priority_hits += 1 if gold["priority"] == predicted["priority"] else 0
            if predicted["priority"] is not None:
                distance_total += abs(
                    PRIORITY_ORDER[gold["priority"]] - PRIORITY_ORDER[predicted["priority"]]
                )
        if predicted["priority"] == "priority: critical" and gold["priority"] != "priority: critical":
            critical_over_calls += 1

        topic_gold += len(gold["topics"])
        topic_predicted += len(predicted["topics"])
        topic_true_positive += len(set(gold["topics"]) & set(predicted["topics"]))

    priority_with_both = sum(
        1 for gold, predicted, _, _ in pairs if gold["priority"] and predicted["priority"]
    )
    issue_count = len(pairs)
    return {
        "issues": issue_count,
        "type_accuracy": _ratio(type_hits, type_total),
        "type_confusion": {"{} -> {}".format(*cell): count for cell, count in sorted(confusion.items())},
        "priority_exact": _ratio(priority_hits, priority_total),
        "priority_mean_distance": _ratio(distance_total, priority_with_both),
        "critical_over_calls": critical_over_calls,
        "topic_precision": _ratio(topic_true_positive, topic_predicted),
        "topic_recall": _ratio(topic_true_positive, topic_gold),
        "fallback_rate": _ratio(fallbacks, issue_count),
        "forbidden_labels": forbidden,
        "labels_per_issue": _ratio(labels_total, issue_count),
    }


def stability(runs_by_issue):
    """Mean share of repeated runs that agree with the most common label set.

    runs_by_issue maps an issue key to the label lists of its repeated runs.
    """
    shares = []
    for runs in runs_by_issue.values():
        if len(runs) < 2:
            continue
        counts = {}
        for labels in runs:
            key = tuple(sorted(labels))
            counts[key] = counts.get(key, 0) + 1
        shares.append(max(counts.values()) / len(runs))
    return _ratio(sum(shares), len(shares))


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RUN_ONE = os.path.join(SCRIPT_DIR, "run-one.sh")
TRANSIENT_STATUSES = {429, 500, 502, 503, 504, 529}


def run_gh(arguments):
    """Runs gh and returns its stdout, failing loudly with the stderr text."""
    completed = subprocess.run(
        ["gh"] + arguments, capture_output=True, text=True, check=False, timeout=300
    )
    if completed.returncode != 0:
        raise RuntimeError("gh {} failed: {}".format(" ".join(arguments[:2]), completed.stderr.strip()))
    return completed.stdout


def read_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path, value):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, sort_keys=True, ensure_ascii=False)
        handle.write("\n")


def issue_path(cache_dir, repo, number):
    return os.path.join(cache_dir, "{}__{}.json".format(repo.replace("/", "__"), number))


def labels_path(cache_dir, repo):
    return os.path.join(cache_dir, "labels__{}.json".format(repo.replace("/", "__")))


def fetch_candidates(owner):
    """Lists the issues, pull requests excluded, of the public repositories."""
    repos = run_gh(
        ["repo", "list", owner, "--visibility", "public", "--no-archived", "--source",
         "--limit", "200", "--json", "name", "--jq", ".[].name"]
    ).split()
    candidates = []
    for name in repos:
        output = run_gh(
            ["api", "--paginate", "repos/{}/{}/issues?state=all&per_page=100".format(owner, name),
             "--jq", ".[] | select(.pull_request == null) | {number, title, body, labels: [.labels[].name]}"]
        )
        for line in output.splitlines():
            if line.strip():
                issue = json.loads(line)
                issue["repo"] = "{}/{}".format(owner, name)
                candidates.append(issue)
    return candidates


def fetch_repo_labels(repo):
    """Returns the repository labels as {name, description} entries.

    gh prints one JSON array per page, so the output is read value by value.
    """
    pages = run_gh(["api", "--paginate", "repos/{}/labels".format(repo)])
    decoder = json.JSONDecoder()
    labels, index = [], 0
    while True:
        while index < len(pages) and pages[index].isspace():
            index += 1
        if index >= len(pages):
            return labels
        page, index = decoder.raw_decode(pages, index)
        labels.extend({"name": item["name"], "description": item.get("description") or ""} for item in page)


def load_issue(cache_dir, entry):
    """Reads the cached text of a frozen issue and refuses an edited one."""
    issue = read_json(issue_path(cache_dir, entry["repo"], entry["number"]))
    body = issue.get("body") or ""
    if content_hash(issue["title"], body) != entry["sha256"]:
        raise RuntimeError("{} changed since it was frozen".format(issue_key(entry["repo"], entry["number"])))
    return issue["title"], body


def selected(manifest, split):
    return [entry for entry in manifest["issues"] if split == "all" or entry["split"] == split]


def command_build(args):
    candidates = fetch_candidates(args.owner)
    entries = sample_issues(candidates, args.seed, args.per_repo_cap, args.holdout_percent, args.hard_cap)
    by_key = {issue_key(item["repo"], item["number"]): item for item in candidates}
    os.makedirs(args.cache_dir, exist_ok=True)
    for entry in entries:
        item = by_key[issue_key(entry["repo"], entry["number"])]
        write_json(issue_path(args.cache_dir, entry["repo"], entry["number"]),
                   {"title": item["title"], "body": item["body"] or ""})
    for repo in sorted({entry["repo"] for entry in entries}):
        write_json(labels_path(args.cache_dir, repo), fetch_repo_labels(repo))
    write_json(
        args.manifest,
        {"version": 1, "owner": args.owner, "seed": args.seed,
         "holdout_percent": args.holdout_percent, "issues": entries},
    )
    print("froze {} issues".format(len(entries)))


def run_helper(arguments, environment=None):
    completed = subprocess.run(
        ["bash", RUN_ONE] + arguments, capture_output=True, text=True, check=False,
        timeout=180, env=dict(os.environ, **(environment or {})),
    )
    if completed.returncode != 0:
        raise RuntimeError("run-one.sh failed: {}".format(completed.stderr.strip()))
    return json.loads(completed.stdout.strip().splitlines()[-1])


def offered_labels(cache_dir, repo):
    """The label names the labeler is offered, as its own filters decide."""
    return run_helper(["offered", labels_path(cache_dir, repo)])


def classify(cache_dir, entry):
    """Runs the labeler pipeline once, retrying transient API failures."""
    title, body = load_issue(cache_dir, entry)
    with tempfile.TemporaryDirectory() as work:
        title_file = os.path.join(work, "title")
        body_file = os.path.join(work, "body")
        for path, text in ((title_file, title), (body_file, body)):
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
        for attempt in range(4):
            result = run_helper(["classify", entry["repo"], title_file, body_file,
                                 labels_path(cache_dir, entry["repo"])])
            if result.get("status") != "error" or result.get("http") not in TRANSIENT_STATUSES:
                return result
            time.sleep(2 ** attempt)
        return result


def result_key(entry, run_index):
    return "{}@{}".format(issue_key(entry["repo"], entry["number"]), run_index)


def read_results(path):
    results = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                if line.strip():
                    record = json.loads(line)
                    results[record["id"]] = record
    return results


def command_run(args):
    manifest = read_json(args.manifest)
    done = read_results(args.results)
    jobs = []
    for entry in selected(manifest, args.split):
        for index in range(args.hard_repeats if entry["hard"] else args.repeats):
            if result_key(entry, index) not in done:
                jobs.append((entry, index))
    offered = {}
    for entry in {e["repo"]: e for e, _ in jobs}.values():
        offered[entry["repo"]] = offered_labels(args.cache_dir, entry["repo"])

    def work(job):
        entry, index = job
        record = {"id": result_key(entry, index), "key": issue_key(entry["repo"], entry["number"]),
                  "run": index, "offered": offered[entry["repo"]]}
        record.update(classify(args.cache_dir, entry))
        return record

    with open(args.results, "a", encoding="utf-8") as sink, \
            concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        for record in pool.map(work, jobs):
            sink.write(json.dumps(record, sort_keys=True) + "\n")
            sink.flush()
    print("ran {} calls".format(len(jobs)))


JUDGE_PROMPT = (
    "You judge which labels the text of a GitHub issue establishes. You see exactly the "
    "title and the body that a classifier sees, nothing else. Choose a type only if the "
    "text establishes it, a priority only if the text itself supports one, and topic "
    "labels only if the text directly supports them. Use only the labels listed below. "
    "Report your answer by calling the tool report_gold."
)


def judge_request(model, title, body, offered):
    return {
        "model": model,
        "max_tokens": 4000,
        "system": JUDGE_PROMPT + "\n\nLabels:\n" + "\n".join("- " + name for name in offered),
        "tools": [{
            "name": "report_gold",
            "description": "Report the labels the issue text establishes.",
            "strict": True,
            "input_schema": {
                "type": "object",
                "properties": {
                    "type": {"type": "string", "enum": list(TYPE_LABELS) + [NO_ANSWER]},
                    "priority": {"type": "string", "enum": list(PRIORITY_ORDER) + [NO_ANSWER]},
                    "topics": {"type": "array", "items": {"type": "string", "enum": offered}},
                },
                "required": ["type", "priority", "topics"],
                "additionalProperties": False,
            },
        }],
        "tool_choice": {"type": "auto"},
        "messages": [{"role": "user", "content": "Issue title:\n" + title + "\n\nIssue body:\n" + body}],
    }


def call_messages(request):
    """Posts one Messages request and returns the decoded answer."""
    key = os.environ["ANTHROPIC_API_KEY"]
    body = json.dumps(request).encode("utf-8")
    for attempt in range(4):
        http_request = urllib.request.Request(
            MESSAGES_URL, data=body, method="POST",
            headers={"content-type": "application/json", "x-api-key": key,
                     "anthropic-version": "2023-06-01"},
        )
        try:
            with urllib.request.urlopen(http_request, timeout=120) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            if error.code not in TRANSIENT_STATUSES or attempt == 3:
                reason = error.read().decode("utf-8", "replace")[:300]
                raise RuntimeError("API answered HTTP {}: {}".format(error.code, reason)) from None
        time.sleep(2 ** attempt)
    raise RuntimeError("unreachable")


def tool_input(answer, name):
    for block in answer.get("content", []):
        if block.get("type") == "tool_use" and block.get("name") == name:
            return block["input"]
    raise RuntimeError("answer carried no {} call (stop reason {})".format(name, answer.get("stop_reason")))


def command_judge(args):
    manifest = read_json(args.manifest)
    gold = read_json(args.gold) if os.path.exists(args.gold) else {}
    offered = {}

    def work(entry):
        key = issue_key(entry["repo"], entry["number"])
        if entry["repo"] not in offered:
            offered[entry["repo"]] = offered_labels(args.cache_dir, entry["repo"])
        title, body = load_issue(args.cache_dir, entry)
        answer = tool_input(call_messages(judge_request(args.model, title, body, offered[entry["repo"]])),
                            "report_gold")
        return key, {"type": None if answer["type"] == NO_ANSWER else answer["type"],
                     "priority": None if answer["priority"] == NO_ANSWER else answer["priority"],
                     "topics": sorted(answer["topics"])}

    todo = [e for e in manifest["issues"] if issue_key(e["repo"], e["number"]) not in gold]
    for entry in todo:
        offered.setdefault(entry["repo"], offered_labels(args.cache_dir, entry["repo"]))
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        for key, value in pool.map(work, todo):
            gold[key] = value
            write_json(args.gold, gold)
    print("judged {} issues".format(len(todo)))


def pairs_for(manifest, results, gold_kind, text_gold, split):
    """Builds the metric input and the repeated runs of the hard cases.

    Every issue counts once in the metrics, with its first run. The repeated
    runs of the hard cases only feed the stability.
    """
    entries = {issue_key(e["repo"], e["number"]): e for e in selected(manifest, split)}
    pairs, hard_runs = [], {}
    for record in results.values():
        entry = entries.get(record["key"])
        if entry is None or record.get("status") != "ok":
            continue
        if entry["hard"]:
            hard_runs.setdefault(record["key"], []).append(record["labels"])
        if record["run"] != 0:
            continue
        offered = set(record["offered"])
        if gold_kind == "text":
            if record["key"] not in text_gold:
                continue
            raw = text_gold[record["key"]]
            gold = {"type": raw["type"], "priority": raw["priority"], "topics": raw["topics"]}
        else:
            gold = gold_from_labels(entry["maintainer_labels"], offered)
        pairs.append((gold, predicted_shape(record["labels"]), offered, len(record["labels"])))
    return pairs, hard_runs


def command_report(args):
    manifest = read_json(args.manifest)
    results = read_results(args.results)
    text_gold = read_json(args.gold) if args.gold else {}
    failed = sum(1 for record in results.values() if record.get("status") != "ok")
    report = {"calls": len(results), "not_ok": failed}
    for kind in ("convention", "text"):
        if kind == "text" and not text_gold:
            continue
        pairs, hard_runs = pairs_for(manifest, results, kind, text_gold, args.split)
        report[kind] = compute_metrics(pairs)
        report[kind]["hard_case_stability"] = stability(hard_runs)
    print(json.dumps(report, indent=2, sort_keys=True))


def parse_args(argv):
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    build = sub.add_parser("build", help="sample and freeze the evaluation set")
    build.add_argument("--owner", required=True)
    build.add_argument("--manifest", required=True)
    build.add_argument("--cache-dir", required=True)
    build.add_argument("--seed", default="labeler-eval-1")
    build.add_argument("--per-repo-cap", type=int, default=30)
    build.add_argument("--holdout-percent", type=int, default=33)
    build.add_argument("--hard-cap", type=int, default=40)

    judge = sub.add_parser("judge", help="ask the referee for the text-only gold")
    judge.add_argument("--manifest", required=True)
    judge.add_argument("--cache-dir", required=True)
    judge.add_argument("--gold", required=True)
    judge.add_argument("--model", default="claude-opus-5-5")
    judge.add_argument("--workers", type=int, default=4)

    run = sub.add_parser("run", help="run the labeler pipeline over the set")
    run.add_argument("--manifest", required=True)
    run.add_argument("--cache-dir", required=True)
    run.add_argument("--results", required=True)
    run.add_argument("--repeats", type=int, default=1)
    run.add_argument("--hard-repeats", type=int, default=5)
    run.add_argument("--split", choices=("dev", "holdout", "all"), default="dev")
    run.add_argument("--workers", type=int, default=4)

    report = sub.add_parser("report", help="compute the metrics")
    report.add_argument("--manifest", required=True)
    report.add_argument("--results", required=True)
    report.add_argument("--gold")
    report.add_argument("--split", choices=("dev", "holdout", "all"), default="dev")

    return parser.parse_args(argv)


COMMANDS = {"build": command_build, "judge": command_judge, "run": command_run, "report": command_report}


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    COMMANDS[args.command](args)


if __name__ == "__main__":
    main()
