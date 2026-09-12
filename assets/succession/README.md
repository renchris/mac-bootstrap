# The succession engine

`agent-handoff fire` closes the agent out, re-opens it with the right command and parameters,
inserts the initial prompt **and** the goal prompt, autonomously, fault-tolerantly, with **zero
human in the loop**.

One-time setup gestures exist and are named below. There is **no per-recycle gesture**.

```
agent-handoff doctor                 can this machine do it, and what is still human
agent-handoff capture "<next step>"  freeze the bridge
agent-handoff fire --goal "<cond>"   run the succession
agent-handoff resume [<id>]          re-enter a succession whose driver was killed
```

---

## 1. THE INVARIANT

> **The predecessor retires ONLY after the oracle proves the successor engaged. On timeout the
> predecessor SURVIVES, says what happened, and leaves a resumable on-disk state.**

The two errors are not the same size. Retiring too early destroys a context that cannot be
rebuilt — the work is gone and nobody finds out until someone opens a husk. Retiring too late
costs **one idle pane**, which a human closes in a second and which the `TIMEOUT_UNPROVEN` line
names explicitly. An asymmetric loss function with an unbounded arm and a one-pane arm has exactly
one defensible bias.

The corollary is the part people get wrong: **"unknown" must resolve to the SAFE side, never to
the cheap side.** That is why the timeout writes its own terminal phase rather than falling
through, why a read error is `CANNOT-TELL` and not `NO`, and why the oracle may never be process
liveness — process liveness answers "unknown" as "yes".

Supporting invariants, each with the arm that tests it (`e2e` column = the live test that produced
it, see §7):

| | Invariant | How it is enforced | Arm |
|---|---|---|---|
| **I1** | `RETIRED` is reachable only from `ENGAGED` | the phase machine | 2,3 |
| **I2** | the brief's checksum is frozen at plan and re-verified immediately before launch | `brief_sha` | 7 |
| **I3** | exactly one successor per id, ever | `launch.lock.d` (mkdir, atomic) | 5 |
| **I3b** | exactly one driver per id | `run.lock.d` + holder-pid liveness | 6 |
| **I4** | timeout ⇒ the predecessor is explicitly NOT retired | `decide` returns HOLD | 2,3 |
| **I5** | every state write is atomic | temp + `rename(2)`, validated before it lands | — |
| **I6** | the launcher's rc is NOT liveness | `spawn` re-reads the session 2 s later | 4 |
| **I7** | preflight refuses BEFORE the first irreversible step | `fire` step 2 | 8 |
| **I8** | the brief never travels as keystrokes | argv + a generated launcher | 0 |
| **I9** | the terminal phase is written BEFORE the pane is closed | `RETIRED` then `close-self` | 1 |

---

## 2. THE STATE MACHINE

State lives on disk under `$BOOTSTRAP_STATE_DIR/handoff/<id>/`, never in the driver process, so a
`kill -9` mid-flight loses nothing.

```
            ┌──────────── resume re-enters at the recorded phase ─────────────┐
            ▼                                                                 │
 plan ─► PLANNED ─► (preflight) ─► SEEDED ─► LAUNCHING ─► LAUNCHED ─► ENGAGED ─┤
            │            │            │          │            │         │      │
            │            │            │          │            │         │      │
            │      FAILED_PREFLIGHT   │    FAILED_LAUNCH      │   write RETIRED │
            │      (nothing moved)    │  (rc 0 but the        │         ▼      │
            │                   FAILED_SEED   session is      │   close-self   │
            │                                 already gone)   │         ▼      │
            │                                                 │  (detached reaper
            │                                                 │   verifies) ► DONE
            └──────────────────────── TIMEOUT_UNPROVEN ◄───────┘
                                      predecessor STAYS UP, rc 3, resumable
```

Files per succession:

| file | what |
|---|---|
| `state.json` | phase + every resolved input. Flat JSON, written by `printf`, **read back by `plutil`** |
| `brief.md` | the frozen brief |
| `prompt.txt` | brief + the succession handshake — what the successor actually receives |
| `launch.sh` | the generated launcher: env scrub, `cd`, read the prompt from a file, `exec` |
| `handle` | the driver's opaque handle for the successor |
| `ack` | the successor's proof-of-tool-use, if it gets that far |
| `pred-pane` | the predecessor's own pane identity, written BEFORE the retire |
| `run.lock.d/`, `launch.lock.d/` | `mkdir`-atomic locks, holder pid inside |
| `log` | append-only |

