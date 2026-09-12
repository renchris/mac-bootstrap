# The module contract

This is the document you write a `modules/mN_name.sh` against. The rail — `bootstrap.sh`,
`verify.sh`, `assets/hooks/bootstrap-lib.sh` — is finished and will not change shape under you. Read
§1, §2 and §8; the rest is reference.

---

## 1. What a module is

A file at `modules/<name>.sh` that defines six shell functions and **no top-level side effects**.
It is `.`-sourced, never executed. `<name>` is the function suffix: a module at
`modules/statusline.sh` defines `verify_statusline`, `gate_statusline`, and so on.

**Every verb runs in its own subshell, with `bootstrap-lib.sh` and your module freshly sourced.**
That is not an implementation detail you may ignore:

- **No state survives between verbs.** A variable `install_` sets is gone by the time `verify_`
  runs. If two verbs need to agree on something, put it on disk or re-derive it.
- **A stray `exit` cannot kill the run.** Measured: a syntax error in a sourced file leaves the
  shell alive, but a bare `exit` in one *terminates it* — one such line in one module would end
  the whole bootstrap and every later module would silently never run. The subshell contains it.
- **Top-level code still runs**, once per verb call. Put nothing at the top level but function
  definitions and `readonly`-style constants. Anything expensive there is paid six times.

The driver discovers modules in this order: `BOOTSTRAP_MODULES` (a space-separated list, used by
tests) → `modules/*.sh` beside `bootstrap.sh` → the built-in manifest, fetched from the pinned
raw URL. A module named in the manifest that cannot be resolved is recorded `SKIPPED`, which is
a precondition error (exit 30), never a silent absence.

Keypath segments in anything you pass to the library may not contain a `.` — the library splits
on it.

---

## 2. The six verbs, and the optional seventh

| Verb | Must | Must not |
|---|---|---|
| `verify_<m>` | exit **0 if and only if** the end state is genuinely present on this machine, read back through a **different code path than the installer wrote it with**. Called BEFORE install (that is what makes the whole thing idempotent) and again AFTER. | Never grep for a string you just wrote. Never trust an installer's exit code. Never print to stdout. |
| `gate_<m>` | exit **0 iff a human gesture is required** — a GUI permission, a Keychain dialog, `sudo`, an Apple ID, the App Store, money. Called **before any early return**, so a gated module is reported in every mode. Called **again** if `install_` fails, because an installer may discover a gate it could not see in advance. | Never perform the gesture. Never prompt. |
| `note_<m>` | print **one line of plain English** naming what is missing. | No ANSI, no multi-line. |
| `gesture_<m>` | print **the one resolved command** the human runs, executable exactly as typed. Empty output is allowed when there is no command (a GUI toggle with no CLI). | Never print a bare path — a path pasted into a shell is *executed*, not opened. Use `open "<url>"` or `cursor <path>`. Never print a list. |
| `install_<m>` | do the **reversible** work. May exit non-zero; the driver handles it. Anything it prints goes to the log. | Never do irreversible work. Never write permissions, allowlists or credentials. Never `sudo` without the operator having already run it. |
| `uninstall_<m>` | reverse `install_`. Must be safe to run when nothing is installed. | — |
| `bench_<m>` *(optional)* | measure a candidate and **print its verdict**; the operator or the agent reads that output and chooses. Invoked only under `--bench`. | Never change state. Never write the receipt. |

`verify_`, `gate_`, `install_` and `uninstall_` speak in exit codes. `note_`, `gesture_` and
`bench_` speak in stdout.

**A module missing any of the six is recorded `FAILED` and never sourced further.** `bench_` is
the only optional one.

---

## 3. The four states, and exactly how the driver picks one

```
gate_<m>                          ← always evaluated first, in every mode
verify_<m> == 0                 → SATISFIED
else gate_<m> == 0              → NEEDS_HUMAN   (note_ and gesture_ are recorded)
else --verify mode              → FAILED        "not installed"
else install_<m> == 0
       and verify_<m> == 0      → SATISFIED
       and verify_<m> != 0      → FAILED        "installer exited 0 but the read-back disagreed"
else install_<m> != 0
       and gate_<m> == 0        → NEEDS_HUMAN   (a gate the installer discovered)
       else                     → FAILED
module file unresolvable        → SKIPPED
```

