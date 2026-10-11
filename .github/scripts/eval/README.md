# Evaluation of the AI issue labeler

A frozen set of issues and the tools to measure the labeler on it. A change to
the prompt, a threshold or the model is judged on the same issues every time
instead of on a new small sample.

## What is frozen

`.github/eval/labeler-set.json` lists issues of the public repositories of one
account. For each issue it holds the repository, the number, a hash of the title
and the body, the split (`dev` or `holdout`), a flag for hard cases and the
labels the maintainers set. The texts are not in the repository. They sit in a
cache directory that `build` fills. `run` and `judge` refuse an issue whose hash
no longer matches, so an edited issue never changes a result unnoticed.

The holdout is untouched while a change is developed. Run it once for a final
check, never to tune.

## Two kinds of gold

- **Convention**: the labels the maintainers set, reduced to the labels the
  labeler is offered. This is what the workflow should end up with after the
  conventions of each repository.
- **Text**: what the title and the body alone establish.
  `.github/eval/labeler-gold-text.json` holds the answers of a referee model
  that sees the same input as the labeler and nothing more.

## Commands

```bash
labeler_eval.py build  --owner OWNER --manifest MANIFEST --cache-dir CACHE
labeler_eval.py judge  --manifest MANIFEST --cache-dir CACHE --gold GOLD
labeler_eval.py run    --manifest MANIFEST --cache-dir CACHE --results RESULTS --split dev
labeler_eval.py report --manifest MANIFEST --results RESULTS --gold GOLD --split dev
```

`judge` and `run` need `ANTHROPIC_API_KEY`. `run` goes through the library of
the workflow (`ai-issue-labeler.sh`) for the request, the confidence step and the
guard, so a measurement uses the code that runs in production. Hard cases are run
several times. `run` continues an interrupted results file.

`build` samples with a seed. The same seed gives the same set, and an issue keeps
its split when other issues are added.

## Metrics

Every issue counts once, with its first run.

- Type: accuracy and a confusion matrix.
- Priority: exact accuracy, the mean distance and the number of over-calls of
  `critical`.
- Topics: precision and recall.
- The rate of the `needs-triage` fallback, the labels outside the offered set and
  the labels per issue.
- Stability: the mean share of the repeated runs of a hard case that agree with
  its most common label set.

The numbers of the two gold kinds differ on purpose. A gap between them shows
where the maintainers follow a convention that the text does not carry.