Exit codes of `fire`: **0** done · **2** refused (preflight, bad arguments, no bridge) ·
**3** engagement NOT proven — *the predecessor survives, and this is not a failure of the
invariant* · **4** failed launch · **5** another driver owns this id.

---

## 3. THE ORACLE, AND WHY EVERY CHEAPER ONE IS A DEMONSTRATED FALSE POSITIVE

`oracle.sh` is filesystem-pure and knows nothing about processes. It states WHAT IS TRUE;
`decide` states WHAT TO DO. Conflating those is how a detector that cannot say NO gets shipped.

| candidate oracle | verdict | the artifact that refutes it |
|---|---|---|
| a non-shell process runs in the pane | **FALSE POSITIVE** | a pane parked on the first-run theme picker reports `pane_current_command=claude.exe` |
| the successor's transcript exists | **FALSE POSITIVE** | an unauthenticated run writes one |
| the transcript contains the brief | **FALSE POSITIVE** | the harness writes the `user` record BEFORE the agent runs |
| the transcript has an `assistant` record | **FALSE POSITIVE** | the unauthenticated run writes one too: `model:"<synthetic>"`, `isApiErrorMessage:true`, text `Not logged in · Please run /login` |
| **a token only the model could have echoed** | **the one shipped** | — |

The ladder, and what makes each rung unforgeable:

| rc | tier | claim | why it cannot be faked |
|---:|---|---|---|
| 0 | `ACTED` | the agent ran a TOOL because of this prompt | the ack file holds the nonce, and only the agent's own tool call writes it |
| 3 | `SPEAKING` | logged in, and answering **this** prompt | the nonce appears in a **non-error** `assistant` record |
| 4 | `ARRIVED` | the prompt reached the model's input | the marker appears in a `user` record |
| 5 | `AUTHFAIL` | the session cannot authenticate — TERMINAL | a structural `isApiErrorMessage` / `<synthetic>` record |
| 1 | `NO` | every read SUCCEEDED and found nothing | the honest definite-so-far negative |
| 2 | `CANNOT-TELL` | a read itself FAILED | never treated as a negative |

**Two tokens, not one.** The `marker` identifies the prompt on the INPUT side; the `nonce` is a
second token the prompt instructs the agent to ECHO, so it can only reach the OUTPUT side by the
model having read the prompt. With one token, `SPEAKING` would be satisfiable by a transcript
quoting its own input — and transcripts do exactly that, in `queue-operation` and `attachment`
rows.

**Run its negative arms yourself:** `bash oracle.sh selftest` — 36 cases, every positive paired
with the negative that gives it meaning, including a fixture where an API-ERROR record *quotes the
nonce* and must still not reach `SPEAKING`.

Default bar: `SPEAKING` for Claude Code, `ACTED` for Copilot (whose session store is not readable
before login, so the ack file IS the oracle).

---

## 4. THE DRIVER SEAM

One seam, three implementations. Every driver implements the same verbs or declares it cannot,
and `fire` refuses to start a succession whose driver failed its own preflight.

```
capabilities                          key=value lines
preflight                             rc 0 usable here · 2 not, with the reason
spawn <handle> <cwd> <title> ARGV…    launch ARGV as a real argv vector; no keystrokes
prove-alive <handle>                  rc 0 alive · 1 definitely gone · 2 cannot tell
send-text <handle> <text>             rc 0 DELIVERY VERIFIED · 3 issued, unverifiable · 1 failed
capture <handle>                      print the successor's visible screen
attach <handle>                       the command that opens a viewport on the successor
close-self <statedir>                 retire the CALLER's OWN pane; records its identity first
prove-pred-gone <statedir>            rc 0 gone · 1 still there · 2 cannot tell
alive-cmd <handle>                    the shell string the oracle's --alive-cmd wants
```

