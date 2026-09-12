# Patch for `stop.sh` — ARM R, the self-recycle block

**Owner of the file being patched: m3.** m4 owns `agent-handoff`, `handoff.md` and
`m4_handoff.sh` and does not edit `assets/hooks/stop.sh`, so the arm arrives as this document
instead. Everything it needs already exists: `agent-handoff recycle-due` is installed by m4 and
carries the whole predicate, so the patch below is a guard and an emit, not logic.

---

## Why the arm has to exist at all

`stop.sh`'s arm B renders the context advisory into **`systemMessage`**, and that is correct —
`systemMessage` is the only Stop field that does not extend the turn. But it has a consequence
the advisory's own wording does not survive: **`systemMessage` reaches the OPERATOR and never the
model.** The text says *"…then run /handoff"*, and the only reader who can run `/handoff` is the
one who cannot see it.

So deliverable 2c's *self*-recycle is not delivered by arm B. At Stop there is exactly one channel
that reaches the model — `decision:"block"`, whose `reason` becomes the next turn — and that is
what this arm uses. It is the same mechanism arm C already uses for uncommitted work; this is the
second thing worth spending a forced turn on.

## Where it goes, and why there

**Immediately after arm C's emit-and-exit, immediately before the non-blocking render.** Only one
hook can usefully block, so the order is load-bearing and must be visible in the file:

> A session at 82 % fill **with uncommitted work of its own** must commit first. A handoff written
> over uncommitted work strands it on a disk the successor will not look at.

With arm C first that sequencing is emergent rather than coded: arm C blocks, the session commits,
the next organic Stop finds arm C quiet and arm R fires. Putting arm R first would invert it.

**Anchor.** Insert between these two existing lines:

```bash
  exit 0
fi

# ── no block: render the ledger, never extend the turn ────────────────────────────────────────
```

## The patch

```bash
# ── ARM R: bounded self-recycle. THE ONLY ARM THAT REACHES THE MODEL WITH THE RECYCLE. ────────
# Arm B has already rendered the fill into systemMessage, which reaches the OPERATOR and never
# the model — so the sentence "then run /handoff" is, on that channel, addressed to the one
# reader who cannot act on it. `decision:"block"` is the only Stop field the model sees, and this
# is the arm that uses it for the handoff.
#
# ALL THE JUDGMENT LIVES IN `agent-handoff recycle-due`, which is m4's and is fixture-tested
# there: it reads the same telemetry file arm B reads, applies the same freshness rule, and
# returns rc 1 IN SILENCE for every kind of ignorance — no telemetry, a stale row, a null fill, an
# unknown session, or the library missing. It never blocks on not-knowing. Reproducing any of that
# here would make two implementations of one rule, which is two rules.
#
# FOUR BOUNDS, and only the first two are new:
#   B1  stop_hook_active — inherited; it is already the first statement in this file.
#   B2  the BOOTSTRAP_STOP_MAX counter — shared with arm C, so the two arms cannot between them spend
#       more forced turns than the file's one documented budget.
#   B4  a PER-SESSION LATCH inside recycle-due: a session is asked to hand itself off AT MOST
#       ONCE, ever, however many times this hook runs. Stronger than a counter, because the
#       demanded action (a handoff) does not lower the fill — an un-latched arm would re-fire on
#       every subsequent stop for the rest of the session, which is the runaway shape.
#   B5  no agent-handoff, not executable, or a non-zero rc ⇒ the arm does not exist this turn.
# FAILS OPEN at every seam, like everything else in this file.
AH="$BOOTSTRAP_STATE_DIR/bin/agent-handoff"
if [ -x "$AH" ] && [ "$CNT" -lt "$MAX" ] \
   && R_REASON="$("$AH" recycle-due "$SID" 2>/dev/null)" && [ -n "$R_REASON" ]; then
  printf '%s %s' "$SID" "$(( CNT + 1 ))" > "$CNT_F" 2>/dev/null || true
  printf '%s\n' "$RUNG $LEDGER" > "$BOOTSTRAP_STATE_DIR/last-ledger" 2>/dev/null || true
  R_SYS="⟳ pb-stop [$(( CNT + 1 ))/$MAX]: context past ${BOOTSTRAP_CONTEXT_THRESHOLD_PCT:-70}% — handing off. $RUNG${LEDGER:+ — $LEDGER}"
  # The reason text CONTAINS DOUBLE QUOTES (it quotes the capture command back at the model), so
  # the no-jq arm must escape rather than interpolate. A Stop hook that emits malformed JSON has
  # its whole chain ignored, silently — and the one message that most needs to survive a missing
  # jq is the one telling the session to save itself.
  if R_JQ="$(bootstrap_jq)"; then
    "$R_JQ" -nc --arg r "$R_REASON" --arg s "$R_SYS" \
            '{decision:"block",reason:$r,systemMessage:$s}'
  else
    printf '{"decision":"block","reason":"%s","systemMessage":"%s"}\n' \
      "$(bootstrap_json_escape "$R_REASON")" "$(bootstrap_json_escape "$R_SYS")"
  fi
  exit 0
fi
```

