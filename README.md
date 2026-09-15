# mac-bootstrap

Sets a brand-new Mac up for an agent workflow that has to behave identically under **Claude Code**
and **GitHub Copilot CLI 1.0.83**.

**One command.** Paste it into Terminal. It shows every module with what it does and what it costs,
you pick, and it installs what you picked:

```bash
curl -fsSLo /tmp/mac-bootstrap.sh https://raw.githubusercontent.com/renchris/mac-bootstrap/0f46dc504439e4468b96d493efb3940ec59fd83c/bootstrap.sh && echo "097e980914be95c65288c4045d223a86b1a5b7dad30fd378768f7b29ce2a6414  /tmp/mac-bootstrap.sh" | shasum -a 256 -c - && bash /tmp/mac-bootstrap.sh
```

It checks the script's sha256 before running a line of it, and the script checks every file it then
fetches against a manifest of hashes inside itself — so that one hash covers the whole release, from
whichever host served it. It needs no administrator password, no Homebrew and no Xcode to start: a
module that needs one of those says so, installs what it can without it, and records the one step
that is yours. `curl … | bash` works too — the menu reads your terminal, not the pipe — but then
nothing checked the script first.

**One prompt**, if an agent is already running: [paste this](#if-an-agent-is-already-running-paste-this).
**Where your data goes:** `bash /tmp/mac-bootstrap.sh --egress` lists every host each module can reach
and then checks this Mac for anything that could send local data to a cloud AI service —
[details](#where-your-data-goes).

Readying a Mac is part files a script can write, part gestures only a person can make — twenty-one of
them plus one decision, and no script may take a single one for you. So the command drives every
drivable step, records each of the rest with its exact gesture, and a full install still leaves you
about four runs and roughly an hour, most of it waiting on Apple.

1. **[Clear the gates no script may pass for you](#1-clear-the-gates-no-script-may-pass-for-you)** → a Mac that can fetch, install and build
2. **[Decide what to install](#2-decide-what-to-install)** → a selection whose cost you know
3. **[Run it, and read the exit code](#3-run-it-and-read-the-exit-code)** → a receipt
4. **[Close out what the receipt says is yours](#4-close-out-what-the-receipt-says-is-yours)** → a verified machine

## 1. Clear the gates no script may pass for you

`lite` — the default — needs two: **`agent-logged-in`** and **`terminal-emulator`**. `agent_cli` installs
Claude Code and Copilot CLI for you, but only you can sign in to them, so the run exits `10` with the one
sign-in command until an agent is signed in. And an out-of-the-box Mac has only Terminal.app, which has no
equalize action, so `pane_equalize` has nothing to bind ⌘⇧E in; it records the gesture and the run exits
`10` until a terminal emulator exists. Every other row below is `standard` or `full`.
The driver detects and records each rather than attempting it, so doing them first only saves you a
re-run — and re-running after one is the recovery procedure, not a repair.

**You can skip both and start now.** On a Mac whose agents IT installs, or before you sign in:

```bash
bash bootstrap.sh --profile lite --except agent_cli,pane_equalize
```

exits `0` with the status line, the instructions file and the lifecycle hooks all live — no
Homebrew, no sudo, no gesture of any kind. Re-run plain `bash bootstrap.sh` whenever you like to add
the agents and ⌘⇧E.

**On a company Mac where you are not an administrator**, Homebrew's installer is not open to you, and
nothing below needs it: the modules fetch node, ollama and Hammerspoon themselves, as pinned downloads
checked against a sha256 in the repo, into `~/.mac-bootstrap/tools` and `~/Applications`. A step that
genuinely needs an administrator — the Xcode licence, an Accessibility approval, tmux — says so and
names IT, instead of handing you a command you cannot run. A policy IT set that switches a module off
(hooks reserved to IT, an MCP server not on its allowlist) is reported as yours to raise, never as
installed.

**Whether you *may* install a module there is a different question, and it is IT's.** `--list`, `--plan`
and the menu open with one line on what IT has on this Mac — MDM enrolment, endpoint-security
extensions (CrowdStrike, Defender, SentinelOne, Jamf Protect, Zscaler, …), Santa's mode — read with no
network and no password. Under it, every module that does something IT usually governs is marked `IT`
with a line per thing, by kind: **data** (work data copied onto this disk, outside your tenant's DLP,
retention and eDiscovery — the meeting archive and the shared-folder views do this), **background**
(a job at login or a local server), **trust** (a signing identity or keychain trust), **permission** (a
macOS privacy grant), **software** (an app or binary IT did not distribute), **agent** (something your
coding agent runs on its own). On a managed Mac, clear those with IT first. The run never refuses a
module on the strength of it — it tells you exactly what IT would be approving, and you decide.

Ordered by dependency: Homebrew installs the two below it, and nothing else here depends on
anything else here.

| | Gate | Exact gesture | Blocks |
|---|---|---|---|
| **`homebrew`** | Homebrew — **administrators only**, and optional: without it the modules use their pinned downloads | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` → RETURN → login password | cmake and tmux, which have no official download |
| **`cmake`** | **cmake** — absent from `/usr/bin`, from Xcode *and* from the CLT, all three probed | `brew install cmake` | the VoiceInk build; whisper.cpp will not build |
| **`tmux`** | **tmux** — macOS ships none, and it has no official download. Without it the drivers fall back to `direct` mode, where the successor dies with the terminal app; `/handoff` still works | `brew install tmux` where Homebrew exists; otherwise ask IT | `handoff`'s fault tolerance (`agent-handoff doctor` names it) |
| **`xcode-command-line-tools`** | Xcode Command Line Tools | if `/usr/bin/git --version` fails: `xcode-select --install` → **Install** → **Agree** | the VoiceInk build, and git everywhere — `/usr/bin/git` is an `xcrun` shim until these exist |
| **`terminal-emulator`** | **A terminal emulator** — a fresh Mac has Terminal.app and nothing else, so pane-equalize has nothing to bind. Which one is your call, so the module never installs one itself | the one command the receipt prints: iTerm2's own release into `~/Applications` for anyone, or `brew install --cask iterm2` for an administrator with Homebrew | ⌘⇧E pane equalize |
| **`agent-logged-in`** | **An agent signed in.** `agent_cli` installs Claude Code and Copilot CLI into `~/.local/bin` itself — no admin, no Homebrew, no node: each vendor's own signed binary, checked against a sha256 and a signing Team ID pinned in the repo. An agent already on the Mac is left as it is. `BOOTSTRAP_AGENTS=claude` or `copilot` installs one; `none` installs neither | The one command the receipt prints: `~/.local/bin/claude auth login` (browser sign-in) or `~/.local/bin/copilot login` (device flow). One signed-in agent satisfies the row | everything on the agent path |
| **`copilot-seat`** | ⛔ **A decision, not a gesture: has this Mac a Copilot seat?** Unanswerable from a shell | Only you know. If not, `COPILOT_PROVIDER_BASE_URL` documents *"GitHub authentication is not required"* — an unentitled Mac can still run `copilot` against local Ollama | the Copilot half of every row |

One question first: clean install, or Migration Assistant? Migration carries existing TCC grants,
agent config and app secrets across, so the two verify different things — and on a migrated Mac,
rotate any API key that rode along. It is now a key on two machines.

## 2. Decide what to install

These run against the script the one command saves; on the agent path, the prompt does this looking
for you and then asks which modules you want. The looking commands change nothing on your Mac — a
curl'd run keeps only its verified copy of the release, under `~/.mac-bootstrap/release/`.

| | Command | |
|---|---|---|
| What is on offer, and what each costs | `bash bootstrap.sh --list` | writes nothing |
| What *this* invocation would do to *this* Mac, in install order, and what IT would be approving | `bash bootstrap.sh --plan` | writes nothing; exits 10 when a row needs you |
| Every file it would write, with hashes | `bash bootstrap.sh --manifest` | writes nothing |
| Every host each module can reach, and a check that nothing here can reach a cloud AI service | `bash bootstrap.sh --egress` | writes nothing |
| This Mac's real budget for a local model, and which candidates fit | `bash bootstrap.sh --advise-model` | writes nothing |
| A menu: switch modules on and off, see the cost, confirm | `bash bootstrap.sh` in a terminal, or `--pick` | acts on what you confirm |
| The default, with nobody to ask (an agent, CI, output piped to a file) | `bash bootstrap.sh` | acts |
| A bigger set | `bash bootstrap.sh --profile standard` · `--profile full` | acts |
| Exactly these | `bash bootstrap.sh --only statusline,pane_equalize` | acts |
| Everything but that one | `bash bootstrap.sh --profile full --except voiceink` | acts |

<!-- Diagram source: assets/diagrams/module-selection.mmd — edit it, run `npm run diagrams`, commit the SVGs. -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/diagrams/module-selection-dark.svg">
  <img src="assets/diagrams/module-selection-light.svg" alt="--profile full includes --profile standard, which includes --profile lite (the default). lite installs statusline, instructions, hooks and pane_equalize; standard adds handoff, microsoft365, rewrite_model and reporting_off; full adds voiceink, screenshot, microsoft365_archive and shared_folders. handoff needs statusline and hooks, and microsoft365_archive needs microsoft365; each is added out loud when missing.">
</picture>

Profiles are cut by blast radius; `lite` is the default because it is the largest set that asks
nothing of you and leaves nothing to clean up.

| Profile | You get | It costs |
|---|---|---|
| **lite** — the default | Claude Code and Copilot CLI · status line · instructions file · lifecycle hooks · ⌘⇧E pane equalize | the two agents' signed binaries (downloads of ~200 MB and ~85 MB) and config files. No Homebrew, no permissions, no Apple ID — it asks one sign-in of you, and records `terminal-emulator` until a terminal emulator is installed |
| **standard** | + `/handoff` self-recycle · a local speech-rewrite model · Outlook mail and calendar for both agents · the agents' optional reporting switched off | Homebrew, tmux, node, a ~5 GB model download, one Microsoft sign-in |
| **full** | + the VoiceInk build · the screenshot pipeline · Teams meetings and Copilot chats archived as markdown · shared OneDrive/SharePoint folders linked into any repo | Xcode ~9 GB and an Apple ID, plus two permission toggles only you can grant; the archive reads only what your Microsoft tenant grants, and each shared folder needs the OneDrive app to sync it |

`--verify` re-reads the machine cold and changes nothing; `--uninstall` reverses a run. Dependencies
resolve themselves and say so (`note: handoff needs statusline — adding it`); an unknown module
name is refused with the list of real ones, so it never selects nothing and calls that success.

## 3. Run it, and read the exit code

`0` all satisfied · `10` satisfied but for steps waiting on **you** · `20` something failed, read the
log · `30` the run could not assemble itself, so it is *not* a verdict about your machine (precedence
`30 > 20 > 10 > 0`, install and verify alike). It is idempotent — **re-running it is the recovery
procedure** — and writes only to `$HOME/.mac-bootstrap/`.

### If an agent is already running, paste this

Replace `0f46dc504439e4468b96d493efb3940ec59fd83c` with the release commit — never `main`, whose
raw URL serves up to five minutes of stale CDN bytes (`cache-control: max-age=300`, measured). At
that pinned commit `bootstrap.sh` is 1368 lines and `shasum -a 256` reads
`097e980914be95c65288c4045d223a86b1a5b7dad30fd378768f7b29ce2a6414`; step 1 checks it,
and anything else means stop. Fetched on its own it has no `modules/` beside it, so it makes a
second fetch, from the commit pinned *inside* it — which is this one's parent, because a commit
cannot contain its own sha. `scripts/release.sh --check` re-walks both hops anonymously, and CI
runs it on every push to `main`.

```text
You are setting up a Mac for an agent workflow. Work only in this terminal. Do not open a browser.
SELECTION: ask
(Before pasting, you may replace "ask" with lite, standard, full, or modules such as
statusline,hooks,microsoft365 — then step 3 is skipped.)

1. FETCH — never pipe a script into a shell. Save it and check it; the check must print OK:
     curl -fsSL -o /tmp/mac-bootstrap.sh https://raw.githubusercontent.com/renchris/mac-bootstrap/0f46dc504439e4468b96d493efb3940ec59fd83c/bootstrap.sh
     echo "097e980914be95c65288c4045d223a86b1a5b7dad30fd378768f7b29ce2a6414  /tmp/mac-bootstrap.sh" | shasum -a 256 -c -
   If raw.githubusercontent.com cannot be reached, this is the one other source, under the same check:
     curl -fsSL -H 'Accept: application/vnd.github.raw' -o /tmp/mac-bootstrap.sh 'https://api.github.com/repos/renchris/mac-bootstrap/contents/bootstrap.sh?ref=0f46dc504439e4468b96d493efb3940ec59fd83c'
   If neither download works or the check does not print OK, stop and tell me. Never skip the check.

2. LOOK before touching anything. These change nothing on this Mac:
     bash /tmp/mac-bootstrap.sh --list
     bash /tmp/mac-bootstrap.sh --plan --profile full
     bash /tmp/mac-bootstrap.sh --egress
   Then tell me in at most eight lines: what each module does and costs (read it off --list; do not
   invent it), which ones this Mac already has (--plan says "already satisfied"), and what --egress
   found. --plan exits 10 and --egress 20 when they find something: those are findings to tell me,
   not errors — for --egress name the app and the setting, never read or print a key, and fix nothing.
   Read the THIS MAC line: if an organisation manages this Mac, list every module marked IT with its
   IT lines, and tell me to clear those with my IT team before I choose them.

3. ASK me which modules I want, and wait. Offer them as a numbered list with one line each, and
   recommend a set in one sentence. If the SELECTION line above is not "ask", or I have already told
   you, skip this step and use that: a profile name becomes --profile <name>, a list becomes --only.
   Do not use --pick: it is a menu for a person at a terminal, and you have none.

4. RUN it with my answer, e.g.  bash /tmp/mac-bootstrap.sh --only statusline,hooks,microsoft365
   If rewrite_model is in it, first run  bash /tmp/mac-bootstrap.sh --advise-model  (it changes
   nothing: this Mac's real budget for a model, which is not its RAM, and the candidates that fit,
   each marked measured-good, contested, unmeasured or measured-unfit), and add
   --model <the first candidate that is not measured-unfit>  to the run. Never pick on size.
   It can outlast your shell tool's time limit (the local model alone is a ~5 GB download), so start
   it in the background, keeping the Mac awake, and read the file until its last line is "exit N":
     (caffeinate -i bash /tmp/mac-bootstrap.sh <the flags> ; echo "exit $?") > /tmp/mac-bootstrap.out 2>&1 &
   It is idempotent; running it twice is the recovery procedure. It does nothing irreversible:
   anything needing a GUI permission, a keychain entry, sudo, an Apple ID or money is recorded
   for me, never attempted.
   Exit 0 = every selected module satisfied. 10 = some need me. 20 = something failed.
   30 = the run could not assemble itself; its last lines say why (a blocked host, a file that failed
   its check). Tell me that reason. Do not work around it.

5. READ $HOME/.mac-bootstrap/receipt.json. For each module this run judged ("this_run": true)
   whose state is FAILED: read
   $HOME/.mac-bootstrap/bootstrap.log, say the cause in one line, fix it only if the cause is
   yours, then re-run `--only <module>`. Never retry a module unchanged.

6. ONLY IF rewrite_model is in the selection — MEASURE the model you installed:
     bash /tmp/mac-bootstrap.sh --only rewrite_model --bench <tag>
   exits 0 on PASS, 1 on REJECTED, 2 if nothing was measured. On REJECTED, bench the next candidate
   in --advise-model's order and, when one passes, re-run step 4 for rewrite_model with its --model.
   If none passes, run  bash /tmp/mac-bootstrap.sh --uninstall --only rewrite_model  and say so.
   The whole procedure is the file --advise-model names on its last line.
   Tell me the pick in one sentence, with the exit code that decided it.

7. VERIFY, then REPORT and stop.
     bash /tmp/mac-bootstrap.sh --verify
   It re-reads every module installed here. Line 1: what is installed and verified. Then, for each
   thing that needs me: one line of plain English, then its single command alone on its own line
   in backticks, executable as typed. If I should not run it, do not show it. Do not ask me to
   confirm steps 1-2 or 4-7.

In force throughout: never edit my agent's permission settings, allowlists or credentials — if you
need a permission, ask me in chat. Never run sudo without showing me the exact command and waiting
for my yes. Never turn TLS certificate checks off (no curl -k, no NODE_TLS_REJECT_UNAUTHORIZED, no
strict-ssl false): if a certificate fails, tell me. Never add a cloud API key to anything. If a step
needs a GUI gesture (a macOS permission prompt, Keychain Access, the App Store, an Apple ID, the
Microsoft 365 sign-in, which is a code I type into a browser), do not attempt it: name the exact
gesture and move on.
```

The repo, SHA, `curl`, "never pipe into a shell", exit codes and safety clauses are inline **because
they are the root of trust**: a safety rule fetched from the thing being trusted is not one.
Everything else is fetched — inline text is re-paid on every paste.

### If not, the one command at the top

It saves the script, refuses to run it unless its sha256 is the one printed here, and then shows the
menu. To read it first, run the part before `&& bash` and then `less /tmp/mac-bootstrap.sh`.

**Behind a company proxy.** If the first download itself is blocked (proxies often block
`raw.githubusercontent.com` and allow the rest of GitHub), take the same bytes from GitHub's API — the
checksum, not the host, is what you trust:

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw' -o /tmp/mac-bootstrap.sh 'https://api.github.com/repos/renchris/mac-bootstrap/contents/bootstrap.sh?ref=0f46dc504439e4468b96d493efb3940ec59fd83c' && echo "097e980914be95c65288c4045d223a86b1a5b7dad30fd378768f7b29ce2a6414  /tmp/mac-bootstrap.sh" | shasum -a 256 -c - && bash /tmp/mac-bootstrap.sh
```

The script then tries GitHub's tarball host, git over github.com (when the Command Line Tools are
installed), and the raw host, in that order, and names why each one failed. If your proxy blocks all
three, that is usually IT's policy rather than an accident: ask IT whether this tool is allowed before
you route around it. Where it is, IT can mirror this repo at the release commit (`BOOTSTRAP_RAW=<the
mirror's URL for that commit>`) and the vendor downloads the modules pin — node, ollama, Hammerspoon,
iTerm2, kitty, the agents — at `<mirror>/<host>/<path>` (`BOOTSTRAP_ARTIFACT_MIRROR=<mirror>`, over
https or a carried folder as `file:///Volumes/…`). Nothing any of them serves is trusted by where it
came from: every file is checked against the manifest inside the script, every vendor download against
the sha256 its module pins, and one wrong byte stops that file with it named. A network that
inspects TLS with a certificate IT installed needs nothing from you; one whose certificate this Mac
does not trust is named, and the step is IT's.

## 4. Close out what the receipt says is yours

`$HOME/.mac-bootstrap/receipt.json` carries every row below with its exact command; the driver
detected each and attempted none.

Ordered the way the run surfaces them: the VoiceInk build's own chain first, then the
permission toggles, then the two things only your eyes can settle.

| | Gate | Exact gesture | Blocks |
|---|---|---|---|
| **`xcode`** | Xcode itself, ~9 GB | App Store → Xcode → **Get** | the VoiceInk build |
| **`xcode-licence`** | Xcode licence + developer dir | `sudo xcodebuild -license accept`, then `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` | the VoiceInk build |
| **`code-signing-identity`** | **A code-signing identity** — a fresh Mac has none. An ad-hoc signature is silently revoked on every rebuild, taking Microphone and Accessibility with it, so the driver refuses to build without one | `bash ~/.mac-bootstrap/voiceink-signing-identity.sh` — written for you at the moment this row is recorded | the VoiceInk build |
| **`keychain-trust`** | Keychain trust dialog — **may not appear** | If it does, type your login password. Re-running after a cancel is safe | the VoiceInk build |
| **`gatekeeper-hammerspoon`** | Gatekeeper first launch of Hammerspoon | System Settings → Privacy & Security → scroll to Security → **Open Anyway** → authenticate | the screenshot pipeline |
| **`accessibility-hammerspoon`** | **Accessibility for Hammerspoon** — irreducible: `tccutil` only *resets*, and TCC writes are SIP-protected | System Settings → Privacy & Security → **Accessibility** → toggle **Hammerspoon** on. If absent: **+** → `/Applications/Hammerspoon.app` → Open | `screenshot` entirely |
| **`screen-recording`** | Screen Recording — believed unnecessary, never tested without it | Only if the thumbnail or copy fails after `accessibility-hammerspoon`: Privacy & Security → **Screen Recording** → enable Hammerspoon → **restart it** | `screenshot`, maybe |
| **`voiceink-permissions`** | VoiceInk Microphone + Accessibility | Click **OK** on the Microphone prompt. Then Privacy & Security → Accessibility → **+** → `~/Applications/VoiceInk.app` → toggle on | `voiceink` |
| **`transcription-model`** | Transcription model, ~1.5 GB, in-app, no CLI path | VoiceInk → AI Models → download **parakeet-unified-0.6b** (English, ANE-resident, self-punctuating) or `ggml-large-v3-turbo` | `voiceink` |
| **`voiceink-ollama-provider`** | **Selecting the Ollama provider inside VoiceInk** — GUI-only. A `defaults write` is not sufficient and can be wrong: the provider resolves **per mode**, and the fallback takes the first connected one in declaration order, where a cloud provider sits 10 places ahead of Ollama | VoiceInk → Settings → AI Models → **Ollama → Connect** → pick `voiceink-rewrite`. If any cloud key is still in the keychain, **also** pin Ollama on the active mode: Settings → Modes → *your mode* → AI Provider | `rewrite_model`'s whole point |
| **`microsoft365-sign-in`** | **Signing in to Microsoft 365** — a device-code flow in your browser; the token it mints is a credential only you can create. A work tenant may refuse Softeria's app: then IT approves it, or registers its own and you re-run with `BOOTSTRAP_MICROSOFT_CLIENT_ID=<that app's id>`. IT's Conditional Access may block or flag a device-code sign-in (AADSTS530036): the receipt then offers the browser sign-in (`--auth-browser`) instead, and a tenant that demands token protection (AADSTS530084) cannot be met from any Mac — ask IT for an exemption | The one command the receipt prints (`… dist/index.js --login`) → open the URL → type the code → sign in with the work account → **Accept** | `microsoft365` |
| **`archive-account`** | **Which Microsoft account the archive reads as** — asked only when more than one account in the tenant is signed in, or the one recorded has signed out | Re-run with `BOOTSTRAP_MICROSOFT_ACCOUNT=<that account>`; the receipt names the candidates it found | `microsoft365_archive` |
| **`onedrive-shared-folder`** | **Syncing a shared folder with the OneDrive app** — sign-in and the folder choice are yours; a link to a folder no OneDrive root holds points nowhere | OneDrive signed in → on the SharePoint site, **Add shortcut to My files** (your own tenant) or **Sync** (a client's site, as their guest) → then `shared-folder add <link> "<folder path inside OneDrive>"` | `shared_folders` |
| **`relaunch-iterm2`** | Relaunch iTerm2 — `NSUserKeyEquivalents` takes effect at the next launch | Quit and reopen iTerm2, split twice, drag a divider, press ⌘⇧E | `pane_equalize` |
| **`look-and-paste`** | **Two observations no script can make**, both on Copilot | (a) look at the status line for one second — does a percentage appear? (b) take a ⌘⇧4, then press **Ctrl+V**, not ⌘V, in the agent — does an image attach? | the two UNPROVEN rows below |

## What you get, and the three places Copilot differs

All of them work on Claude Code. On Copilot one is degraded and three are unproven — two of them
`look-and-paste`, one second of looking each, and the third a first Outlook tool call.

| Module | Deliverable | Claude Code | Copilot 1.0.83 | Notes |
|---|---|---|---|---|
| `reporting_off` | the agents' optional reporting switched off | **DELIVERED** | **nothing to switch** | Claude Code's `/feedback` uploads the transcript, code included, kept five years, a survey follow-up can do the same, and error reports carry stack traces: all three are switched off in its settings' `env`, and Homebrew's install analytics are turned off when this user owns Homebrew. Its telemetry switch is deliberately left alone — it also removes Remote Control and auto mode. Copilot CLI has no user-level switch at all; `--egress` says so. |
| `statusline` | context-% in the agent status line | **DELIVERED** | **DELIVERED — painting UNPROVEN** | Execution on Copilot is proven 39×; whether it *paints* our stdout nobody has observed. Copilot renders a status line only in the interactive TUI, never under `-p`. |
| `instructions` | repo-agnostic instructions file | **DELIVERED** | **DELIVERED** | One `CLAUDE.md`, both agents measured loading it. The global tier is two paths bridged by one symlink: the content is one file, the paths cannot be. |
| `hooks` | agent lifecycle hooks | **DELIVERED** | **DELIVERED** | Identical scripts, two wrapper files: Copilot accepts Claude Code's PascalCase event names as a documented compatibility surface. Its `PreToolUse` fails **closed**, so every exit path is an explicit `0`. If a company policy reserves hooks to IT (`allowManagedHooksOnly`, `disableAllHooks`, `strictPluginOnlyCustomization`), read from the same files the agent reads, the row is `NEEDS_HUMAN` with the policy named — never a green over hooks that will not run; the same holds for `statusline`, `instructions` and `handoff`. |
| `handoff` | self-recycle via `/handoff` | **DELIVERED** | **DEGRADED** | The *actuator* is identical and measured on both; the *typed gesture* is not. Copilot has no `/name` registration at all, so it is `/handoff` here and `copilot --agent handoff` there, and only the frontmatter description reaches Copilot's context. The successor keeps the session's provider routing (`COPILOT_PROVIDER_*`, Bedrock, Vertex and its per-model regions, Foundry, the Claude model pins, the GitHub Enterprise host), proxy, CA and privacy variables — 46 of them, measured by its selftest — and never a credential. |
| `pane_equalize` | ⌘⇧E evens out split panes | **DELIVERED** | **DELIVERED** | Terminal-level, no agent involved. kitty gets `equalize_on_window_close` — its own docs name the wrong option, and the wrong spelling is a silent no-op. iTerm2 gets an undocumented native menu item via `NSUserKeyEquivalents`: no Python API, no Hammerspoon, no Accessibility grant. Found in `~/Applications` too; with no terminal emulator, a standard user is handed a command they can run, never `brew`. |
| `agent_cli` | Claude Code and Copilot CLI themselves | **DELIVERED — after your sign-in** | same | The vendors' own binaries — Claude Code from `downloads.claude.ai`, Copilot CLI from its GitHub release — into `~/.local/bin`, each kept only when its sha256 and its signing Team ID match the pins (Anthropic `Q6L2SF6YDW`, GitHub `VEKTX9H2N7`). A blocked download, or a binary this Mac refuses to run (Santa), is yours to raise with IT and names the host or signer; it adds `~/.local/bin` to your login shell's `PATH` only when it is not already there. Both agents update themselves afterwards. |
| `voiceink` + `rewrite_model` | local VoiceInk build + rewrite model | **DELIVERED — gated** | same | Agent-independent; gated on Xcode, `cmake`, a codesigning identity and TCC prompts. Fully scriptable **except** `voiceink-ollama-provider` — which is the point, because a surviving cloud key otherwise wins the provider race silently. `rewrite_model` is satisfied only when every enabled, enhancement-on mode is pinned to the local model **and** `assets/local-only-check.sh` finds no saved cloud key, cloud transcription model or cloud "Local CLI" template; it switches Ollama's cloud off (`disable_ollama_cloud`, confirmed by the server's own `/api/status`), refuses `:cloud` models, and installs ollama without Homebrew or admin from a pinned download. It also derives `local-agent`, the same model at 32k context, for an agent you point at this Ollama (`COPILOT_OFFLINE=true`, `COPILOT_PROVIDER_BASE_URL=http://127.0.0.1:11434/v1`, `COPILOT_MODEL=local-agent`): Ollama's default of 4,096 tokens below 24 GiB of GPU memory makes an agent call the wrong tool and still exit 0 (measured). |
| `microsoft365` | Outlook mail, calendar, contacts and OneDrive through a local MCP server | **DELIVERED — after your sign-in** | **REGISTERED — a live tool call UNPROVEN** | A node process each agent starts over stdio; it calls only `graph.microsoft.com` and `login.microsoftonline.com`, with no relay and no hosted part. Claude Code started it from the sandbox install and reported **Connected**; `copilot mcp get` reads the registration back **Enabled**. Tenant `organizations` by default (`BOOTSTRAP_MICROSOFT_TENANT` overrides it), and no `--org-mode`, whose Teams and SharePoint scopes need a tenant admin. **The agent drafts mail but never sends it on its own:** `guard-mail-send.sh` denies every tool that writes and sends in one call, and lets a draft be sent only in a later turn than the one that wrote it — measured live on both agents against a fake mail server. It also lets `graph-batch` through only when every batched request is a GET (a batched `POST /me/sendMail` used to pass it silently), and refuses `logout`, `remove-account` and `select-account`, which delete or switch the sign-in for every session sharing it. Whatever a tool returns still goes to the agent's model provider. |
| `microsoft365_archive` | Teams meetings and Copilot chats as one local markdown folder, refreshed hourly | **DELIVERED — what your tenant grants** | same — agent-independent | **These are copies on your disk, outside your tenant's DLP, retention and eDiscovery** — clear it with IT on a company Mac. `BOOTSTRAP_MICROSOFT365_ARCHIVE_SCHEDULE=off` installs it with no schedule, to run only when you start it. A LaunchAgent runs `microsoft365-archive run` hourly through the Softeria server your agent already signs in with — the one `microsoft365` installs or, when an agent already registers its own `ms365` in `$HOME/.claude.json`, that one, on that registration's node and tenant, read and never rewritten (`BOOTSTRAP_MICROSOFT_SERVER` names another; each is accepted only once it runs as the server) — so it reuses your sign-in and writes no credential. It enforces GET-only itself, since a launchd job never passes an agent hook. One folder per meeting occurrence (`meetings/YYYY/YYYY-MM/<date>_<time>_<subject>__<hash of iCalUId>/`), one markdown file per artifact, and an `index.md`. **Every artifact it cannot read is recorded with the reason, never skipped:** a personal account (measured live on 10 real meetings), the Copilot history API (measured live: HTTP 412, application permission only) and a meeting organized in another tenant (fixture-tested; Graph reaches only your own tenant's meetings, so a client's meeting is `external-organizer` and no request is made) each land as a status, and `index.md` names the grant that would unlock each. Transcripts need a tenant admin to switch on Graph transcript access and consent the meeting scopes; AI notes and Copilot history also need a Copilot licence. A second run over unchanged data rewrites no byte (measured on 10 real meetings). The archive folder is refused inside a sync client's folder, and uninstall never deletes it. |
| `shared_folders` | a shared OneDrive or SharePoint folder as a plain path in any repo, with markdown views | **DELIVERED — after the folder syncs** | same — agent-independent | `shared-folder add <link> <path>` makes a symlink into the OneDrive app's own synced copy, so there is no second copy to drift: the link *is* the source of truth, as current as OneDrive's sync. The OneDrive root's name carries your organization's name and moves on a rename or sync-engine upgrade, so every command re-finds the folder and relinks. `refresh` writes read-only markdown views to `<link>.views/`, keyed on each source's sha256, so an unchanged file is never rewritten and a stale view is counted by `check`. A file OneDrive has not downloaded is never opened, since reading it would pull the whole library; its view says so. Nothing is ever written inside the synced folder. Office and PDF views need `pandoc` or `markitdown`. |
| `screenshot` | ⌘⇧4 → thumbnail → clipboard → paste | **DELIVERED** | **UNPROVEN** | The ⌘V→⌃V eventtap is required in every design: an image-only clipboard has zero text flavour, so ⌘V is a silent no-op in kitty and iTerm2 alike. On Copilot two dated primary sources point opposite ways and nobody ran the path. Hammerspoon comes from Homebrew, or — for a standard user — as a pinned, checksummed download into `~/Applications` with no quarantine prompt; its crash reports to Sentry are switched off and read back. |

The design predicted a further `handoff` degradation — one human paste per recycle — and the oracle refuted
it: `fire` runs preflight → seed → launch → prove-engagement → retire with no per-recycle gesture,
its eight negative arms shipping as a runnable control (`bash assets/succession/oracle.sh selftest`,
44 tests). `RETIRED` is reachable only from `ENGAGED`; a timeout leaves the predecessor **up**:

<!-- Diagram source: assets/diagrams/succession-state-machine.mmd — edit it, run `npm run diagrams`, commit the SVGs. -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/diagrams/succession-state-machine-dark.svg">
  <img src="assets/diagrams/succession-state-machine-light.svg" alt="Succession state machine: PLANNED to SEEDED on preflight passing, or to FAILED_PREFLIGHT with nothing moved; SEEDED to LAUNCHING or FAILED_SEED; LAUNCHING to LAUNCHED when the launcher returns, or to FAILED_LAUNCH when rc is 0 but the session is already gone; LAUNCHED to ENGAGED when the oracle proves a real turn, or to TIMEOUT_UNPROVEN where invariant I4 keeps the predecessor up at rc 3; ENGAGED to RETIRED, which invariant I1 makes the only edge into RETIRED; RETIRED to DONE once a detached reaper verifies. Full failure taxonomy in assets/succession/README.md.">
</picture>

## Where your data goes

`bash bootstrap.sh --egress` writes nothing. It prints every host each module can reach — while it
installs, and afterwards — and then runs `assets/local-only-check.sh`, which trusts none of those
declarations: it reads this Mac's own settings and fails when anything a module set up could send
your data to a cloud AI service. A module that does not declare its hosts fails the report too.

| What leaves the Mac | To | Why it cannot be otherwise, or how it is switched off |
|---|---|---|
| What your agent reads | Claude Code → Anthropic, or whichever route your company set: Amazon Bedrock (`CLAUDE_CODE_USE_BEDROCK`), Google Vertex AI (`CLAUDE_CODE_USE_VERTEX`), Microsoft Foundry (`CLAUDE_CODE_USE_FOUNDRY`), or an LLM gateway (`ANTHROPIC_BASE_URL`). Copilot CLI → GitHub, or your GitHub Enterprise host where your company keeps data in a region (`GH_HOST` / `COPILOT_GH_HOST`), which routes to OpenAI, Anthropic, Google or xAI by the model you pick | That is how a coding agent works, and no module adds to it. `--egress` names the route each agent is on. To keep Copilot's context on this Mac, run it offline against the local model: `COPILOT_OFFLINE=true` with `COPILOT_PROVIDER_BASE_URL=http://127.0.0.1:11434/v1` and `COPILOT_MODEL`. `/handoff` carries every one of these routing variables into the next session and never a credential, so a successor cannot drift to a different provider |
| Your mail, calendar, files, meetings — `microsoft365`, `microsoft365_archive` | `graph.microsoft.com`, `login.microsoftonline.com`, and the SharePoint and OneDrive hosts Graph sends file downloads to: your own tenant | Reads only, GET-only in the archive. The agent drafts mail but never sends it, shares a file or forwards on its own |
| Nothing of yours: code coming in | GitHub (this release, every byte checked), the npm registry (the Microsoft server), Homebrew or the vendors' own pinned downloads (node, ollama, Hammerspoon), the Ollama registry (the rewrite model) | Install time only |

**Switched off by the modules that install them:** Ollama's cloud models and its calls to ollama.com,
Homebrew's install analytics, VoiceInk's update checks and announcements, Hammerspoon's crash reports.

**What the check fails on:** VoiceInk with any cloud provider selected in any enabled mode, or any cloud
key saved (all fifteen providers, custom endpoints, and the "Local CLI" templates, which run a cloud
agent); Ollama listening beyond this Mac, with its cloud switched on, or holding a cloud model; an agent
routed to a cloud AI host that is not its own vendor (a warning: routing your agent is your call).
It reads key NAMES and exit codes only — never a key.

**What no check here can see:** an endpoint on this Mac that itself relays to the cloud (a local proxy
in front of a cloud model), and Copilot CLI's own usage telemetry, which has no off switch short of
running it offline against a local model (`COPILOT_OFFLINE=true` with `COPILOT_PROVIDER_BASE_URL`).

## Not carried, by design

This repo is the **portable** part of one working setup, cut to what a stranger's Mac can use as it
is. What it leaves out, it leaves out on purpose:

| Left out | Why |
|---|---|
| Your agent's permissions, allowlists, trusted folders and credentials | They authorize the agent; a tool that could widen its own permissions has no permission model. Always yours, in chat |
| A personal fleet of hooks, skills, rules and plugins, and a long global instructions file | They encode one person's habits and account layout. It ships three hooks, one skill (`/handoff`) and a 6 KB repo-agnostic instructions file, and your own replace them freely |
| The agent launcher's own settings — model and effort defaults, auto-update pinning, subagent depth | Choices, not setup. The one place it pins an agent's auto-update is the successor `/handoff` starts, which must not change under a running chain |
| MCP servers other than Microsoft 365 (browser automation and the like), `gh`, git's global config, tmux's config, keyboard remappers | Each is a preference or a second vendor to trust; none is needed for the workflow here |
| A second model provider's CLI (Gemini, Codex) | Out of scope: the repo targets Claude Code and Copilot CLI, and a third agent is a third place your context goes |
| The Copilot half's baseline | There is none to copy: the Copilot configuration is designed to match the Claude one, row by row, as the table above shows — not taken from a Mac that ran it |
| The VoiceInk fork the original setup uses | This builds upstream VoiceInk v2.13, so what you install is what anyone can audit |

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
