# mac-bootstrap

Sets a brand-new Mac up for an agent workflow that has to behave identically under **Claude Code**
and **GitHub Copilot CLI 1.0.83**.

Readying one is part files a script can write, part gestures only a person can make — eighteen of
them plus one decision, and no script may take a single one for you. **So this is one entry point,
not one command:** it drives every drivable step, records each of the rest with its exact gesture,
and leaves you about four runs and roughly an hour, most of it waiting on Apple.

1. **[Clear the gates no script may pass for you](#1-clear-the-gates-no-script-may-pass-for-you)** → a Mac that can fetch, install and build
2. **[Decide what to install](#2-decide-what-to-install)** → a selection whose cost you know
3. **[Run it, and read the exit code](#3-run-it-and-read-the-exit-code)** → a receipt
4. **[Close out what the receipt says is yours](#4-close-out-what-the-receipt-says-is-yours)** → a verified machine

## 1. Clear the gates no script may pass for you

`lite` — the default — needs exactly one: **G12′**. An out-of-the-box Mac has only Terminal.app,
which has no equalize action, so `m5_panes` has nothing to bind ⌘⇧E in; it records the gesture and
the run exits `10` until a terminal emulator exists. Every other row below is `standard` or `full`.
The driver detects and records each rather than attempting it, so doing them first only saves you a
re-run — and re-running after one is the recovery procedure, not a repair.

| | Gate | Exact gesture | Blocks |
|---|---|---|---|
| **G0** | Homebrew | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` → RETURN → login password | m6, m7, m8 — and `node`, therefore Copilot itself |
| **G0b** | **cmake** — absent from `/usr/bin`, from Xcode *and* from the CLT, all three probed | `brew install cmake` | m6; whisper.cpp will not build |
| **G0c** | **tmux** — macOS ships none. Without it the drivers fall back to `direct` mode, where the successor dies with the terminal app | `brew install tmux` | 2c's fault tolerance (`agent-handoff doctor` names it) |
| **G1** | Xcode Command Line Tools | if `/usr/bin/git --version` fails: `xcode-select --install` → **Install** → **Agree** | m6, and git everywhere — `/usr/bin/git` is an `xcrun` shim until these exist |
| **G12′** | **A terminal emulator** — a fresh Mac has Terminal.app and nothing else, so m5 has nothing to configure | `brew install --cask iterm2` (or kitty) | m5 |
| **G2** | **Agent installed and logged in.** Copilot is four gestures deep — macOS ships no `node` | Claude Code: `claude` → `/login` → browser OAuth. Copilot: `brew install node` → `npm i -g @github/copilot` → `copilot` → device flow (`gh auth login` also satisfies the last step) | everything on the agent path |
| **G2′** | ⛔ **A decision, not a gesture: has this Mac a Copilot seat?** Unanswerable from a shell | Only you know. If not, `COPILOT_PROVIDER_BASE_URL` documents *"GitHub authentication is not required"* — an unentitled Mac can still run `copilot` against local Ollama | the Copilot half of every row |

One question first: clean install, or Migration Assistant? Migration carries existing TCC grants,
agent config and app secrets across, so the two verify different things — and on a migrated Mac,
rotate any API key that rode along. It is now a key on two machines.

## 2. Decide what to install

These run against the script you fetch in step 3; on the agent path, the prompt does this looking
for you and then asks which profile you want.

| | Command | |
|---|---|---|
| What is on offer, and what each costs | `bash bootstrap.sh --list` | writes nothing |
| What *this* invocation would do to *this* Mac | `bash bootstrap.sh --plan` | writes nothing |
| Every file it would write, with hashes | `bash bootstrap.sh --manifest` | writes nothing |
| The default | `bash bootstrap.sh` | acts |
| A bigger set | `bash bootstrap.sh --profile standard` · `--profile full` | acts |
| Exactly these | `bash bootstrap.sh --only m1_statusline,m5_panes` | acts |
| Everything but that one | `bash bootstrap.sh --profile full --except m6_voiceink` | acts |

<!-- Diagram source: assets/diagrams/module-selection.mmd — edit it, run `npm run diagrams`, commit the SVGs. -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/diagrams/module-selection-dark.svg">
  <img src="assets/diagrams/module-selection-light.svg" alt="--profile full includes --profile standard, which includes --profile lite (the default). lite installs m1_statusline, m2_instructions, m3_hooks and m5_panes; standard adds m4_handoff and m7_model; full adds m6_voiceink and m8_screenshot. m4_handoff needs m1_statusline and m3_hooks, which are added out loud when missing.">
</picture>

Profiles are cut by blast radius; `lite` is the default because it is the largest set that asks
nothing of you and leaves nothing to clean up.

| Profile | You get | It costs |
|---|---|---|
| **lite** — the default | status line · instructions file · lifecycle hooks · ⌘⇧E pane equalize | config files only. No Homebrew, no permissions, no Apple ID, no network beyond the fetch — it asks nothing of you *once a terminal emulator is installed*, and records G12′ until one is |
| **standard** | + `/handoff` self-recycle · a local speech-rewrite model | Homebrew, tmux, a ~5 GB model download |
| **full** | + the VoiceInk build · the screenshot pipeline | Xcode ~9 GB and an Apple ID, plus two permission toggles only you can grant |

`--verify` re-reads the machine cold and changes nothing; `--uninstall` reverses a run. Dependencies
resolve themselves and say so (`note: m4_handoff needs m1_statusline — adding it`); an unknown module
name is refused with the list of real ones, so it never selects nothing and calls that success.

## 3. Run it, and read the exit code

`0` all satisfied · `10` satisfied but for steps waiting on **you** · `20` something failed, read the
log · `30` the run could not assemble itself, so it is *not* a verdict about your machine (precedence
`30 > 20 > 10 > 0`, install and verify alike). It is idempotent — **re-running it is the recovery
procedure** — and writes only to `$HOME/.mac-bootstrap/`.

### If an agent is already running, paste this

Replace `4918eee97f42684ad0565d4b5d4ae01bf79c2693` with the release commit — never `main`, whose
raw URL serves up to five minutes of stale CDN bytes (`cache-control: max-age=300`, measured). At
that pinned commit `bootstrap.sh` is 790 lines and `shasum -a 256` reads
`cfa5c3ed18a4b19256515d7a431bccbdbbc36940828232d312ee154c831f9beb`; step 1 shows you the checksum,
and anything else means stop. Fetched on its own it has no `modules/` beside it, so it makes a
second fetch, from the commit pinned *inside* it — which is this one's parent, because a commit
cannot contain its own sha. `scripts/release.sh --check` re-walks both hops anonymously, and CI
runs it on every push to `main`.

```text
You are setting up a Mac for an agent workflow. Work only in this terminal. Do not open a browser.

1. FETCH — never pipe a script into a shell. Save it, then show me its checksum and first lines:
     curl -fsSL -o /tmp/mac-bootstrap.sh https://raw.githubusercontent.com/renchris/mac-bootstrap/4918eee97f42684ad0565d4b5d4ae01bf79c2693/bootstrap.sh
     shasum -a 256 /tmp/mac-bootstrap.sh && wc -l /tmp/mac-bootstrap.sh && head -20 /tmp/mac-bootstrap.sh
   If the download fails or the file is under 100 lines, stop and tell me. Do not find another source.

2. LOOK before touching anything. These three write NOTHING:
     bash /tmp/mac-bootstrap.sh --list
     bash /tmp/mac-bootstrap.sh --plan
   Then tell me in at most five lines: what the default (lite) would install here, and what
   standard and full would add and cost. Read the costs off --list; do not invent them.

3. ASK me which profile, and wait. Recommend one and say why in a sentence, based on what this
   machine already has. If I have already told you, skip this step and use what I said.
   Profiles: lite (config only) · standard (+ self-recycle, + a local model) · full (+ app build,
   + screenshots). You can also propose --only or --except if some single module is the real fit.

4. RUN it with my answer, e.g.  bash /tmp/mac-bootstrap.sh --profile standard
   It is idempotent; running it twice is the recovery procedure. It does nothing irreversible:
   anything needing a GUI permission, a keychain entry, sudo, an Apple ID or money is recorded
   for me, never attempted.
   Exit 0 = every selected module satisfied. 10 = some need me. 20 = something failed.
   30 = the run could not assemble itself and says nothing about the machine — fix that first.

5. READ $HOME/.mac-bootstrap/receipt.json. For each module whose state is FAILED: read
   $HOME/.mac-bootstrap/bootstrap.log, say the cause in one line, fix it only if the cause is
   yours, then re-run `--only <module>`. Never retry a module unchanged.

6. ONLY IF m7_model is in the selection — your judgment call, and it is yours:
     sysctl -n hw.memsize ; sysctl -n machdep.cpu.brand_string
   At 16 GB or more use qwen3:8b. Under 16 GB do not guess: `--only m7_model --bench <model>`
   on two candidates and choose on the printed output. Tell me the pick in one sentence.

7. VERIFY, then REPORT and stop.
     bash /tmp/mac-bootstrap.sh --verify
   Line 1: what is installed and verified. Then, for each thing that needs me: one line of plain
   English, then its single command alone on its own line in backticks, executable as typed.
   If I should not run it, do not show it. Do not ask me to confirm steps 1-2 or 4-7.

In force throughout: never edit my agent's permission settings, allowlists or credentials — if you
need a permission, ask me in chat. Never run sudo without showing me the exact command and waiting
for my yes. If a step needs a GUI gesture (a macOS permission prompt, Keychain Access, the App
Store, an Apple ID), do not attempt it: name the exact gesture and move on.
```

The repo, SHA, `curl`, "never pipe into a shell", exit codes and safety clauses are inline **because
they are the root of trust**: a safety rule fetched from the thing being trusted is not one.
Everything else is fetched — inline text is re-paid on every paste.

### If not, four lines — and read it before you run it

```bash
curl -fsSL -o /tmp/mac-bootstrap.sh https://raw.githubusercontent.com/renchris/mac-bootstrap/4918eee97f42684ad0565d4b5d4ae01bf79c2693/bootstrap.sh \
  && shasum -a 256 /tmp/mac-bootstrap.sh \
  && less /tmp/mac-bootstrap.sh \
  && bash /tmp/mac-bootstrap.sh
```

Never `curl … | bash`. The `less` is the one second that makes this different from a pipe, and what
lets you re-read the exact bytes afterwards.

## 4. Close out what the receipt says is yours

`$HOME/.mac-bootstrap/receipt.json` carries every row below with its exact command; the driver
detected each and attempted none.

| | Gate | Exact gesture | Blocks |
|---|---|---|---|
| **G3** | Xcode itself, ~9 GB | App Store → Xcode → **Get** | m6 |
| **G4** | Xcode licence + developer dir | `sudo xcodebuild -license accept`, then `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` | m6 |
| **G4′** | **A code-signing identity** — a fresh Mac has none. An ad-hoc signature is silently revoked on every rebuild, taking Microphone and Accessibility with it, so the driver refuses to build without one | `bash ~/.mac-bootstrap/m6-signing-identity.sh` — written for you at the moment this row is recorded | m6 |
| **G5** | Keychain trust dialog — **may not appear** | If it does, type your login password. Re-running after a cancel is safe | m6 |
| **G6** | Gatekeeper first launch of Hammerspoon | System Settings → Privacy & Security → scroll to Security → **Open Anyway** → authenticate | m8 |
| **G7** | **Accessibility for Hammerspoon** — irreducible: `tccutil` only *resets*, and TCC writes are SIP-protected | System Settings → Privacy & Security → **Accessibility** → toggle **Hammerspoon** on. If absent: **+** → `/Applications/Hammerspoon.app` → Open | deliverable 5 entirely |
| **G8** | Screen Recording — believed unnecessary, never tested without it | Only if the thumbnail or copy fails after G7: Privacy & Security → **Screen Recording** → enable Hammerspoon → **restart it** | deliverable 5, maybe |
| **G9** | VoiceInk Microphone + Accessibility | Click **OK** on the Microphone prompt. Then Privacy & Security → Accessibility → **+** → `~/Applications/VoiceInk.app` → toggle on | deliverable 4 |
| **G10** | Transcription model, ~1.5 GB, in-app, no CLI path | VoiceInk → AI Models → download **parakeet-unified-0.6b** (English, ANE-resident, self-punctuating) or `ggml-large-v3-turbo` | deliverable 4 |
| **G11** | **Selecting the Ollama provider inside VoiceInk** — GUI-only. A `defaults write` is not sufficient and can be wrong: the provider resolves **per mode**, and the fallback takes the first connected one in declaration order, where a cloud provider sits 10 places ahead of Ollama | VoiceInk → Settings → AI Models → **Ollama → Connect** → pick `voiceink-rewrite`. If any cloud key is still in the keychain, **also** pin Ollama on the active mode: Settings → Modes → *your mode* → AI Provider | deliverable 4's whole point |
| **G12** | Relaunch iTerm2 — `NSUserKeyEquivalents` takes effect at the next launch | Quit and reopen iTerm2, split twice, drag a divider, press ⌘⇧E | deliverable 3 |
| **G13** | **Two observations no script can make**, both on Copilot | (a) look at the status line for one second — does a percentage appear? (b) take a ⌘⇧4, then press **Ctrl+V**, not ⌘V, in the agent — does an image attach? | the two UNPROVEN rows below |

## What you get, and the three places Copilot differs

All five work on Claude Code. On Copilot one is degraded and two are unproven — and both unproven
ones are G13, one second of looking each.

| # | Deliverable | Claude Code | Copilot 1.0.83 | Notes |
|---|---|---|---|---|
| **1** | context-% in the agent status line | **DELIVERED** | **DELIVERED — painting UNPROVEN** | Execution on Copilot is proven 39×; whether it *paints* our stdout nobody has observed. Copilot renders a status line only in the interactive TUI, never under `-p`. |
| **2a** | repo-agnostic instructions file | **DELIVERED** | **DELIVERED** | One `CLAUDE.md`, both agents measured loading it. The global tier is two paths bridged by one symlink: the content is one file, the paths cannot be. |
| **2b** | agent lifecycle hooks | **DELIVERED** | **DELIVERED** | Identical scripts, two wrapper files: Copilot accepts Claude Code's PascalCase event names as a documented compatibility surface. Its `PreToolUse` fails **closed**, so every exit path is an explicit `0`. |
| **2c** | self-recycle via `/handoff` | **DELIVERED** | **DEGRADED** | The *actuator* is identical and measured on both; the *typed gesture* is not. Copilot has no `/name` registration at all, so it is `/handoff` here and `copilot --agent handoff` there, and only the frontmatter description reaches Copilot's context. |
| **3** | ⌘⇧E evens out split panes | **DELIVERED** | **DELIVERED** | Terminal-level, no agent involved. kitty gets `equalize_on_window_close` — its own docs name the wrong option, and the wrong spelling is a silent no-op. iTerm2 gets an undocumented native menu item via `NSUserKeyEquivalents`: no Python API, no Hammerspoon, no Accessibility grant. |
| **4** | local VoiceInk build + rewrite model | **DELIVERED — gated** | same | Agent-independent; gated on Xcode, `cmake`, a codesigning identity and TCC prompts. Fully scriptable **except** G11 — which is the point, because a surviving cloud key otherwise wins the provider race silently. |
| **5** | ⌘⇧4 → thumbnail → clipboard → paste | **DELIVERED** | **UNPROVEN** | The ⌘V→⌃V eventtap is required in every design: an image-only clipboard has zero text flavour, so ⌘V is a silent no-op in kitty and iTerm2 alike. On Copilot two dated primary sources point opposite ways and nobody ran the path. |

The design predicted a further 2c degradation — one human paste per recycle — and the oracle refuted
it: `fire` runs preflight → seed → launch → prove-engagement → retire with no per-recycle gesture,
its eight negative arms shipping as a runnable control (`bash assets/succession/oracle.sh selftest`,
44 tests). `RETIRED` is reachable only from `ENGAGED`; a timeout leaves the predecessor **up**:

<!-- Diagram source: assets/diagrams/succession-state-machine.mmd — edit it, run `npm run diagrams`, commit the SVGs. -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/diagrams/succession-state-machine-dark.svg">
  <img src="assets/diagrams/succession-state-machine-light.svg" alt="Succession state machine: PLANNED to SEEDED on preflight passing, or to FAILED_PREFLIGHT with nothing moved; SEEDED to LAUNCHING or FAILED_SEED; LAUNCHING to LAUNCHED when the launcher returns, or to FAILED_LAUNCH when rc is 0 but the session is already gone; LAUNCHED to ENGAGED when the oracle proves a real turn, or to TIMEOUT_UNPROVEN where invariant I4 keeps the predecessor up at rc 3; ENGAGED to RETIRED, which invariant I1 makes the only edge into RETIRED; RETIRED to DONE once a detached reaper verifies. Full failure taxonomy in assets/succession/README.md.">
</picture>

## What it will not do

**It never writes your agent's permissions, allowlists or credentials** — no `permissions.allow`,
`settings.local.json`, `allowedTools`, `apiKeyHelper` or keychain entry: it refuses the write and
asks you in chat, because a tool that can widen its own permissions has no permission model. It
**attempts no GUI, sudo, App Store or paid step**, **pipes nothing into a shell**, and **writes
nothing inside this repo**. Every module verifies by **independent read-back** — parsing the plist
with `plutil`, running the script against a synthetic payload, reading the pane geometry — never by
grepping for a phrase it just wrote or trusting an installer's exit code.

`bootstrap.sh` is the only entry point and `CONTRACT.md` the module spec it obeys; `verify.sh`
re-verifies cold into `receipt.verify.json`; `scripts/release.sh` cuts a release and refuses to
call it one until it has fetched every module and asset back anonymously. Diagram sources are `assets/diagrams/*.mmd` (`npm run
diagrams` renders, `diagrams:check` fails CI on a stale SVG). MIT licensed.