| | kitty 0.48.2 | tmux 3.6a | iTerm2 3.6.11 |
|---|---|---|---|
| argv launch, no typing | yes | yes | **yes** — `create window with default profile command "…"` |
| argv fidelity (3 KB hostile payload) | byte-identical | byte-identical | byte-identical (via the launcher path) |
| keystroke verb can say NO | **no — rc 0 for a target that does not exist** | **yes** | rides tmux |
| successor outlives the launching window | yes | yes | yes |
| **successor outlives the terminal APP dying** | **no** | **yes (ppid 1)** | **no** |
| close-self | `@ close-window --self` | `kill-pane -t $TMUX_PANE` | `close` — **two independent measurements disagree**, so its rc is not evidence |

**Therefore tmux is the SUBSTRATE and the terminal is only the VIEWPORT.** `AH_SUBSTRATE` defaults
to `tmux` whenever tmux exists: the successor is born detached, is proven engaged, and only then
does the predecessor die; an ordinary kitty/iTerm2 window is opened attached to it, so the operator
sees a normal window. Set `AH_SUBSTRATE=direct` to use the terminal's own spawn — the successor
then dies with the terminal app, and preflight says so.

`AH_DRIVER=tmux|kitty|iterm2` overrides detection.

**Never wrap the `osascript` in a new helper.** macOS TCC keys Automation consent on the
*(client binary, target app)* PAIR and attributes to the nearest non-platform binary in the
responsibility chain, so a `timeout`/`gtimeout` wrapper creates a different pair and therefore a
NEW consent modal on the target machine. The engine invokes every driver as `/bin/bash <driver>`
for exactly this reason.

---

## 5. WHAT MAKES A FRESH MAC WORK — three gates, and only the third needs a human

| gate | where it lives | seedable |
|---|---|---|
| first-run **theme picker** | `$CLAUDE_CONFIG_DIR/.claude.json` → `hasCompletedOnboarding` | **yes** |
| per-directory **workspace trust** | same file → `projects["<absolute cwd>"].hasTrustDialogAccepted` | **yes** |
| **login** | macOS Keychain, `Claude Code-credentials-<sha256(config-dir path)[:8]>` | **no** |

Bisected one variable at a time: nothing seeded → theme picker, prompt **swallowed**, zero
transcripts. `settings.json {"theme":"dark"}` alone → the picker **still** appears (theme is not
the gate). `hasCompletedOnboarding` alone → the picker goes, and it stops at the trust modal
**whose default selection is "No, exit"**, so a successor that meets it and receives a blind Enter
CLOSES ITSELF. Both seeded → straight to the composer, and the positional prompt AUTO-SUBMITS, on
a brand-new config dir under a brand-new `$HOME`.

So *"`claude \"<prompt>\"` does not auto-submit on a fresh Mac"* was entirely an artifact of two
absent booleans. `seed.sh` writes them before the first launch.

**What this repo will not write:** `hasTrustDialogAccepted` is the one authorization-adjacent key
here, and it is guarded — only for an absolute, existing directory that is **not `$HOME`** (where
the dialog itself warns it pre-approves hundreds of tool permissions) and **not `/`**, only for the
exact cwd the succession targets, and only while `AH_SEED_TRUST` is not `0`. Nothing here writes
`permissions`, `allowedTools`, `apiKeyHelper`, `settings.local.json` or any credential, and there
is no flag that makes it. A login is asked for in chat; it is never scripted.

---

## 6. THE GOAL, ARMED FROM A FILE

There is **no `--goal` launcher flag**: `--help` contains no `goal`, the binary registers 93
`.option("--…")` and none is `--goal`, and `--goal X` is rejected byte-identically to
`--zzzbogusflag X`. What exists instead is a seam in the product's own restore path — setting a
goal appends ONE `goal_status` attachment to the transcript, and `restoreGoalFromTranscript` reads
back exactly the LAST such attachment (returning nothing if it is met/failed) and re-registers the
session-scoped Stop hook from it.

So the bootstrap **writes that line itself** and launches `claude --resume <sid> "<brief>"`:

* ONE exec delivers the goal **and** the initial prompt;
* the restore happens during session init, so the successor's **first turn already has the goal
  armed** — which settles the ordering question for free;
* nothing is typed, and no composer has to be proven empty first.

Two properties of this path that are hazards as much as features:

* it **bypasses the 4000-character cap** the command path enforces, so `seed.sh goal` re-imposes
  the cap itself rather than handing the Stop evaluator a condition no validator ever saw;