`SKIPPED` means exactly one thing: **the module is not in this release at this pin.** It is not
"already done" (that is `SATISFIED`) and it is not "excluded by `--only`" — an unselected module
is not re-run at all and simply keeps the row it already had.

---

## 4. Exit codes — the same scale on the install path and under `--verify`

| | Meaning |
|---|---|
| **0** | every module `SATISFIED`. Nothing else is 0. |
| **10** | satisfied except for modules waiting on the human (`NEEDS_HUMAN`). |
| **20** | something `FAILED`. |
| **30** | precondition/internal error — including any `SKIPPED`. **This run is not a verdict about the machine.** |

Precedence when several apply: **30 > 20 > 10 > 0**.

Two consequences worth stating, because the design this replaces got both wrong:

- `--verify` exiting **0** means *every module is satisfied*, not *nothing is left for the
  script to do*. A machine with no Xcode, no Accessibility grant and no terminal returns **10**,
  and the operator is told which steps are theirs.
- **There is no `--dry-run`.** It overwrote the receipt with meaningless rows — destroying the
  only record of what needed the human — and it exited 0 on a machine where nothing was
  installed. Passing `--dry-run` now prints why and exits 30.

### Three more, added 2026-09-11 by the integration pass that measured them going wrong

- **A manifest module with NO row was never judged, and lands in 30 — never in 0.** Measured
  pre-fix: `bash bootstrap.sh --only handoff` on a fresh Mac exited **0** and printed *"every
  module satisfied"* while seven deliverables had never been evaluated and no statusline existed
  on disk. An unselected module writes no row and the verdict only ever read rows that exist.
  The receipt still carries only the rows that were judged; the `error` field names the rest.
- **A row state that is not one of the four exact literals is 30, not 0.** A truncated or failed
  `driver_row_set` leaves an EMPTY `.state` file, and a corrupt receipt recovered through
  `driver_rows_recover` can carry anything. Both used to fall through the `case` to the
  all-satisfied return. The `case` now has a fail-closed default.
- **Under `--uninstall` the scale is different, because uninstall CLEARS rows**: **0** everything
  removed · **20** an `uninstall_` failed · **30** a `SKIPPED` (the module file could not be
  resolved, so its `uninstall_` was never attempted) or a state nobody can read. Zero rows is
  uninstall's SUCCESS and only uninstall's — a fully successful uninstall used to exit **30**.

---

## 5. The environment contract

A sourced function cannot take flags, so parameters arrive as exported variables. These names
are the contract.

| Variable | Set by | Meaning |
|---|---|---|
| `BOOTSTRAP_MODE` | the driver | `install` · `verify` · `bench` · `uninstall` |
| `BOOTSTRAP_MODEL` | `--model <name>` | the model a module should install. |
| `BOOTSTRAP_BENCH` | `--bench <model>` | the candidate `bench_` should measure. |
| `BOOTSTRAP_STATE_DIR` | the driver | `$HOME/.mac-bootstrap`. **All runtime state goes here**, never in the repo. |
| `BOOTSTRAP_ASSETS` | the driver | the `assets/` directory beside `bootstrap.sh`, when running from a clone. |
| `BOOTSTRAP_LIB` | the driver | the absolute path to the `bootstrap-lib.sh` in force. |
| `BOOTSTRAP_PIN` / `BOOTSTRAP_RAW` | the driver | the release sha and the raw URL prefix, for a module that must fetch an asset. |
| `BOOTSTRAP_LOG` | the driver | the log file. `bootstrap_warn` writes there as well as to stderr. |
| `BOOTSTRAP_MODULES` | tests | overrides module discovery. |
| `BOOTSTRAP_NO_JQ` | tests | forces every library path onto its plutil arm, so the no-jq degrade is *tested* rather than asserted. |
| `BOOTSTRAP_TELEMETRY_DIR` · `BOOTSTRAP_CONTEXT_THRESHOLD_PCT` · `BOOTSTRAP_CONTEXT_MAX_AGE_S` | seams | context-advisory tuning; defaults `/tmp/mac-bootstrap-telemetry`, `70`, `600`. |

