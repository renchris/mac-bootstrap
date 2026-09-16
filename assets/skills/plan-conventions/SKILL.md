---
name: plan-conventions
description: Conventions for writing and updating a plan, design or roadmap document so decisions accumulate across sessions instead of being overwritten. Use when creating or editing any plan, design, roadmap or phased implementation document, or when adding a phase to one that already exists.
---

<!-- mac-bootstrap: installed skill · replaced on update · copy this directory under another name before editing it -->

# Plan documents

A plan document is not a snapshot of the current intention. It is the **accumulated record of
every decision taken so far**, and its value comes almost entirely from the parts that are
already finished — the reasons, the rejected alternatives, the things that turned out not to
work. Those cost real time to learn and cannot be re-derived from the code.

## The rule that matters most: INTEGRATE, never overwrite

When you change a plan document, edit the section you are changing and leave everything else
exactly as it is.

| Action | How |
|---|---|
| Update a section | a targeted edit of that section alone |
| Add a section | append it after the last related one |
| Rewrite the whole file | **never** — unless you are creating it from scratch |
| Restructure it | propose the new structure and get agreement first |

A full-file rewrite looks like an update and is a deletion. It is the single most expensive
mistake available in a plan document, because nothing about the result announces that history
is gone.

## Completed sections compact; upcoming sections expand

The two halves of a plan are edited in opposite directions.

**Completed work compacts.** Once a phase is done, replace its step-by-step detail with what
survives it:

- what was learned, including anything that turned out to be false
- the commit hashes that carry the change
- what is still broken or deliberately left undone

Drop the granular steps. Keep every "why". A one-line rationale for a decision taken three
months ago is worth more than a page describing how it was carried out.

**Upcoming work expands.** Before a phase is executed it should carry enough that someone
else could do it: the files it touches with line ranges, the decisions already settled, the
trade-offs considered and the one chosen, and the definition of done.

## Never delete

- historical decisions, and the reasoning behind them
- any line beginning "Why:" — those are the whole point
- known issues, including ones that are no longer reproducible
- a section that is now wrong; mark it superseded and say what replaced it

Being wrong is information. A plan that records a corrected belief teaches the next reader
not to try it again; one that silently deletes the belief guarantees they will.

## Shape

State the end state before the steps. Number phases, give each a definition of done that can
be judged true or false, and record who or what each phase is blocked by. If the plan has
several independent pieces of work, say so explicitly at the top, including which pieces can
run at the same time and which must be serialised — that is a decision, and it belongs in the
record like any other.