* `met:true` does **not** mean "achieved". A launch-time error writes a SECOND `goal_status` with
  `met:true` and prints *"Goal cleared after an unrecoverable error"*. The engine therefore reads
  the goal back **after engagement is proven**, never at arming — and reports `GOAL=live` or names
  the one line that arms it by hand.

The goal read-back is **not** a retire gate by default: a healthy successor that holds the brief
but lost its goal is not a reason to strand two live sessions. `--require-goal` makes it one.

A config that sets `disableAllHooks` or `allowManagedHooksOnly` **disables `/goal` outright**
(measured, both arms). Preflight refuses rather than arming a goal that silently does nothing.

---

## 7. THE FAILURE TAXONOMY, and the live arm that produced each

Every row below was produced on the source box, not reasoned about.

| # | failure | detection | what happens | arm |
|---|---|---|---|---|
| 1 | predecessor retires before the successor is proven | the phase machine refuses it | cannot happen | I1 |
| 2 | successor never starts (binary missing, argv wrong) | `tmux new-session` returns **0** for a child that already died; `has-session` 2 s later is the real signal | `FAILED_LAUNCH`, predecessor untouched | 4 |
| 3 | successor parks on the **theme picker** | no transcript is written at all | seeded away; else `NO` → HOLD | 3 |
| 4 | successor parks on the **trust modal** | same | seeded away; else `NO` → HOLD | 3 |
| 5 | successor is alive, got the prompt, **cannot authenticate** | a real `user` record AND a real `assistant` record — every cheaper oracle says ENGAGED | `AUTHFAIL` → HOLD in ~1 s | 2 |
| 6 | prompt mangled in transit | — | it never travels as keystrokes | 0 |
| 7 | the driver's own serialisation mangles argv | successor dies instantly; launcher rc still 0 | `FAILED_LAUNCH` | 4 |
| 8 | the driving script is killed mid-flight | the phase on disk | `resume` re-enters at the recorded phase and does not relaunch | 5 |
| 9 | two successors | `launch.lock.d` | the second launch is refused | 5 |
| 10 | two drivers over one state file | `run.lock.d` + holder liveness | the second exits 5 and touches nothing | 6 |
| 11 | the driver is killed by its own retire | `RETIRED` is written first; a detached reaper verifies | `DONE` lands anyway | 1 |
| 12 | the brief changed between plan and launch | checksum frozen at plan | refuse; never launch a stale brief | 7 |
| 13 | usage-limit / billing failure at launch | shares the `isApiErrorMessage` channel with #5 | `AUTHFAIL` → HOLD | inferred, not produced |
| 14 | an armed goal is silently cleared by a launch-time error | a second `goal_status` with `met:true` | read back after engagement, reported | §6 |
| 15 | a wedged agent binary hangs the preflight | `ah_bounded` polls a pid it started | rc 124 → treated as unknown, never as a verdict | measured |

### The live end-to-end run

Arm 1, Copilot CLI 1.0.83 (authenticated), the driver running **inside the predecessor's own
pane**:

```
launched : successor is up (driver tmux)
proving  : bar=ACTED budget=180s  (the predecessor does not move until this passes)
VERDICT=RETIRE TIER=ACTED ELAPSED=5s DETAIL=TIER=ACTED PROOF=ack-file FILE=…/handoff/pos/ack
✅ successor PROVEN engaged — retiring this pane now.

phase                : DONE          retire_verified: yes
predecessor pane %0  : GONE — retired
successor session    : ALIVE
ack                  : AHN-ac7dcd44-6ee7-49ae-b3e9-66866b107f64   (written by the successor's OWN tool call)
```

### The timeout arm, with a LIVE agent

Arm 2, Claude Code 2.1.260, a config dir that cannot log in — the shape every cheaper oracle calls
ENGAGED:

```
VERDICT=HOLD REASON=authfail DETAIL=TIER=AUTHFAIL PROOF=assistant-api-error CAUSE=api-error
  terminal: waiting cannot help. The predecessor stays up.
⛔ ENGAGEMENT NOT PROVEN. THE PREDECESSOR IS NOT RETIRED and this pane is still yours.

FINAL PHASE      : TIMEOUT_UNPROVEN
PREDECESSOR PANE : ALIVE — the work is safe
```

