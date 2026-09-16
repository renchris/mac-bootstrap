---
name: handoff-continuation
description: Hand a session's live state to a successor session without losing what only this session knows. Use when a session is running low on context, when work must continue in a new session or on another machine, or when the user asks for a handoff, a continuation brief, or a summary to resume from.
---

<!-- mac-bootstrap: installed skill · replaced on update · copy this directory under another name before editing it -->

# Handing a session on

A successor starts with the repository and nothing else. So the only thing worth writing
down is **what a successor reading only the disk would get wrong.**

## The test, before you write a word

Ask: *what would someone who has the code, the git log and the open files still get wrong?*

- A concrete answer — an approach that was tried and rejected and why, a measurement that
  contradicts the obvious reading, a preference the user stated in words, a constraint that
  is true but written nowhere — is the handoff. Write those.
- No concrete answer means there is nothing to hand off. Say the work is on disk and stop.

Everything reconstructible is noise. Do not restate the file tree, re-summarise the diff, or
list what `git log` already says. A bridge document that repeats the repository costs the
successor context and teaches them nothing.

## Persist first, hand off second

The order is not cosmetic. Write the durable things to their durable homes **before** you
write the bridge:

1. Commit finished work, with a message that carries the *why*.
2. Put design decisions and rejected approaches in the plan or design document.
3. Only then write the bridge, which points at those and adds what has no home.

A fact that lands in the bridge and nowhere else dies when the bridge is deleted.

## What the bridge contains

Six short sections, in this order, and omit any that is empty:

| Section | The one thing it carries |
|---|---|
| Goal | the end state, in one sentence, stated so it can be judged true or false |
| State | what is done, what is verified, what is merely written |
| Next | the single next action, phrased as a verb |
| Knowledge | the dead ends, the measurements, the constraints — the part that exists nowhere else |
| Blocked | anything waiting on a decision or on a person, named |
| Receipts | commit hashes, document paths, the commands that prove the state |

Keep it to one screen. A long bridge is a sign the work should have been persisted instead.

## Two failure modes to avoid

- **A summary in place of a handoff.** A recap of the session narrates what happened; a
  handoff supplies what is needed next. They are different documents.
- **Handing off in the middle of a thought.** If a judgment is half-formed, finish it and
  write it down, then hand off at the seam. Cutting mid-thought is the one case where the
  successor genuinely cannot recover the value.