---

## 6. The library — and the ONE writer rule

`assets/hooks/bootstrap-lib.sh` is the only shared code. It is sourced by the driver, by every module
and by every lifecycle hook. Run its fixtures any time: `bash assets/hooks/bootstrap-lib.sh --selftest`.

### 🚨 `bootstrap_settings_merge` is the only thing in this repo that writes a JSON settings file.

```sh
bootstrap_settings_merge <file> <keypath> <json-value> [set|append]
```

`statusline` (the statusLine) and `hooks` (the hooks) both go through it, and so does every Copilot file —
`$HOME/.copilot/settings.json` and `$HOME/.copilot/hooks/00-lifecycle.json`. **Do not call
`plutil` or `jq` to write a settings file yourself.** Two writers for one file is the defect this
rule exists to prevent: the design had `statusline` writing with `plutil` while `hooks` used a jq-only
merger that *hard-exited* when jq was missing, so on a Mac without `/usr/bin/jq` the statusline
would install and the hooks would not, with the failure attributed to the wrong thing.

It is:

- **additive** — every other key in the file survives.
- **idempotent** — if the keypath already holds this value, compared through plutil's own
  normalisation, the file is not opened for writing at all.
- **atomic** — all work happens on a temp copy which is read back *there*; a failed write never
  lands. A half-written `settings.json` makes the agent start with **no hooks at all**, silently.
- **backed up** — `<file>.mac-bootstrap-backup.<utc>`, once per file per run.
- **degrading** — jq by absolute path when present, plutil when not. It **never** returns
  non-zero merely because jq is absent.
- **refusing** — a keypath or file that authorizes the agent is refused, at the chokepoint.

| Function | Use |
|---|---|
| `bootstrap_settings_merge f k v [set\|append]` | the one writer. rc 0 written-or-already-correct · 2 refused/failed · 3 unsupported keypath shape |
| `bootstrap_settings_get f k [json\|raw]` | **the read-back.** plutil only, never jq — a different engine from the one that wrote, by construction. Empty + rc 1 when absent. |
| `bootstrap_settings_type f k` · `bootstrap_array_len f k` | shape probes |
| `bootstrap_hook_wire f Event matcher command [timeout]` | Claude Code hook chain: additive, order-preserving, idempotent |
| `bootstrap_copilot_hook_wire f Event matcher command [timeoutSec]` | the Copilot envelope (`version`, `bash`, `timeoutSec`) |
| `bootstrap_hook_unwire f command-prefix` | for `uninstall_` |
| `bootstrap_json_escape text` | before putting any text in JSON |
| `bootstrap_json_ok file` · `bootstrap_json_type v` · `bootstrap_json_fmt v` · `bootstrap_json_norm v` | validate / classify / canonicalise |
| `bootstrap_ctx_pct sid` · `bootstrap_ctx_advisory sid` | the context-fill advisory. **Neither reads git.** |
| `bootstrap_jq` · `bootstrap_have_jq` | absolute jq path, or rc 1 |
| `bootstrap_json payload path` · `bootstrap_emit_ctx event text` · `bootstrap_git dir args…` · `bootstrap_count` · `bootstrap_trunk dir` | hook helpers |
| `bootstrap_warn text` | stderr + the log. **Never stdout** — a hook's stdout is parsed as JSON. |

---

## 7. Measured traps this repo has already paid for

Every one of these was established by running it on macOS 15.7.9 (24G830). Do not re-derive
them, and do not "fix" the code back.

1. **`plutil -replace` AND `-insert` both exit 1 against an empty root dict `{}`** — the
   fresh-Mac case, and it *recurs* whenever `uninstall_` removes a file's last key. `-convert`
   first is not a fix either. The repair is to seed a throwaway key, write, then remove it;
   `bootstrap_settings_merge` does this for you, and the selftest runs the **pre-fix arm and requires it
   to stay red** so the repair remains attributable.