Its transcript carried the seeded `goal_status`, a real `user` record with the argv brief, and
real `assistant` records. The brief arrived **verbatim on the successor's screen**.

---

## 8. WHAT IS UNPROVEN — stated so nobody inherits a guess

1. **No authenticated Claude Code succession was run end to end.** Every Claude Code arm here
   stops at the auth wall by choice: the only way to authenticate a throwaway config dir is to
   borrow a real credential, and an OAuth refresh from a copy can rotate and invalidate the
   original. The authenticated end-to-end arm therefore used **Copilot**. What that leaves
   unmeasured is narrow and named: *a real Claude Code model turn following an argv-launched,
   goal-headed prompt.* Everything on either side of it — the launch, the byte-exact arrival of
   the brief in Claude Code's own transcript, the goal seed on line 1, the on-disk signature that
   separates engaged from not-engaged, the retire — was measured on Claude Code itself.
2. **The goal seed's survival across a successful turn is INCONCLUSIVE.** It is proven *armed and
   live at the start of turn 1* (an auth error cannot clear a goal that was never armed, and the
   error names the seeded condition). Whether it survives a healthy turn needs one authenticated
   `--resume`.
3. **`claude auth status --json` is a ONE-ARMED instrument here.** Only its negative arm was
   observed. An unrecognised answer is reported as unknown and does **not** refuse, because a
   preflight that refuses on a working machine makes the feature unusable while the oracle's
   `AUTHFAIL` tier catches a real logout in about a second and lands on HOLD.
4. **The first-ever macOS Automation consent dialog on a clean Mac was never raised** — the grant
   already exists on the source box, so the TCC diff before/after is empty. Its existence is
   certain from the TCC schema; its exact wording is not measured.
5. **Display-locked / screen-saver behaviour** is proven irrelevant for the tmux substrate (every
   run executed with zero attached terminals) and **unmeasured** for the AppleScript path.
6. **`ACTED` blocked by a permission prompt** is unmeasured: producing one needs a config with
   auto-approval off, and the only such configs are unauthenticated. This is exactly why the
   default bar is `SPEAKING` and not `ACTED` for Claude Code.
7. **Version pinning.** Every Claude Code measurement is against **2.1.260**. `hasCompletedOnboarding`
   was version-insensitive as far as tested; a later binary could re-onboard on a version bump.
8. **Copilot `--autopilot`**: flag surface confirmed, behaviour not run.

---

## 9. ONE-TIME HUMAN GESTURES, and there are no others

1. **One OAuth login per config-dir PATH, ever.**
   `CLAUDE_CONFIG_DIR=<dir> claude auth login`.
   There is no token-paste login for Claude Code. The credential is a Keychain item named
   `Claude Code-credentials-<sha256(absolute path)[:8]>`, so **moving or renaming the config dir
   logs it out silently**, and copying a config dir to a new Mac produces a directory that is
   onboarded and logged out. Copilot needs no browser gesture at all —
   `COPILOT_GITHUB_TOKEN` / `GH_TOKEN` / `GITHUB_TOKEN` in the environment is a supported path.
2. **iTerm2 driver only: one macOS Automation consent click**, per (calling binary, iTerm2):
   `osascript -e 'tell application "iTerm2" to count windows'` → Allow. It persists, and it cannot
   be pre-granted from the command line (TCC.db is SIP-protected).
3. **kitty driver only, and only if kitty is the remote-control viewport:**
   `allow_remote_control socket-only` and `listen_on unix:/tmp/kitty-{kitty_pid}` in `kitty.conf`,
   then **restart kitty** (a `SIGUSR1` config reload does not create the socket). A **literal**
   `listen_on` path is silently ignored — no socket, empty stderr — so the `{kitty_pid}`
   placeholder is load-bearing. On a new Mac, write `kitty.conf` before first launching kitty and
   this gesture disappears.

**Per recycle, per launch, per worktree: none.**

---

## 10. RUNNING THE TESTS

```bash
bash assets/succession/oracle.sh selftest    # 36 cases — the oracle's negative arms
bash assets/succession/seed.sh   selftest    # 47 cases — seeding, guards, and the plutil traps
bash assets/agent-handoff        selftest    # 51 cases — bridge, state, locks, launcher, transit
bash assets/agent-handoff        doctor      # is THIS machine ready, and what is still human
```

