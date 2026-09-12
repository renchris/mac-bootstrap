# mac-bootstrap

One entry point that sets a brand-new Mac up for an agent workflow which has to work the same under **Claude Code** and **GitHub Copilot CLI 1.0.83**.

---

## The one entry point

> It drives every drivable step and records the rest. **Expect about four runs and roughly an hour, most of it waiting on Apple.**

That sentence is the honest framing and it is deliberate. This is not "one command": it is one entry point wrapped around a worksheet of sixteen human gestures — TCC permission toggles, an App Store download, two in-app pickers — none of which a script may take on your behalf. The driver's job is to **detect and record** each one, never to attempt it. Everything else it does itself.

**Look before you leap — these three write nothing at all:**

| | |
|---|---|
| What is on offer, what each costs | `bash bootstrap.sh --list` |
| What *this* invocation would do to *this* Mac | `bash bootstrap.sh --plan` |
| Every file it would write, with hashes | `bash bootstrap.sh --manifest` |

**Then pick and choose:**

| | |
|---|---|
| The default — config files only, nothing to undo | `bash bootstrap.sh` |
| A bigger set | `bash bootstrap.sh --profile standard` · `--profile full` |
| Exactly these | `bash bootstrap.sh --only m1_statusline,m5_panes` |
| Everything but that one | `bash bootstrap.sh --profile full --except m6_voiceink` |
| Re-read the machine cold, change nothing | `bash bootstrap.sh --verify` |
| Reverse it | `bash bootstrap.sh --uninstall` |

Dependencies resolve themselves and say so (`note: m4_handoff needs m1_statusline — adding it`).
A module name that does not exist is refused with the list of real ones — it never selects nothing and calls that success.

### Profiles, cut by blast radius

| Profile | You get | It costs |
|---|---|---|
| **lite** — the default | status line · instructions file · lifecycle hooks · ⌘⇧E pane equalize | config files only. No Homebrew, no permissions, no Apple ID, no network beyond the fetch |
| **standard** | + `/handoff` self-recycle · a local speech-rewrite model | Homebrew, tmux, a ~5 GB model download |
| **full** | + the VoiceInk build · the screenshot pipeline | Xcode ~9 GB and an Apple ID, plus two permission toggles only you can grant |

The default is `lite` on purpose: it is the largest set that asks nothing of you and leaves nothing to clean up.

**Exit codes**, identical on the install and the verify path — `0` every module satisfied · `10` satisfied except for steps waiting on **you** · `20` something failed, read the log · `30` the run could not assemble itself, so it is *not* a verdict about your machine. Precedence `30 > 20 > 10 > 0`.

It is idempotent. **Re-running it is the recovery procedure.** Nothing is written inside this repo; all state lives in `$HOME/.mac-bootstrap/` (`receipt.json`, `bootstrap.log`).

---

## Path A — paste this into Claude Code or Copilot CLI

Replace `bd3f74ff41d10aaf285a0846b66d12d7c47b3986` with the release commit. Never `main`: a `main`-pinned raw URL serves up to five minutes of stale CDN bytes (`cache-control: max-age=300`, measured).

```text
You are setting up a Mac for an agent workflow. Work only in this terminal. Do not open a browser.

1. FETCH — never pipe a script into a shell. Save it, then show me its checksum and first lines:
     curl -fsSL -o /tmp/mac-bootstrap.sh https://raw.githubusercontent.com/renchris/mac-bootstrap/bd3f74ff41d10aaf285a0846b66d12d7c47b3986/bootstrap.sh
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

**Why the prompt says this much.** The repo, the SHA, the `curl` line, "never pipe into a shell", the exit-code contract, the receipt path and the safety clauses are inline **because they are the root of trust**. A safety rule that lived in the fetched file would be advice from the thing being trusted. Everything else — module bodies, the instructions artifact, hook definitions, model tables — is fetched, because inline text is re-paid on every paste and can only be fixed by you re-pasting it.

---

## Path B — no agent yet

The genuine first state of a new Mac has no agent logged in. Then:

```bash
curl -fsSL -o /tmp/mac-bootstrap.sh https://raw.githubusercontent.com/renchris/mac-bootstrap/bd3f74ff41d10aaf285a0846b66d12d7c47b3986/bootstrap.sh \
  && shasum -a 256 /tmp/mac-bootstrap.sh \
  && less /tmp/mac-bootstrap.sh \
  && bash /tmp/mac-bootstrap.sh
