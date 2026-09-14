# Choosing VoiceInk's local rewrite model — the brief for the agent on the new Mac

Hand this to the agent running **on the target machine** (Claude Code, Copilot CLI, or any agent
with a shell). It is written to be pasted whole. It assumes nothing about the hardware, because
the first command reads it.

Your job is to leave this Mac with **either** a local rewrite model that has been *measured* fit,
**or** AI enhancement deliberately switched off. Both are acceptable outcomes. Installing a model
that was never scored is not.

---

## Why this is not "pick the biggest model that fits"

VoiceInk's AI enhancement rewrites dictated speech before it is pasted into whatever the user was
typing into. Its failure modes are silent and they land in the user's documents:

- it **answers** a dictated question instead of rephrasing it, pasting the answer into the document;
- it **drops** a trailing clause of what was said, with nothing to indicate loss;
- it **invents** detail that was never spoken — a date, an AM/PM qualifier, a number;
- it **leaks its own chain of thought** into the output.

None of these is visible in a model's parameter count, its benchmark scores or its download size.
All four are caught by running the model against `assets/model-gate.sh`. That is why every step
below ends in a measurement, and why no step accepts a recommendation on trust — including the
recommendations in this file.

---

## Step 1 — Read the machine. Do not guess any of it.

```
bash assets/model-advisor.sh
```

It writes nothing and installs nothing. It prints this Mac's chip, GPU cores, unified memory,
macOS version, free disk, power source, whether ollama is present, and — the number that decides
everything — the **memory budget for a model**, which is *not* the machine's RAM. Add `--json` if
you would rather parse than read.

Three corrections it applies, each of which a hand-rolled estimate gets wrong:

1. the GPU gets about **75%** of unified memory, not all of it;
2. macOS, a browser and VoiceInk-while-transcribing measurably occupy **~6.6 GiB**, and VoiceInk
   is bimodal — 22 MB idle, ~1.98 GB the instant the hotkey is pressed, which is exactly when the
   rewrite model also needs to be resident;
3. a model's resident size is weights **plus context**, and ollama sizes context from total VRAM
   unless it is pinned. This repo pins `num_ctx 4096` in a Modelfile, which is what makes a
   table of on-disk sizes meaningful at all.

## Step 2 — If this is macOS 27 or newer, check for a model that needs no download

```
fm respond "say ok"
```

macOS 27 preinstalls Apple's on-device Foundation Models with an `fm` CLI. VoiceInk can call it
through its **Local CLI** provider — no ollama, no 5–7 GB download, no model licence to review,
and nothing leaves the machine. For a corporate Mac that is a materially easier approval than any
downloaded model.

Two things to establish before preferring it, and they are the whole risk:

- **Is Apple Intelligence actually enabled?** It is a ~7 GB opt-in the user must switch on in
  System Settings. No script can flip it. If `fm` errors with a not-enabled condition, this path
  is closed until the user acts — say so and move on rather than waiting.
- **Does it refuse ordinary dictation?** Apple's guardrails can return a *refusal sentence with a
  200 status*, which VoiceInk would paste into the document verbatim. Apple's own guidance says
  you may not be able to tell a refusal from a normal answer programmatically. So score it with
  the same gate you would use on any other model (Step 4) before trusting it, and prefer a
  schema-constrained call if one is available, because that turns a silent refusal into a
  catchable error.

## Step 3 — Choose candidates from what fits, in the order the advisor printed

The advisor prints an `status` column, and it is the column that matters:

| status | what it means |
|---|---|
| `measured-good` | scored PASS against this repo's gate this month |
| `contested` | the repo asserts it and a later probe disagreed — **re-measure, do not assume** |
| `unmeasured` | catalogue-verified, never scored. A candidate, never a recommendation |

Take them in order. Do not substitute a model you happen to know about: if you did not read the
tag out of the advisor's output or out of the live registry, you do not know that it exists.
Before pulling any tag you were not given, confirm it resolves:

```
curl -sS -o /dev/null -w '%{http_code}\n' https://registry.ollama.ai/v2/library/<name>/manifests/<tag>
```

`200` means it exists; `404` means you invented it.

## Step 4 — Measure. This is the step that cannot be skipped or predicted.

```
bash bootstrap.sh --only rewrite_model --bench <tag>
```

It derives a temporary model with the repo's sampling parameters baked in, runs the acceptance
gate against VoiceInk's real system prompt, prints a verdict, and removes the temporary model.
It changes no state and never touches the receipt.

**Read the exit code, and quote the `BENCH_RESULT=` line in your report:**

| exit | `BENCH_RESULT` | what to do |
|---|---|---|
| 0 | `PASS` | the model is fit — install it |
| 1 | `REJECTED` | try the next candidate. The `WHY:` line above names the clause that convicted it |
| 2 | `NOT-MEASURED` | nothing was measured. **This is not a failure of the model.** Fix the cause (no ollama, no server, disk, a bad tag) and re-run |

A `REJECTED` verdict is a successful measurement. Report it as a result, never as an error.

## Step 5 — Install the first candidate that passed

```
bash bootstrap.sh --only rewrite_model --model <tag>
```

If none passed, install nothing and say so. A Mac with AI enhancement off is a working Mac; a Mac
with a model that invents text is a liability, and the user will not notice until it has already
happened in something that mattered.

## Step 6 — The step no script can do, and it is structural

VoiceInk resolves its AI provider **per mode**, falling back to the first *connected* provider in
the enum's declaration order — where several cloud providers sit ahead of Ollama. So if any cloud
API key survives on this machine, it silently wins the fallback and the local model you just
installed is never called. The user must open **VoiceInk → Settings → AI Models**, select the
Ollama provider and the installed model, and — if a cloud key is still present — pin Ollama on the
active mode under **Settings → Modes**.

Name that gesture explicitly in your report. Do not report success without it.

---

## What to put in your report

1. The advisor's machine line and the computed budget.
2. Every candidate you measured, with its exit code and `BENCH_RESULT` line. Including the rejections.
3. What you installed, or that you deliberately installed nothing, and which measurement decided it.
4. The Step 6 gesture, as the one thing still outstanding.

## Questions to bring back rather than answer yourself

These are judgment calls that belong to the user, not to you:

- **Apple Intelligence is off and this is macOS 27+.** Enabling it is a ~7 GB download and a
  privacy posture. Ask; do not assume.
- **Nothing fits the budget.** Confirm that AI enhancement stays off, rather than installing the
  smallest thing that runs.
- **This is an Intel Mac.** It has the memory but not the GPU; expect the gate to reject on
  latency. Confirm before spending a multi-GB download to prove it.
- **The only candidate that passes is `contested` or `unmeasured`.** Say which, and let the user
  decide whether one passing run is enough for their documents.
- **A corporate policy question:** ollama's server contacts `ollama.com` every few hours with a
  stable signed device identifier. `OLLAMA_NO_CLOUD=1` disables it. (`OLLAMA_NO_TELEMETRY`, which
  is the popular answer on the web, **does not exist** — do not offer it as a mitigation.)