2. **`plutil -lint` cannot validate JSON.** It lints property-list syntax and reports
   `Unexpected character { at line 1` on a perfectly valid receipt and on a real, in-use
   `~/.claude/settings.json`. `{}` passes only because it is also a valid empty OpenStep
   dictionary — which is how a reader who tests `-lint` on `{}` concludes it works. Use
   `bootstrap_json_ok`, which runs `plutil -convert json -o /dev/null` plus jq as a second engine.
3. **`plutil -extract` writes its failure message to STDOUT**, not stderr. A reader that
   forwards stdout without checking the rc hands its caller an error *sentence* where it expects
   a value. `bootstrap_settings_get` emits only on rc 0.
4. **`plutil -insert … -append` on a MISSING key exits 0 and writes the value as a dict**, not as
   a one-element array — `hooks.SessionStart` becomes `{…}` instead of `[{…}]`, a silent shape
   corruption the agent then cannot read. Guard with `bootstrap_settings_type … = array`.
5. **plutil cannot render a top-level scalar as JSON** (`invalid object in plist for destination
   format`), so a scalar can only be compared through `raw`. `bootstrap_json_fmt` tells you which format
   a value needs; both sides of a comparison must use the same one.
6. **`plutil -replace` rewrites the whole file**: pretty-printed JSON collapses to one line and
   `/` is escaped to `\/`. Valid, but a reformat of a file the user may hand-maintain — which is
   why the jq arm is preferred when jq is there.
7. **plutil dies on JSONC.** Copilot's own `~/.copilot/config.json` ships with a `//` comment on
   line 1, so never plutil-edit that file.
8. **`$?` after a pipe is the LAST stage's status.** `xcodebuild -version | head -1` under
   `pipefail` SIGPIPEd rc=141 in 1 of 80 runs and misdiagnosed as an Xcode licence problem.
   Capture, then read the rc. The rail does not set `pipefail` for this reason.
9. **`grep -c` prints a valid `0` and exits 1 on no match.** `$(grep -c x f || echo 0)` puts a
   second producer on one stream and the caller reads `"0\n0"`, which fails every `-gt` test with
   `integer expected`. Use `bootstrap_count`, or capture once and default the variable.
10. **`plutil` parses XML and binary plists too**, so "it parses" is not "it is JSON". Measured:
    `plutil -convert json -o /dev/null` returns 0 for an XML plist and for a binary one. Since
    `plutil -replace` *preserves the input format*, handing it an XML-plist `settings.json`
    writes a valid XML plist back and the agent — which reads that path as JSON — starts with no
    settings at all. `bootstrap_is_json_text` checks the first non-whitespace byte and the writer
    refuses anything that is not `{`.
11. **`exec 3>>"$LOG" 2>/dev/null` is two redirections on one `exec`** and silently sends the
    whole script's stderr to `/dev/null` for the rest of the run. (This one was found in this
    driver, by running it: the terminal showed eight modules and not one word about why none of
    them ran, while the log recorded every error perfectly.)

---

## 8. House rules every module must obey

1. **bash 3.2.** The target ships `/bin/bash` 3.2.57. No associative arrays, no `${x^^}`, no
   `mapfile`. Indexed arrays are fine. Check with `/bin/bash -n` — not with Homebrew's bash 5.
2. **`set -u` is on; `set -e` is not**, and must not be. A module failing must not kill the run.
3. **Fail open.** A hook that wedges a session is worse than a hook that says nothing. Every
   exit path of a hook script is an explicit `0` — Copilot's `preToolUse` **fails closed** on any
   non-zero exit, so a crash there blocks the tool call.
4. **Verify by independent read-back** — parse it back with `plutil`/`jq`, execute the script,
   read the geometry. Never grep for a phrase you just wrote; never trust an installer's exit
   code. `kitty @ action` exits **0 on an unknown action name**, so a bare rc proves nothing in
   either direction.
5. **A negative control is what makes a positive result mean something.** Assert that your
   verifier can say *no*: a bogus event name must write nothing, an empty directory must answer
   UNKNOWN, a crossed fixture must produce no percentage.