```

Fetch → checksum → **read it** → run. Never `curl … | bash`. The `less` is the point, not decoration: it is the one second that makes this different from a pipe, and it is what lets you re-read the exact bytes afterwards. `bash /tmp/mac-bootstrap.sh --verify` is the same verification the agent path uses.

---

## What must already be true before either path

The driver cannot install these; three of the four are browser or sudo gestures. Do them first.

| | Gesture | Why it must precede |
|---|---|---|
| 1 | **Homebrew** — `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`, press RETURN at its prompt, enter your login password | Blocks the VoiceInk, model and screenshot modules — and `node`, therefore Copilot itself |
| 2 | **Xcode Command Line Tools** — if `/usr/bin/git --version` fails: `xcode-select --install`, click **Install**, click **Agree** | `/usr/bin/git` is an `xcrun` shim until these exist; every git step raises a modal without them |
| 3 | **Agent installed** | see the two chains below |
| 4 | **Agent logged in** | a fresh config dir answers `Not logged in · Please run /login` at $0 — nothing in the prompt can run |

**Claude Code:** launch `claude`, type `/login`, finish the browser OAuth. Two gestures.

**Copilot CLI is four gestures deep, and this is the one most people get wrong** — macOS ships no `node`:

```
Homebrew  →  brew install node  →  npm i -g @github/copilot  →  copilot, then the device flow
```

The credential is the `gh` CLI keyring, so `gh auth login` also satisfies the last step. **One decision only you can answer: does the target Mac have a Copilot seat?** If not, `COPILOT_PROVIDER_BASE_URL` documents *"GitHub authentication is not required"*, so an unentitled Mac may still run `copilot` against local Ollama.

---

## The five deliverables, with honest status

| # | Deliverable | Claude Code | Copilot CLI 1.0.83 | Notes |
|---|---|---|---|---|
| **1** | context-% in the agent status line | **DELIVERED** | **DELIVERED — painting UNPROVEN** | One script, one alternation. Execution on Copilot is proven 39×; whether Copilot **paints** our stdout was never observed by anyone. Copilot renders a status line only in the interactive TUI, never under `-p`. |
| **2a** | minimal repo-agnostic instructions file | **DELIVERED** | **DELIVERED** | Identical at the repo tier — one `CLAUDE.md`, both agents measured loading it. The global tier is two different paths bridged by one symlink; the content is one file, the paths cannot be. |
| **2b** | agent lifecycle hooks | **DELIVERED** | **DELIVERED** | Identical scripts, two wrapper files. Copilot accepts Claude Code's PascalCase event names as a documented compatibility surface; the payload is field-for-field the same dialect. Copilot's `PreToolUse` fails **closed**, so every exit path is an explicit `0`. |
| **2c** | self-recycle via `/handoff` | **DELIVERED** | **DEGRADED** | The *actuator* is identical and measured on both. The *typed gesture* is not: Copilot has no `/name` registration at all, so you type `/handoff` in Claude Code and `copilot --agent handoff` in Copilot, and only the file's frontmatter description reaches Copilot's context. **The design predicted a further degradation — one human paste per recycle — and the shipped succession oracle refuted it:** `fire` runs preflight → seed → launch → prove-engagement → retire with no per-recycle gesture, and its eight negative arms ship as a runnable control (`bash assets/succession/oracle.sh selftest`, 44 tests). One-time setup gestures remain; `agent-handoff doctor` names them. |
| **3** | Cmd+Shift+E evens out split panes | **DELIVERED** | **DELIVERED** | Terminal-level, no agent involved. kitty gets `equalize_on_window_close` (kitty's own docs name the wrong option; the wrong spelling is a silent no-op). iTerm2 gets an undocumented native menu item bound via `NSUserKeyEquivalents` — no Python API, no Hammerspoon, no Accessibility grant. **A terminal emulator is not installed by this repo** — see G12′. |
| **4** | local VoiceInk build + local rewrite model | **DELIVERED — gated** | same | Agent-independent. Gated on Xcode, `cmake`, a codesigning identity and TCC prompts. The model half is fully scriptable **except** one GUI selection inside VoiceInk (G11) — which is the deliverable's whole point, because a surviving cloud key silently wins the provider race otherwise. |
| **5** | ⌘⇧4 → thumbnail → clipboard → paste into the agent | **DELIVERED** | **UNPROVEN** | On Claude Code the ⌘V→⌃V eventtap is required in every design: an image-only clipboard has zero text flavour, so ⌘V is a silent no-op in kitty and iTerm2 alike. On Copilot, two dated primary sources point opposite ways and nobody ran the path. |

### The two UNPROVEN rows are one second of looking each

Both are on the target machine, and neither is assertable from a shell. They are listed again as **G13** below.

1. Open the agent and **look at the status line**. Does a percentage appear? That settles deliverable 1 on Copilot.
2. Take a ⌘⇧4, then press **Ctrl+V** — not ⌘V — in the agent. Does an image attach? That settles deliverable 5 on Copilot.

---

## Every human gesture, in the order it occurs

Sixteen. The driver detects each one and writes it into `$HOME/.mac-bootstrap/receipt.json` with the exact command; it never attempts one.

| | Gate | Exact gesture | Blocks |
|---|---|---|---|
| **G0** | Homebrew | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` → RETURN → login password | m6, m7, m8, and `node` → Copilot |
| **G0b** | **cmake** — absent from `/usr/bin`, from Xcode *and* from the Command Line Tools, all three probed | `brew install cmake` | m6 (the whisper.cpp build dies without it) |
| **G0c** | **tmux** — macOS ships none, and the succession engine's fault tolerance IS the tmux substrate: without it the drivers fall back to `direct` mode, where the successor dies with the terminal app and the retire cannot be verified. You never interact with tmux; it is plumbing under `/handoff` | `brew install tmux` | deliverable 2c's fault-tolerance guarantee (`agent-handoff doctor` names it when absent) |
| **G1** | Xcode Command Line Tools | if `/usr/bin/git --version` fails: `xcode-select --install` → **Install** → **Agree**. The sudo path is `sudo softwareupdate -i "<the Command Line Tools label>" --agree-to-license` | m6, and git everywhere |
| **G12′** | **A terminal emulator** — a genuinely fresh Mac has Terminal.app and nothing else, so deliverable 3 has nothing to configure | `brew install --cask iterm2` (or kitty). The module records this rather than exiting clean having configured nothing | m5 |
| **G2** | Agent install + login | Claude Code: `claude` → `/login` → browser OAuth. Copilot: `brew install node` → `npm i -g @github/copilot` → `copilot` → device flow | everything |
| **G2′** | ⛔ **Decision, not a gesture: does this Mac have a Copilot seat?** | Only you know. Unanswerable from a shell — the credential lives in the `gh` keyring | the Copilot half of every row |
| **G3** | Xcode itself, ~9 GB | App Store → Xcode → **Get** | m6 |
| **G4** | Xcode licence + developer dir | `sudo xcodebuild -license accept`, then `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` | m6 |
| **G5** | Keychain trust dialog — **may not appear** | If a password dialog appears, type your login password. Re-running after a cancel is safe | m6 |
| **G6** | Gatekeeper first launch of Hammerspoon | System Settings → Privacy & Security → scroll to Security → **Open Anyway** → authenticate | m8 |
| **G7** | **Accessibility for Hammerspoon** — irreducible on an unmanaged Mac: `tccutil` only *resets*, TCC writes are SIP-protected | System Settings → Privacy & Security → **Accessibility** → toggle **Hammerspoon** on. If absent: **+** → `/Applications/Hammerspoon.app` → Open | deliverable 5 entirely |
| **G8** | Screen Recording — believed unnecessary, never tested without it | Only if the thumbnail or the copy fails after G7: System Settings → Privacy & Security → **Screen Recording** → enable Hammerspoon → **restart Hammerspoon** | deliverable 5, maybe |
| **G9** | VoiceInk Microphone + Accessibility | Click **OK** on the Microphone prompt. Then System Settings → Privacy & Security → Accessibility → **+** → `~/Applications/VoiceInk.app` → toggle on | deliverable 4 |
| **G10** | Transcription model, ~1.5 GB, in-app, no CLI path | VoiceInk → AI Models → download **parakeet-unified-0.6b** (English, ANE-resident, emits its own punctuation) or `ggml-large-v3-turbo` | deliverable 4 |
| **G11** | **Selecting the Ollama provider inside VoiceInk** — GUI-only. A `defaults write` is *not* sufficient and can be actively wrong: the provider resolves **per mode**, and the fallback returns the first connected provider in declaration order, where a cloud provider sits 10 places ahead of Ollama | VoiceInk → Settings → AI Models → **Ollama → Connect** → pick `voiceink-rewrite`. If any cloud key remains in the keychain, **also** pin Ollama on the active mode: Settings → Modes → *your mode* → AI Provider | deliverable 4's whole point |
| **G12** | Relaunch iTerm2 — `NSUserKeyEquivalents` takes effect at the next launch | Quit and reopen iTerm2, split twice, drag a divider, press ⌘⇧E | deliverable 3 |
| **G13** | **Two one-shot observations no script can make** | (a) look at the status line for one second; (b) ⌘⇧4 then **Ctrl+V** in the agent | closes the two UNPROVEN rows above |