## 11. MEASURED TRAPS THIS CODE PAYS FOR

* **`plutil -lint` REJECTS valid JSON** (`Unexpected character { at line 1`). The validator is
  `plutil -convert json -o /dev/null`. A guard built on `-lint` refuses every file it protects.
* **`plutil -extract` writes its FAILURE MESSAGE TO STDOUT.** A reader that forwards stdout
  without checking the rc hands its caller an error sentence where a value belongs — harmless for a
  `= "true"` test, fatal for a `= ""` test. It silently broke trust seeding on every config dir the
  binary had already written.
* **`plutil -extract <an array> raw` prints the element COUNT**, not the elements. Reading it as a
  list makes an "already present?" check answer 1 for arrays of any size.
* **plutil `-replace` and `-insert` BOTH fail against an EMPTY ROOT DICT**, which is the fresh-Mac
  case — so `{}` is never created; the file is created already populated.
* **plutil does not auto-create intermediate dicts**, so a brand-new project entry is written whole
  and an existing one is edited key-by-key (never replaced, which would discard the operator's
  state).
* **A tty in canonical mode DELETES a line over 1024 bytes** and the sender still gets rc 0.
  Bisected: 1023 + Enter arrive; 1024 + Enter arrive as ZERO.
* **`timeout` is GNU coreutils and is not on a stock macOS PATH** — `ah_bounded` polls a pid it
  started instead. Without it, a wedged agent binary leaves `fire` hung at `PLANNED` with two lines
  printed and no error, which reads exactly like a crash.
* **The Claude Code project-slug rule is "every character outside `[A-Za-z0-9]` becomes `-`"**, not
  `s#/#-#g`. The wrong rule costs a silent false negative on any cwd containing `_`, `.` or a
  space — which worktree names routinely do. Better still: pass `--session-id` and find the
  transcript BY NAME, which is what this engine does.
* **A cwd-slug fallback leaks ACROSS SESSIONS.** Every successor in one directory shares one slug
  directory, so a sibling's old transcript answers for this one — measured, a successor with no
  transcript at all returned `AUTHFAIL` read out of a different session's file. When a session id
  is given it is authoritative and there is no fallback.
* **A staleness guard phrased as "the bar must not already be met when we start watching"** is
  right on a first fire and WRONG on a resume, where the successor has legitimately engaged
  already. The honest discriminator is *is the proof NEWER THAN THE LAUNCH*.
* **`open -a <terminal>` from inside an agent's Bash tool poisons every session that app will ever
  spawn** with the caller's `CLAUDE_CODE_*` environment — including `CLAUDE_CODE_CHILD_SESSION`,
  which disables transcript saving and blinds the oracle on a perfectly healthy successor. The
  launcher's `env -i` scrub is mandatory, not hygiene.
* **Launching iTerm2 is not a read.** `open -g -a iTerm` triggered macOS session restoration, which
  re-created a window and let the user's shell rc spawn three real agent sessions and three git
  worktrees. The iTerm2 driver refuses to preflight against an app that is not already running.

---

## PROOF

*Added 2026-09-11 by an adversarial prover whose instrument was RUNNING this engine, not reading it.
Full record: `…/scratchpad/succession/PROOF.md`. Box: macOS 15.7.9, M1 Max, tmux 3.6a, **Claude Code
2.1.269** — one minor version ahead of the 2.1.260 this was written against. 36 `fire` invocations,
of which 18 retired a predecessor and 18 were deliberate failure arms. All three shipped selftests
pass on the bytes described here: `agent-handoff` 51/51 · `oracle.sh` 44/44 · `seed.sh` 47/47.*

### MEASURED — executed here, with both arms wherever a verdict depends on one

* **The invariant held under every attack.** 18/18 failure arms ended with the predecessor ALIVE and
  nothing retired. **Zero false ENGAGED.** There is exactly one `close-self` call site, guarded by
  `phase = ENGAGED`, and exactly one live site that writes `ENGAGED`, immediately after the oracle
  returns 0. Every path that cannot reach the oracle — a missing part, a crash, a read error, a
  budget expiry, CANNOT-TELL — resolves to HOLD.
