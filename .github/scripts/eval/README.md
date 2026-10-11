# Evaluation of the AI issue labeler

A frozen set of issues and the tools to measure the labeler on it. A change to
the prompt, a threshold or the model is judged on the same issues every time
instead of on a new small sample.

## What is frozen

`.github/eval/labeler-set.json` lists open and closed issues of the public
repositories of one account, archived repositories and forks left out. For each
issue it holds the repository, the number, a hash of the title and the body, the
split (`dev` or `holdout`), a flag for hard cases and the labels the maintainers
set. The texts are not in the repository. They sit in a
cache directory that `build` fills. `judge` refuses an issue whose hash
no longer matches and `run` records such a call as failed, so an edited issue never
changes a result unnoticed.

Every command that reads the manifest refuses an entry whose repository belongs to
another owner than the one frozen in it, because the tool reads with your own gh
login and a pull request may edit the manifest.

The label side is not frozen. The label names and descriptions of a repository are
read from GitHub when the cache is filled, and each result stores the names it was
offered. A label renamed or re-described after the label lists were cached changes
what `run` offers once the cache is filled again, so compare runs only while the
cached label lists are the same.

Hard cases are picked in the order of the sorted issues until the cap is used up,
so they sit in the first repositories by name. The stability numbers describe those
repositories, not the whole set.

The holdout is untouched while a change is developed. Run it once for a final
check, never to tune.

## Two kinds of gold

- **Convention**: the labels the maintainers set, reduced to the labels the
  labeler is offered. This is what the workflow should end up with after the
  conventions of each repository.
- **Text**: what the title and the body alone establish.
  `.github/eval/labeler-gold-text.json` holds the answers of a referee model
  that sees the same title and body as the labeler and the names of the offered
  labels, without their descriptions and without the repository name.

## Commands

```bash
labeler_eval.py build  --owner OWNER --manifest MANIFEST --cache-dir CACHE
labeler_eval.py fetch  --manifest MANIFEST --cache-dir CACHE
labeler_eval.py judge  --manifest MANIFEST --cache-dir CACHE --gold GOLD
labeler_eval.py run    --manifest MANIFEST --cache-dir CACHE --results RESULTS --split dev
labeler_eval.py report --manifest MANIFEST --results RESULTS --gold GOLD --split dev
```

The tool is Python. `run-one.sh` is the only shell file of the tool, a thin shim, because the
labeler library it has to measure is a bash library.

`fetch` fills the cache on a fresh checkout from the committed manifest and fails
when an issue was edited since it was frozen. `build` is for a new set and
refuses to replace an existing manifest unless `--force` is given.

The referee answers `none` where the text establishes no type or no priority.
That counts as an answer, so a labeler that adds a type there is wrong, while an
issue without any convention gold for a field is left out of that metric.

`judge` skips an issue that already has an answer in the gold file. After `build
--force` has frozen a new set, delete the old gold file first, otherwise an edited
issue keeps the answer of its earlier text.

The results file is tied to the frozen set in the same way. After `build --force`,
start a new results file, because a call that already ended ok for an issue number
is not run again. The cache directory holds the label lists unchecked, so keep it
private to your user.

`judge` and `run` need `ANTHROPIC_API_KEY`. `run` goes through the library of
the workflow (`ai-issue-labeler.sh`) for the request, the confidence step and the
guard, so a measurement uses the code that runs in production. Hard cases are run
several times. `run` continues an interrupted results file and runs a call again
whose last result was not ok.

`build` samples with a seed. The same seed on an unchanged set of issues gives the
same sample, and an issue keeps its split when other issues are added. Only the
frozen manifest is stable once the issues of the account change. An issue with two
type labels stays in the set, but it has no convention gold for the type.

## Metrics

Every issue counts once, with its first run. An issue whose first run did not end
ok is left out. The report counts as `not_ok` every call of the chosen split whose
latest result did not end ok, whatever its run.

- Type: accuracy and a confusion matrix.
- Priority: exact accuracy, the mean distance and the number of over-calls of
  `critical`.
- Topics: precision and recall.
- The rate of the `needs-triage` fallback and the labels per issue. A label
  outside the offered set is not measured, because the request never offers one
  and the pipeline drops it.
- Tokens: the input and output tokens of the latest result of every call. A call
  that was run again counts with its last answer only, so the sum is a floor for
  the cost of a run.
- Stability: the mean share of the repeated runs of a hard case that agree with
  its most common label set.

The numbers of the two gold kinds differ on purpose. A gap between them shows
where the maintainers follow a convention that the text does not carry.