`BOOTSTRAP_STATE_DIR`, `CNT`, `MAX`, `CNT_F`, `SID`, `RUNG` and `LEDGER` are all already in scope at that point
in `stop.sh`; the patch introduces `AH`, `R_REASON`, `R_SYS` and `R_JQ` and nothing else.

## Measured — 9 arms, run against the real installed `agent-handoff`

The harness is `stop.sh`'s own skeleton (B1 + the counter + a stub arm A) with the block above
spliced in at the position above, driven by real telemetry files and a real `install_m4_handoff`.
**The harness is generated by extracting the block from THIS DOCUMENT**, so the matrix cannot
drift from the text you are about to paste — the first run of this matrix was taken against a
hand-copied approximation, and it differed from the shipped block in three lines:

```sh
awk 'BEGIN{n=0} /^```bash$/{n++; if(n==2){f=1}; next} /^```$/{f=0} f' assets/handoff-stop-arm.md
```

| # | case | want | got |
|---|---|---|---|
| R1 | 82 % fresh, first stop | `decision:"block"`, reason names the fill and the command | ✅ blocked; `⟳ pb-stop [1/3]` |
| R2 | same session, second stop | **no `decision` key** (the latch) | ✅ `{"systemMessage":"(no block)"}` |
| R3 | `stop_hook_active:true` | total silence, rc 0 | ✅ |
| R4 | **NEG** 12 % fill | no block | ✅ |
| R5 | **NEG** stale telemetry at 95 % | no block | ✅ |
| R6 | **NEG** `used_pct: null` | no block — a null is not 0 % | ✅ |
| R7 | **NEG** `agent-handoff` absent | rc 0, no block | ✅ |
| R8 | **NEG** budget already at 3/3 | no block | ✅ |
| R9 | no jq, reason contains `"` | still **valid JSON**, quotes intact | ✅ `decision=block`, `"<the one next step>"` survived |

Observed R1 output, verbatim:

```
reason:  Context is at 82%, past the 70% line. Persist what this context holds that the disk does not…
sysmsg:  ⟳ pb-stop [1/3]: context past 70% — handing off. CLEAN — clean, nothing unpushed on main
```

Six of the nine are negative arms on purpose. The refuted design in this corpus failed precisely
because its detector could only ever say *yes*; an arm that forces a turn has to be able to say no
about each of its inputs separately, and R4–R8 are those inputs one at a time.

## What this arm still cannot do

It fires **once per session**, from a fill number **someone else** measured. If m1's statusline is
not installed, `recycle-due` returns silence forever and this arm never fires at all — correctly,
and invisibly. That is the seam to check first if self-recycle never happens on the target:
`$HOME/.mac-bootstrap/bin/agent-handoff status` prints `UNKNOWN (<reason>)` and names which of the
two halves is missing.