* **The oracle says NO to all five shapes, four of them induced with the real `claude` binary:** a
  successor that dies instantly · one that starts and never consumes the prompt · one **parked on
  the real first-run theme picker** (`claude.exe` alive, prompt swallowed, captured from the pane) ·
  a launch that silently no-ops at rc 0 · **a driver that lies and reports the successor alive
  forever** · a real successor that receives the prompt and cannot authenticate (`HOLD
  CAUSE=not-logged-in`, 4 s). The last is the one every cheaper oracle fails: its transcript carries
  a real `user` record holding **both** tokens and a real content-bearing `assistant` record.
* **Prompt fidelity, 3 KB of hostile bytes** (quotes, backticks, `$(…)`, `$HOME`, tab, 32 newlines,
  shell metachars, JSON bait, é/中文/рус, 🚀 🇺🇸 👩‍💻 ZWJ, NBSP, RTL): **3,716 / 3,716 bytes
  byte-identical into the successor's argv, and byte-identical again inside Claude Code's own
  transcript** (`EXACT: True`). `grep -n 'send-keys'` over `agent-handoff`: **zero call sites**.
* **Happy path, 9 consecutive stub runs + 3 authenticated runs = 12 successions with no failure.**
  LAUNCHED→ENGAGED median **4 s** (min 0, max 10); PLANNED→DONE median **8 s**.
* **Kill the driver mid-flight and `resume`:** recovered at `LAUNCHED` (proof accepted via the
  `--since` guard, no relaunch) and at `LAUNCHING` (re-attach, no second successor). No window loses
  the work; the worst outcome anywhere is two live sessions.
* **No state leaks.** A silent successor in the *same cwd and same config dir* as a completed,
  fully-engaged succession reported `TIER=NO PROOF=no-transcript` and HELD. Reusing an `--id` now
  refuses at rc 5 having launched nothing.
* **Zero human gestures per recycle**, across all 36 fires.
* **The authenticated end-to-end gap named in this README is CLOSED** — three real Claude Code model
  turns, argv-launched, goal-headed, proven and retired; the last with `--require-goal --no-ack`, so
  the transcript was the only admissible proof.

### FIXED — seven defects, six of them fixed here and re-proven

Each carries its measurement in a comment beside the code.

1. **`USER` was scrubbed out of the launcher's `env -i`, and it is part of the credential lookup.**
   4 cells, one variable, replicated on a second account: full env → `loggedIn: true`; `env -i` →
   **false**, in and out of tmux. Inside the scrub, `+USER` → true, `+LOGNAME` → false,
   `+USER=nosuchuser` → **false** — a wrong value fails like an absent one, so it is a lookup key,
   not a decoration. **Every succession against a real logged-in account ended AUTHFAIL → HOLD.**
   The previous wave could not have seen it: its one authenticated arm was Copilot, whose credential
   is an env token.
2. **`model:"<synthetic>"` was read as an API error.** It means *the harness manufactured this
   record*, not *this is an error*. A healthy authenticated successor writes
   `{"model":"<synthetic>","text":"No response requested."},"isApiErrorMessage":false` **1.2 s after
   launch and 2.7 s before its first real answer** — and the driver's own 2 s spawn wait lands the
   first probe inside that window, so the terminal AUTHFAIL won the race on *every* authenticated
   run. Now `<synthetic>` disqualifies a record from being **proof** but is not an **error**;
   `isApiErrorMessage` alone is the error test. AUTHFAIL is terminal only for `not-logged-in` /
   `auth-failed` — a transient error no longer abandons a successor that recovers.
3. **The transcript arm was blind on a symlinked config dir.** BSD `find` does not descend a
   symlinked start directory without `-H` and reports that as nothing-found at rc 0.
   An alternate config dir's `projects/` can be such a symlink: `find … -name "$sid.jsonl"` → 0 lines rc 0,
   `find -H …` → 1 line. Proof could then come only from the ack file; with `--no-ack` every
   succession would HOLD forever. Replaced with shell globs, which follow symlinks by construction
   and cannot regress by forgetting a flag.
4. **The launch lock was stealable.** A lock may be stolen from a dead holder only when what it
   guards dies with that holder — true of `run.lock.d`, false of `launch.lock.d`, whose successor
   outlives its driver. Killing the driver inside `cmd_spawn`'s 2 s window made `resume` attempt a
   **second** successor; only tmux refusing a duplicate session *name* prevented two agents on one
   brief, and the engine then recorded `FAILED_LAUNCH — the successor did not start` over one that
   had started and engaged. Now: never steal it; a `resume` with a handle re-attaches and lets the
   oracle arbitrate; a fresh `fire` over a spent id refuses.
