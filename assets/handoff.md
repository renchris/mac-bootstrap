---
name: handoff
description: Hand this session to a successor without losing anything, autonomously and with no human in the loop. Trigger on "/handoff", "hand off", "hand this off", "recycle the session", "we're running out of context", or when the context fill is past the threshold. Freeze a bridge file with `$HOME/.mac-bootstrap/bin/agent-handoff capture "<the ONE next step>"`, EDIT it until the frozen scope, what is done and verified, the one next step, the key files and the dead ends are all true, then run `$HOME/.mac-bootstrap/bin/agent-handoff fire --goal "<the end state>"`, which launches the successor, PROVES it engaged, and only then retires this pane. If it cannot prove engagement it holds this pane and says so. The bridge is the deliverable — a successor that has to re-derive anything has been handed nothing.
argument-hint: "[the one next step]"
---

Hand this session's work to a successor.

*Portability note: in Claude Code this file is a real typed `/handoff` at
`$HOME/.claude/commands/handoff.md`. Copilot CLI 1.0.83 has **no** mechanism to register a
`/name` — its slash set is a hardcoded array — so the same file installs as a personal skill at
`$HOME/.copilot/skills/handoff/SKILL.md` and is asked for in English ("hand off this session").
**Only the frontmatter `description` is measured reaching Copilot's context** — a planted body
token scored 0 while a description token scored 1 — so the description above carries the trigger
and the gist on purpose. The Copilot **user-tier** arm is **UNPROVEN**: the measurement behind it
was taken at the repo tier, and `$HOME/.claude/skills` is measured NOT read by Copilot. Probe it
on the target with `/env` before relying on it.*

## 1. Read the current state

Run `$HOME/.mac-bootstrap/bin/agent-handoff status`. It prints the bridge path, the context fill,
and the last succession's phase. (The full path is deliberate: nothing in this bootstrap edits
your shell's PATH, so the bare name is not assumed to resolve.
`alias agent-handoff=$HOME/.mac-bootstrap/bin/agent-handoff` if you want the short form.)

If the fill reads `UNKNOWN`, that is the honest answer and **not** a reason to stop — it means no
statusline has written telemetry for this session. It is never `0%`. Decide by judgment.

## 2. Write the bridge

Run `$HOME/.mac-bootstrap/bin/agent-handoff capture "<the ONE next step>"`, then **edit the file
it prints** until every section below is true. INTEGRATE — never overwrite a section that already
holds a decision. The command is idempotent: re-running it replaces the one next step and files
the one it displaced under `## Previously next`, and touches nothing you wrote by hand.

- **`Scope (frozen):`** — the contract this work is measured against, one line. If the file
  already carries a frozen scope, keep it **verbatim**; a scope that drifts is not frozen.
- **`## Done`** — what is finished AND verified, each with its evidence (a sha, the gate's own
  output). "Implemented" is not "verified".
- **`## Next`** — the ONE next step, as an imperative with a path.
- **`## Key files`** — `path:line — why it matters`. Five at most.
- **`## Do not re-walk`** — every dead end, with the reason it is dead. **This is the section
  that pays for the handoff.** A successor without it repeats your worst hour, and it is the one
  thing in the file that exists nowhere else — everything above it can be re-derived from the
  repo, and this cannot.

Do not write anything a successor could get from `git log` or from running the gate. Name the
command instead.

## 3. Fire

```
$HOME/.mac-bootstrap/bin/agent-handoff fire --goal "<one measurable end state> — proven by <the command the successor runs and prints>; do not <the constraint>"
```

That one command does the whole succession, with nothing typed and nobody watching:

1. **preflights** the terminal driver, the agent binary, the login, and the goal — and refuses
   BEFORE anything irreversible if any of them is not ready;
2. **seeds** the successor's first-run state (theme, per-directory workspace trust) and writes the
   `/goal` into a transcript the product restores at session init, so the goal is armed before the
   successor's first turn and the brief rides the same launch;
3. **launches** the successor with the whole brief in `argv` — never as keystrokes, because a tty
   in canonical mode silently DELETES a line over 1024 bytes and still reports success;
4. **proves** the successor engaged, by a token only a model that read the prompt could produce;
5. **retires this pane** — and only then.

**If it cannot prove engagement it does not retire anything.** It exits 3, says
`⛔ ENGAGEMENT NOT PROVEN`, names the command that shows you the successor, and leaves a resumable
state. That is a correct outcome, not a failure: losing a context is unrecoverable and an extra
idle pane is not.

Useful flags: `--dry-run` (resolve and seed, launch nothing), `--no-retire` (prove, then leave this
pane up), `--budget <seconds>`, `--cwd <dir>` for a successor in a different worktree,
`--agent copilot`.

**Before the first ever succession on a machine**, run
`$HOME/.mac-bootstrap/bin/agent-handoff doctor`. It says whether this box can do it and names the
one-time human gestures — an OAuth login per config-dir path, and on iTerm2 a single macOS
Automation consent click. There is no per-recycle gesture.

## 4. Close

Report what `fire` actually returned, and nothing more:

- **exit 0** — the successor is proven engaged and this pane is being retired. Say which bridge
  holds the work and what the successor was told to do.
- **exit 3** — the successor is NOT proven. This pane is still yours and still holds the context.
  Relay the reason verbatim (`AUTHFAIL`, `timeout-unproven`, `successor-gone`), give the operator
  the attach command it printed, and keep working or wait — do not retry blindly, and do not
  retire anything.
- **exit 2 / 4 / 5** — refused, failed to launch, or another driver owns that succession. Nothing
  moved. Relay the reason.

**Never claim the successor is working unless `fire` returned 0** — that verdict is the only thing
in this flow that observed it.