**Before you start, answer one question:** is the target a **clean install** or was it set up by **Migration Assistant**? Migration copies `~/Library/Preferences` wholesale, which carries existing TCC grants, existing agent config and any existing app secrets across with it. Both cases work, but they verify different things — and on a migrated Mac you should rotate any API key that came along for the ride, since it is now a key on two machines.

---

## What this repo deliberately does not do

| It will not | Because |
|---|---|
| **Write your agent's permissions, allowlists, or credentials** | Authorization is yours. Nothing here edits a `permissions.allow` block, a `settings.local.json`, an `allowedTools` list, an `apiKeyHelper` or a keychain entry — the driver refuses the write and asks you in chat instead. A tool that can widen its own permissions has no meaningful permission model. |
| **Make you live inside a terminal multiplexer** | tmux is installed and used as an *invisible launch substrate* for `/handoff` only — a successor is born detached so it survives its predecessor, and you attach to an ordinary window. You never type a tmux command and your terminal keeps working exactly as it did. That is the measured basis of the fault-tolerance claim, not a workflow opinion: see G0c. |
| **Reproduce the source machine's fleet tooling** | Multi-account routing, dispatch, land gates, mailboxes and the rest are specific to one machine and one person. What is here is the portable intersection — five deliverables that work on any Mac, under either agent. |
| **Attempt any GUI, sudo, App Store or paid step** | Detect and record, never attempt. Every one is a row in the receipt with its exact command. |
| **Pipe anything into a shell** | Both paths fetch to disk, checksum, and let you read the bytes first. |
| **Write inside this repo** | All runtime state is under `$HOME/.mac-bootstrap/`. A stray working copy can never be committed. |

---

## Repo layout

| Path | What it is |
|---|---|
| `bootstrap.sh` | the driver — the only entry point |
| `verify.sh` | cold standalone re-verification; writes `receipt.verify.json`, never `receipt.json` |
| `CONTRACT.md` | the module spec: six verbs, no top-level side effects |
| `modules/mN_*.sh` | one deliverable each |
| `assets/` | bytes that land on the machine verbatim |
| `AGENTS.md` (= `CLAUDE.md`) | the instructions file an agent working *on this repo* reads |

Every module verifies by **independent read-back** — parse the plist back with `plutil`, execute the script against a synthetic payload, read the pane geometry — never by grepping for a phrase it just wrote, and never by trusting an installer's exit code.

## License

MIT.