5. **`resume` over `FAILED_LAUNCH` returned 0 having done nothing** — a silent success over a dead
   succession. Now rc 4, plus a defensive rc 6 for any unhandled phase.
6. **"goal NOT live — arm it by hand" over a goal that was armed and MET.** The read-back had two
   states where the store has three. Measured: seed `met=false`, then the product's own
   `goal_status met=true`, screen reading `✔ Goal achieved (13s · 1 turn)` — and the engine told the
   operator to re-arm it. `--require-goal` would have held the predecessor over a satisfied goal.
   Now `GOAL=none|live|done`.
7. **`doctor` now names a FOURTH one-time gesture: `brew install tmux`.** macOS ships no tmux and
   this repo's README rules a multiplexer out of scope — but **the fault tolerance IS the tmux
   substrate**. Without it, the iTerm2 and kitty drivers fall back to `direct`, where the successor
   is a child of the terminal and dies with it. The preflight already printed a NOTE; a NOTE is the
   wrong rung for the difference between fault-tolerant and not, on the exact machine this is built
   for. Shown only when tmux is absent (both arms verified).

### ASSUMED — stated, not measured

* **`seed.sh trust` read-modify-writes `.claude.json` with no lock** (`cp` → `plutil` → `mv -f`)
  while Claude Code itself keeps a `.claude.json.lock` in that directory. A concurrent write inside
  that window is silently lost. Found by READING. It did not bite: diffed before/after across two
  live accounts holding 633 and 357 project entries, with ~15 concurrent sessions running —
  **0 top-level keys lost, 0 project entries lost** in 5 real fires. Near-zero on the target machine
  (one session at a time); real but small here. Not fixed, because re-implementing the product's own
  lock protocol blind is a worse risk than the one it removes. Cheapest honest fix: re-read and
  compare before the `mv`, retry on divergence.
* The oracle's line-type test could in principle be fooled by unescaped nested JSON on a `user`
  line. Verified unreachable through the prompt (a JSON string is escaped — checked per line on a
  real transcript carrying deliberate `"type":"assistant"` bait). It remains reachable in theory via
  a structured `toolUseResult`, but only *after* the agent has run a tool, which is engagement at a
  higher tier than the one being forged.
* `agent-handoff selftest` shows 4 failures when `bootstrap-lib.sh` is unreachable — all four are
  context-fill arms, and the tool correctly reports `UNKNOWN (no-bootstrap-lib.sh)`. Not an engine defect, but
  a standalone install of the succession parts will show red.

### UNTESTED ON THE TARGET MACHINE (clean-install Mac, iTerm2, Copilot seat)

* **The iTerm2 driver was never executed.** iTerm2 is running on the source box with the operator's
  live sessions in it, and its preflight drives `osascript` into that running app. Verified without
  driving it: `capabilities`, and by reading, that the newline refusal precedes any `osascript`.
  **The gap is narrower than it sounds when tmux is present** — the iTerm2 driver's default substrate
  *is* the tmux driver, delegating `spawn`, `prove-alive` and `capture` verbatim, so everything
  proven above is the same code. Genuinely untested: the AppleScript window creation for the
  viewport, `close-self` (which the driver itself reports as `unverifiable`), and the one Automation
  consent click.
* **Direct mode — iTerm2 or kitty with no tmux — is untested end to end, and on a clean-install Mac
  it is the DEFAULT**, because macOS ships no tmux. This is the largest target-machine risk and the
  reason fix 7 exists. **Install tmux on the new Mac before relying on the fault-tolerance claim.**
* The **kitty driver** was not executed (kitty is the operator's live terminal on the source box).
* **Copilot was not re-measured.** The prior wave's findings are inherited unchanged — noting only
  that the Copilot arm is immune to fixes 1 and 2 by construction, which is exactly why it could not
  have caught them.
* A recycle **into a real git worktree** (as opposed to a scratch directory) was not run.
* A **long-running first turn** was not run: both proven authenticated briefs answered in seconds,
  so the 180 s default budget path was exercised only with stubs.