6. **Never write permissions, allowlists, credentials, or anything that authorizes the agent.**
   If you need a permission, the operator grants it in chat. `bootstrap_settings_merge` refuses these
   keypaths, but that is a backstop against our own mistakes, not a boundary (see §9).
7. **Detect and RECORD a human-gated step; never attempt it.** GUI permission, Apple ID, App
   Store, sudo, money, a Keychain dialog.
8. **Idempotent.** Re-running is the recovery procedure. Run your module twice and diff the
   files it touched; the second run must change nothing.
9. **No absolute path containing a username may appear in any shipped file.** `$HOME` only.
   This repo is public.
10. **Nothing is written inside the repo at runtime.** `$BOOTSTRAP_STATE_DIR`, always.

---

## 9. What the rail does NOT protect you from — stated so nobody over-trusts it

`bootstrap.sh` greps each module for shapes that look like self-authorization before sourcing
it. **That is a denylist of spellings inside the fetched artifact**, it is defeated by three
lines of string-splitting, and modules are *sourced*, so top-level code in one runs before any
check of ours. It is defence-in-depth against our own mistakes and nothing more.

**The SHA pin on the fetched tree is the only real integrity control.** The enforcement that is
real is the refusal inside `bootstrap_settings_merge`, because that is the chokepoint that actually
writes — a guard on the act rather than on the text.

---

## 10. How to know your module is done

```sh
bash assets/hooks/bootstrap-lib.sh --selftest            # the shared library's own fixtures
/bin/bash -n modules/<name>.sh                    # bash 3.2 parses it
shellcheck -S warning modules/<name>.sh           # clean, or a targeted disable with a reason

HOME=$(mktemp -d) bash bootstrap.sh --only <name> # installs on a machine that has nothing
HOME=$(mktemp -d) bash bootstrap.sh --only <name> # …and the second run changes nothing
BOOTSTRAP_NO_JQ=1 bash bootstrap.sh --only <name>        # the plutil arm does the same thing
bash verify.sh --only <name>                      # a cold, separate process agrees
```

A module is done when `verify_` passes from a cold process, the second install run is a no-op,
the no-jq arm reaches the same end state, and every gesture you print runs as typed.

## Catalog metadata — four OPTIONAL verbs

A module may describe itself. These are optional by design: the six required verbs are the
contract, and a module declaring none of them still works.

| verb | prints | default when absent |
|---|---|---|
| `what_<m>` | one line: what the user gets | the module name |
| `cost_<m>` | one line: disk, minutes, and the human gestures it will ask for | `unpriced` |
| `profile_<m>` | the smallest profile containing it: `lite`, `standard`, `full` | `standard` |
| `needs_<m>` | space-separated modules it requires to be meaningful | none |

**Why the default profile is `standard` and not `lite`:** silence must never be dangerous. An
undeclared module is not in `lite`, so a module nobody has priced can never arrive by default on a
stranger's machine.

## Selection, and how it is scored

`--profile` chooses a set; `--only` replaces it outright; `--except` subtracts; `needs_` adds back
and says so on stderr. Dependency notes go to **stderr** because `driver_select` runs inside a command
substitution — a note on stdout is captured as if it were a module name and then dropped by the
rebuild, which is how "adding it out loud" silently became "adding it".

Two rules the verdict depends on, both of which were false greens first:

1. **The verdict is scored over the SELECTION, not the manifest.** A module you did not select is
   a *declined* module, not an unevaluated one. Scoring over the manifest made `--profile lite`
   permanently return 30, which would have made the whole feature unreachable.
2. **An unresolvable module is INCLUDED in the selection, never skipped.** Dropping it would
   remove it from the set the verdict is scored over, and the run would report success having
   silently lost a module it was asked for. Included, it records `SKIPPED`, and `SKIPPED` is 30.
   Measured: before this, `BOOTSTRAP_MODULES="statusline m99_ghost"` exited **0**.

`exit 0` therefore means *every module in this selection is satisfied*, and the closing line names
the selection size so `0` can never be read as a claim about the modules you declined.
