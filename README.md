<div align="center">

<img src="assets/AppIcon.png" width="128" alt="Claude Switcher">

# Claude Switcher

**Several Anthropic accounts on one Mac — and one shared `~/.claude`.**

[![CI](https://github.com/kevinchau/claude-switcher/actions/workflows/ci.yml/badge.svg)](https://github.com/kevinchau/claude-switcher/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/kevinchau/claude-switcher?label=release)](https://github.com/kevinchau/claude-switcher/releases/latest)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)

### [⬇︎ Download for macOS](https://github.com/kevinchau/claude-switcher/releases/latest/download/Claude.Switcher.dmg)

</div>

When one account hits its usage limit, the day stops. The usual workaround — a second config directory — gets you a second account by throwing away everything that made the first one useful.

Claude Switcher is a menu-bar app that runs multiple Anthropic accounts side by side on one Mac, in Claude Desktop (chat **and** the Code tab) and in the terminal `claude` CLI. Every account shares **one `~/.claude`**, so your memories, skills, subagents, plugins and settings follow you to all of them, and every session’s transcript stays in one place on disk. Hitting a limit costs you a menu click, not your setup. (Conversations are the exception: Claude keeps chats, and the Code tab’s session list, per account — see [§2.5](#25-the-code-tabs-session-list-is-per-account-the-transcripts-are-shared). A Code session can be [copied to another account](#copying-a-session-to-another-account), as a separate session.)

<p align="center">
  <img src="assets/two-claudes.jpg" width="480" alt="Office Space meme: &quot;Two Claudes, at the same time&quot;">
</p>

---

## Why this exists

Burn through your Fable quota and the rest of the week turns into pulling hairs: same questions, a lot more coaxing. A second account puts you back on Fable in one click.

<p align="center">
  <img src="assets/opus-vs-fable.jpg" width="400" alt="Two guys on a bus meme: &quot;me talking to Opus&quot; on the rock-wall side, &quot;me talking to Fable&quot; on the scenic side">
</p>

The advice you will find online is to point `CLAUDE_CONFIG_DIR` at a second directory per account:

```sh
alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'   # not what this tool does
```

Per [`RR()`](#21-the-config-dir-is-independent-of-the-electron-profile), that works — and it isolates **exactly the things you want to keep**: `projects/` (your session history), `history.jsonl`, `skills/`, `agents/`, `plugins/`, your memory and `CLAUDE.md`, `settings.json`, your MCP server config and your permission grants. Your second account starts as a stranger: no memory of your projects, none of your skills, none of your subagents, none of your tool permissions.

`claude-switcher` separates accounts along a different axis. The Electron profile (`--user-data-dir`) carries the *identity*; the Keychain slot (`CLAUDE_SECURESTORAGE_CONFIG_DIR`) carries the *terminal credential*; and `~/.claude` — everything you actually built up — stays shared across all of them. **Which is why this tool never sets `CLAUDE_CONFIG_DIR`, and why doing so would defeat its entire purpose.**

---

## What it looks like

The whole interface is one menu, plus a welcome window that points to it — here is the menu with two accounts running at once:

<p align="center">
  <img src="assets/menu.png" width="660" alt="The Claude Switcher menu with two accounts, Personal and Christy, both running">
</p>

The screenshot is from an earlier version: it still says “Profile”, shows the terminal sign-in on the account rows, and has no **Sessions** items, forecast lines or **Start a session in…**. The text below is the current menu.

Its structure as text — one row per account, a checkmark on the ones currently up;
under each account that has run, its usage bars, and under every account a grey forecast line (see [§2.10](#210-where-the-usage-bars-come-from))
and a **Sessions** submenu (see [Copying a session to another account](#copying-a-session-to-another-account));
and above the accounts, **Start a session in…**, which says which account a new session should go to ([Reading the forecasts, and where to start a session](#reading-the-forecasts-and-where-to-start-a-session)).
In the bars, `▰` is what Claude recorded, `▤` the lighter segment the switcher estimates on top of it from this Mac's activity since, and `▱` the rest; the percentage is always the recorded one. The numbers are examples:

```
Running: Personal
Start a session in…              ▸
──────────────────────────────
✓ Personal
    5h    ▰▰▤▤▱▱▱▱▱▱   22%   resets by 9:10 PM (est.)
    week  ▰▰▰▰▰▰▰▰▰▤   92%   resets Sat 9:00 PM · 2 h ago
    ~95% used (est.) · out about this eve
    Sessions                     ▸
  Work
    5h    ▱▱▱▱▱▱▱▱▱▱    0%
    week  ▰▰▰▱▱▱▱▱▱▱   31%   resets Mon 5:00 AM (est.) · 3 h ago
    ~28% unused by Mon 5 AM (est.)
    Sessions                     ▸
  Open Source
    No usage recorded yet (default)
    Sessions                     ▸
──────────────────────────────
Copy terminal command            ▸
Add Account…
Rename Account                   ▸
Remove Account                   ▸
──────────────────────────────
Choose Claude.app…
Reveal ~/.claude in Finder
Welcome…
Diagnostics…
Launch at Login
Reopen Accounts After Claude Updates
Block Claude Auto-Updates
──────────────────────────────
Keep Claude Switcher Up to Date
Check for Claude Switcher Updates…
──────────────────────────────
Quit Claude Switcher
```

Personal's week reset carries no `(est.)`: Claude Code recorded that exact time when the weekly limit was hit, and the schedule has been confirmed within the last two weeks. Work's was recorded too, but nothing has confirmed it for longer than that, so it is assumed to repeat and says `(est.)`; Personal's five-hour window end is estimated. Open Source has never run, so it has no bars, only its line.

**Start a session in…** picks an account for each length of session. In this example Personal is about to run out and Work has budget that would otherwise go unused at its reset; Open Source has never recorded anything, so it is offered short sessions only:

```
Short — under an hour → Work
  ~28% would go unused at its Mon 5 AM reset (est.); Personal cannot fit: ~0% of the week left (est.)
Medium — 1 to 3 hours → Work
  the only account it fits; Personal cannot fit: ~0% of the week left (est.)
Long — over 3 hours or a workflow run → Work
  the only account it fits; Personal cannot fit: ~0% of the week left (est.)
──────────────────────────────
Costs from your last 30 days (short 67, medium 16, long 59 sessions)
Reset times: Personal exact, Work estimated, Open Source not known yet · usage last recorded 2 h / 3 h / never ago
Open Source’s calibration uses defaults for Max 20x; its plan is unknown
```

Each row opens that account, as its own row in the menu does; the grey line under it is why, and hovering says more. `~0% of the week left` beside Personal's `~95% used` is not a slip: a clause about room gives the cautious figure the Advisor fits against — 100 less the upper bound of the estimate, after its margin — so it reads lower than the account's own line. The last footer line says that Open Source's calibration rests on the Max 20x defaults while its plan is unknown; the session costs above it are this Mac's own. Until the switcher has read this Mac's activity — on this Mac, a few seconds after the first launch — the submenu holds one line, `Reading activity…`, and so does the line under each account.

The terminal CLI's sign-in is shown in one place only, the **Copy terminal command** submenu (see [Terminal](#terminal)):

```
For the claude CLI in a terminal — it signs in separately from the Claude app.
Personal              signed in
Work                  no sign-in found
Open Source           no sign-in found
```

An account's **Sessions** submenu lists its Code-tab sessions, newest activity first, each badged `open` while a running Claude has it open and otherwise with how long ago it was last active; each row opens its copy choices. Here is Personal's, with one row opened — Open Source cannot take a copy right now, and says why:

```
Fix the flaky upload test                     open      ▸
Refactor the config loader                    3 h ago   ▸
    Copy to Work…
    Copy to Open Source…                      (greyed out)
    Claude in Open Source is signed out.
Untitled — scratch-notes                      2 d ago   ▸
──────────────────────────────
Not listed: 6 archived, 2 with no transcript on this Mac
```

After a copy, the other account's **Sessions** starts with a line for it until you have opened the copy in that account's Claude:

```
“Refactor the config loader (copy)” — copied 12 min ago, not opened yet
```

When Claude has downloaded an update it cannot install — see [§2.9](#29-updates-need-every-instance-to-quit) — two more lines appear under the header:

```
Running: Personal, Work
Claude 2.110.1 is downloaded but can't install until Claude has quit on every account.
Quit All & Install Update…
```

Claude Switcher updates itself, separately from Claude — see [Updating Claude Switcher](#updating-claude-switcher). When it has downloaded and verified a newer release of itself, a line under the header says it is waiting and a third item appears in its own section (the version numbers here and below are examples):

```
Running: Personal
Claude Switcher 0.8.0 is ready — it relaunches when nothing is going on
──────────────────────────────
  …
──────────────────────────────
Keep Claude Switcher Up to Date
Check for Claude Switcher Updates…
Update Claude Switcher to 0.8.0 & Relaunch
──────────────────────────────
Quit Claude Switcher
```

The same place under the header shows its progress — `Checking for Claude Switcher updates…`, then `Downloading Claude Switcher 0.8.0…` — and, while it replaces itself, `Updating Claude Switcher to 0.8.0 — it relaunches in a moment…`, in the line where `Starting Claude…` would be. If the new version is in place but could not be started, the line reads `Claude Switcher 0.8.0 is in place — it starts the next time Claude Switcher is launched`. After it has updated itself, the next menu open starts with one line, shown once:

```
Running: Personal
Claude Switcher updated itself to 0.8.0 at 3:14 PM.
```

And `claude-switcher --dry-run`, which prints the resolved launch plan and exits without launching or creating anything. Output from a run with Claude up on the default account and a second account `Work` configured, with the home directory rewritten to `/Users/me` (and the Keychain suffix recomputed to match, since it is `sha256` of that exact string — see [§2.7](#27-keychain-service-name-derivation)):

```
claude-switcher launch plan (dry run — nothing was launched or created)

Config file:  /Users/me/.config/claude-switcher/config.json
Claude.app:   /Applications/Claude.app
Shared dir:   /Users/me/.claude (shared by every account; CLAUDE_CONFIG_DIR is never set by this app)
Active account: default

Account "Personal" (id: default)  [default account]
  user data dir:   (none — the app's own default data dir)
  would create it: no
  argv:            (no arguments)
  new instance:    no (an instance for this account is already running)
  environment:     (inherited — no CLAUDE_* variables are ever injected)
  already running: yes (pid 4953) — would reopen its window and activate it instead of launching
  keychain item:   Claude Code-credentials  (terminal CLI only; existence check only — the secret is never read)
  terminal cmd:    claude
  usage:           5h 22% · week 92% · resets by 9:13 PM (est.) · week resets by Sat 10:09 PM (est.) · recorded 7:02 PM (2 h ago)  (read from this account's plan-usage-history.json; never fetched)
  update block:    off — Claude updates itself

Account "Work" (id: work)
  user data dir:   /Users/me/Library/Application Support/Claude-work
  would create it: yes (mkdir -p at launch time)
  argv:            "--user-data-dir=/Users/me/Library/Application Support/Claude-work"
  new instance:    yes (createsNewApplicationInstance — never focuses another account's window)
  environment:     (inherited — no CLAUDE_* variables are ever injected)
  already running: no — would launch
  keychain item:   Claude Code-credentials-1082021d  (terminal CLI only; existence check only — the secret is never read)
  terminal cmd:    CLAUDE_SECURESTORAGE_CONFIG_DIR="/Users/me/.claude-accounts/work" claude
  usage:           no data yet (recorded once Claude has run on this account)  (read from this account's plan-usage-history.json; never fetched)
  update block:    off — Claude updates itself
```

An account that closed itself for an update adds a `closed itself:` line ([§2.11](#211-after-an-update-claude-only-brings-back-the-default-account)). If any running instance matches no configured account, a trailing `Running instances matching no account:` block lists it by pid. A config that cannot be read is reported on stderr and exits `1`.

That sample predates the self-updater. A current build adds one line after `Claude.app:` (and `Update:`, when there is one) saying what this copy does about updating itself, read from its own `state.json` — nothing is fetched: `Claude Switcher: <version> — <what it does>; <last check> (a dry run fetches nothing)`, where *what it does* is `updates itself automatically`, `Keep Claude Switcher Up to Date is off; checks only when you ask`, or the reason it `never replaces itself` ([§2.14](#214-claude-switcher-updating-itself)).

It also predates the forecasts. A current build adds three lines after each `usage:` line and one `advice:` block after the accounts ([§2.10](#210-where-the-usage-bars-come-from)). They come from the switcher's activity index as it is on disk — a dry run never reads a transcript and writes nothing — so before the app has built the index they say only what was recorded. This is the real output on the Mac this README was written on, before the app had run with the Advisor, with the second account renamed `Work`:

```
Account "Personal" (id: default)  [default account]
  …
  usage:           5h 2% · week 93% · resets by 2:50 PM (est.) · week resets by Sat 9:00 PM (est.) · recorded 10:06 AM (3 h ago)  (read from this account's plan-usage-history.json; never fetched)
  forecast:        week 93% used (recorded) · 5h 2% used (recorded), clears by Tue 14:50 (est.) · estimates: needs the activity index (built when the app runs)
  schedule:        week resets by Sat 21:00 (Sun 04:00 UTC) — estimated, ±91 min (support 0.39; newest drop Oct 4 09:43) (A1, A8) · out-of-order samples 0 · 5h window: 10-min floor assumed (A3)
  calibration:     0.074 pts per unit (default) · window 0.30 (default) · plan: unknown (defaults assume Max 20x, A5) · costs: short 0.4/1.0 default, medium 2.1/3.1 default, long 6.7/12.6 (first 3 h 5.5/8.0) default (p50/p75 week points, defaults; A15)
  update block:    off — Claude updates itself

Account "Work" (id: work)
  …
  calibration:     0.074 pts per unit (default) · window 0.30 (default) · plan: Max 20x · costs: …
  update block:    off — Claude updates itself

advice: needs the activity index (built when the app runs)
```

Without the index the reset times come from the drops in the recorded figures alone, hence `estimated, ±91 min`. Personal's plan is `unknown` because the terminal CLI, whose config names the plan, is signed in to the other account (A5).

With an index less than an hour old, `forecast:` reads like `week ~62% used (0–72, est.) · pace 0.9 pts/h (6 h: 1.4) · runs out about Thu 18:00 (est.) · 5h 44% room, clears 21:10 (est.) · committed 0`, the schedule says `exact, fresh (4 anchors; last hit Oct 4 09:20)` once Claude Code has recorded the reset time, and `advice:` has one line per session size, such as `short   → Work       most headroom (~92% left, est.); Personal is projected to run out`. An index more than an hour old is not advised from: `advice: activity last read 26 h ago — open the Claude Switcher menu to refresh it`. The app brings the index up to date when it starts and whenever its menu opens, so with the app running but its menu left closed for an hour, `--dry-run` says this too.

---

## Install

### Download the app

**[⬇︎ Claude Switcher.dmg](https://github.com/kevinchau/claude-switcher/releases/latest/download/Claude.Switcher.dmg)** — open it and drag Claude Switcher to Applications.

Signed and notarized, so it just opens. Needs macOS 14+ and Claude Desktop.

From the first release that has the updater, a downloaded copy in `/Applications` (or `~/Applications`) keeps itself up to date — see [Updating Claude Switcher](#updating-claude-switcher). Releases up to and including 0.7.0 have no updater: the first release with one is installed by hand, like this, and only the releases after it arrive on their own.

### Or build it from source

```sh
git clone https://github.com/kevinchau/claude-switcher.git
cd claude-switcher
make install
```

`make install` builds the release binary, assembles `build/Claude Switcher.app`, signs it, and copies it to `/Applications`. That is the only thing the build system touches outside the working tree — it never modifies the `Claude.app` bundle, and it never writes `~/.config/claude-switcher/config.json` (only the running app does that). Launch at Login is *not* enabled by installing; it is a menu-bar toggle.

A source build is signed with your own Developer ID certificate if you have one, and **ad-hoc** otherwise — an ad-hoc app runs only on the machine that built it, which is fine when that machine is yours. See [Signing and distribution](#signing-and-distribution).

A source build never replaces itself with a release: an ad-hoc one has no developer team to check a release against, and `make install` signs but does not notarize, which the updater requires of the copy it would replace ([§2.14](#214-claude-switcher-updating-itself)). The same goes for `build/Claude Switcher.app` and anything else outside `/Applications` and `~/Applications`, however it is signed. Such a copy still checks when you ask.

| | |
| --- | --- |
| Toolchain | Swift 6 (Xcode 16+); developed against Swift 6.3.3 |
| Dependencies | None. Apple's frameworks only (AppKit, Foundation, Security, CryptoKit and a few more), no Xcode project. |

### Launched it and nothing happened?

Claude Switcher has no Dock icon: it lives in the menu bar, as a two-person icon (`person.2.circle`) near the clock. The first launch opens a **welcome window** that says so, explains what an account is and that `~/.claude` stays shared, and offers **Add Account…**, **Show Menu** and **Done**. It does not open on its own for anyone who already has two or more accounts configured, and whether it has been shown is remembered in the app's own `UserDefaults`, not in `config.json`.

If the icon is not there, macOS is hiding it — because the menu bar is full (quitting a menu-bar app or two makes room), or, on macOS 26, because it is switched off in **System Settings › Menu Bar › Allow in the Menu Bar**. Either way, **open Claude Switcher again**: while it is running, that always brings the welcome window back, and its **Show Menu** button opens the same menu right there. The window is also in the menu, as **Welcome…**.

---

## Usage

### Desktop

Each account in the menu is a separate Anthropic login.

1. Open the menu-bar item and choose **Add Account…** (the welcome window has the same button). Give it a label (e.g. `Work`). The tool derives a slug id — **lowercased**, non-alphanumerics collapsed to `-` — and assigns `userDataDir = ~/Library/Application Support/Claude-<slug>` and `credDir = ~/.claude-accounts/<slug>`. Adding it **launches it immediately**: `addProfile` calls the same launch path the menu rows use, so `Claude.app` comes up right away as a second, concurrent instance with a fresh Electron profile and you land on its sign-in screen. There is no second step of finding the new account in the menu. (The alert says so before you confirm.)
2. **Sign in once, interactively, in that window.** The tool never touches credentials — you log in yourself, exactly as you would on a new Mac.
3. From then on, picking that account brings its window to the front if it is running — reopening the window if you had closed it, since Claude keeps running without one — or launches it if it is not. The default account is launched with no `--user-data-dir` argument, which selects the app's own profile directory — but it is still launched as a *new* instance whenever no instance matching it is running (see [§2.8](#28-what-the-tool-actually-does-with-all-this)).

Both accounts stay up at the same time — no quitting, no logging out, no waiting — and there is nothing special about the number two: add as many as you have. Every instance sees the same `~/.claude`, so the same skills, agents, plugins, memory and settings are there on all of them. The Code tab’s session list is not: Claude Desktop keeps it per account ([§2.5](#25-the-code-tabs-session-list-is-per-account-the-transcripts-are-shared)). To carry a session over, copy it ([below](#copying-a-session-to-another-account)).

### Terminal

The Desktop account is chosen by `--user-data-dir`; the **terminal CLI** account is chosen by `CLAUDE_SECURESTORAGE_CONFIG_DIR` (see [§2.6](#26-the-terminal-cli-is-a-separate-story)). **Copy terminal command** puts the right invocation on the pasteboard:

```sh
# default account — the variable is OMITTED, never set to ""
claude

# any other account
CLAUDE_SECURESTORAGE_CONFIG_DIR="/Users/me/.claude-accounts/work" claude
```

The first run for a new credential dir will be logged out; sign in interactively, once. The submenu's badges say which accounts' terminal slots are signed in. `~/.claude` is shared either way, so your history, skills and memory come along.

### Copying a session to another account

Claude keeps the Code tab's session list per account, so a session started on one account is not in another's list ([§2.5](#25-the-code-tabs-session-list-is-per-account-the-transcripts-are-shared)). Its transcript is in the shared `~/.claude`, though, and Claude Desktop's own fork already makes a separate session out of one — but only within one account. Claude Switcher makes the same kind of copy into another account ([§2.13](#213-copying-a-session-to-another-account)).

1. Open the account's **Sessions**, point at a session, and choose **Copy to *Work*…**.
2. Read the confirmation — it says what the copy is and is not — and click **Copy**. Nothing is written before that.
3. When the other account's sessions are idle, quit its Claude yourself (Claude › Quit) and open it again from the switcher. The copy should then be in its Code tab as *“title (copy)”* (not yet confirmed against a live Claude — [§2.13](#213-copying-a-session-to-another-account)).

**What the copy is.** A separate session, as the original is at that moment: a new session id, a new transcript next to the original's in `~/.claude/projects`, and a new entry in the other account's list. Later messages in either are not added to the other. The conversation comes across byte for byte up to its last complete line, with the transcripts of the subagents it used, its title (as `title (copy)`, then `(copy 2)`, `(copy 3)`…), its model, its effort setting and its working folder.

**When it shows up.** The next time that account's Claude starts — not before. Claude reads an account's session list when it starts; closing the window or **View › Reload** does not read it again ([§2.13](#213-copying-a-session-to-another-account)). **Claude Switcher will not quit Claude for you.** If that account's Claude is running when the copy finishes, the result says so. Until you have opened the copy there, the other account's **Sessions** begins with a line for it — `“title (copy)” — copied 12 min ago, not opened yet` — which goes once Claude has rewritten the copy's record, as it does the first time the session is viewed, or once the record is gone. **Diagnostics…** counts these copies too, and lists any copy that has not finished.

**What does not come across.**

- **Permission mode.** The copy is filed in mode **Default**; Claude Code may restore the original's mode when it first starts the copy (not yet checked against a live Claude — [§2.13](#213-copying-a-session-to-another-account)).
- **Grants and connections.** Allowed-tool grants, connectors (the other account's own apply), Remote Control, and browser-action permission (the copy asks per site).
- **Saved tool outputs and uploads** from before the copy: the conversation still points at the original's, and they disappear if the original is deleted.
- **Rewind points** from before the copy carry over only if the original still exists when the copy is first continued. Keep the original until you have opened the copy — until then nothing renews the copy's files either ([Caveats](#caveats-and-limitations)).

Also worth knowing: both sessions work in the same folder, and each can change or undo the other's file edits. If the other account's plan lacks the original's model, the first reply is a model error — pick another with `/model`; the first reply may also be slower than usual. A copy taken just after Claude was working may end mid-turn, and that turn shows as interrupted. A session Claude has hidden from history stays hidden in the copy.

**What cannot be copied.** A session that cannot be copied anywhere says **Can’t be copied** and why, in its own submenu. A reason that concerns one account greys out that **Copy to …** item and says why under it. Every refusal is one of these:

| Not copied | Why |
| --- | --- |
| Archived or remote (SSH, WSL) sessions, and sessions with no transcript on this Mac | Not listed at all; the submenu's last line counts them. A remote session's files are on another machine. |
| A session with no conversation yet, or no complete line in its transcript | There is nothing to copy yet. |
| A session in a git worktree — named in its record, under `.claude/worktrees`, or still bound in its transcript | The copy would share the worktree, and deleting or archiving either session can remove it, uncommitted work included. Claude Code re-enters a worktree bound in the transcript when the session resumes. |
| A session in a scratch workspace | Claude removes that folder when the session is deleted. |
| A session that has moved away from the folder it started in | Claude treats the starting folder as the base repository, deleting branches there. |
| A session that spans several transcripts (after a clear, a rewind or an unarchive) | Its record names more than one; a copy takes exactly one. |
| A session whose folder is gone, that Claude Switcher cannot look at (no permission on a folder above it), or not recorded as a full path | The copy runs in that same folder. |
| A session whose title or folder contains its own session id | The copy's record must not carry the original's id. Rename the session in Claude to copy it. |
| A session Claude is still replying in, or whose transcript keeps changing | The copy would end mid-reply. A read the file changed during is retried for five seconds. |
| A session watching an artifact's comments | Claude Code restores the watch when the session resumes; what it would do under another account was not traced. Stop the watch first. |
| A session whose Remote Control state cannot be cleared as Claude clears it, or with an unreadable line about Remote Control, a worktree or a watch | What the copy would inherit cannot be checked. |
| A session Claude has marked deleted | A copy would bring back what you deleted. |
| A session already registered in two accounts | Deleting it in either removes it from both ([Caveats](#caveats-and-limitations)). |
| A target that is signed out or has never been signed in | Claude loads only the signed-in account's sessions, so a copy filed elsewhere would stay invisible. |
| A target signed in to the same account as the source | There is no other account to copy into. |
| A target whose account has no Code sessions yet, or none in its current organisation | Claude makes the folder with the first session; start one there first. |
| A target whose account has several organisations | Which one is current is kept only in an encrypted cookie, which Claude Switcher does not read ([§2.13](#213-copying-a-session-to-another-account)). |
| A target that uses the same data folder, or that changes account or organisation during the copy | The record is not filed. |
| On the way to the session's files: a symbolic link anywhere from your home folder down — a symlinked `~/.claude` included — a folder or file owned by another user, or a folder others can write to | Claude Switcher does not follow links or write there ([§2.13](#213-copying-a-session-to-another-account)). Such a session is listed, not copied, and the message says it is the session's files. |
| The same on the way to the other account's Claude data folder — a link anywhere from your home folder down to its session folder (a data folder spelled through a link outside your home folder that leads back into it included), a folder of another user, or a session folder others can write to | The same rule; the message names that account's data folder, not the session's files. |
| Less free space than the copy plus 1 GB, a disk that cannot rename exclusively, something already at the copy's new name, or a session store that cannot be read | A copy must never replace anything: it needs room to spare, a rename that refuses to overwrite, and a new name provably unused in every store on the Mac. A store folder that cannot be read greys out every **Copy to …** item, and **Diagnostics…** names it. |
| Claude Switcher's own settings folder (`~/.config/claude-switcher`) on a disk that cannot rename exclusively | The copy's journal is put in place with the same exclusive rename. |
| Another copy in progress, another Claude Switcher running (copy from that one), or a lock file in `~/.config/claude-switcher` that cannot be taken at all | One copy at a time, only in the switcher that holds the automation lock. Each case has its own message. A recovery pass under way is waited for, not refused. |

A copy that is interrupted — a crash, a power cut, a forced quit — is finished or cleaned up the next time Claude Switcher starts — or, when it cannot prove a leftover is its own, left exactly as it is — and a line near the top of the menu says which ([§2.13](#213-copying-a-session-to-another-account)).

### Reading the forecasts, and where to start a session

The percentage beside each bar is what Claude last recorded for that account. Everything else about usage in the menu — the lighter part of a bar, the grey line under the bars, and **Start a session in…** — is an estimate: the switcher reads this Mac's Claude Code transcripts (token counts and times, nothing else) and works out how far each account has probably got since Claude's last recording, how fast it is going, and when its limits reset. It is a model of Anthropic's limits, calibrated on the two Max 20x accounts it was built on, and it says so wherever it is used: a number that is not recorded says `(est.)` — or `(default)` while it rests on defaults — and so does every time Claude Code did not record, in the bars, the lines, **Start a session in…** and Diagnostics alike. The lighter part of a bar is drawn, not written; its tooltip gives its number with `(est.)`, and VoiceOver reads it as *estimated*. [§2.10](#210-where-the-usage-bars-come-from) says how it works and what each assumption is.

**The grey line** under each account is its week at a glance. It is at most 40 characters, and when it is an estimate its `(est.)` ends within the first 32, so a narrow menu can cut the end of the line but not the hedge. Hover the bars or the line for the whole picture: what was recorded and when, what the lighter part of each bar stands for and its number, the estimate and the range it certainly lies in under the assumptions, the pace, where the reset time comes from, and the assumptions it rests on.

| Line | What it says |
| --- | --- |
| `~95% used (est.) · out about this eve` | At the faster of this week's pace and the last six hours', the weekly limit will be reached before the reset — about then. |
| `~28% unused by Mon 5 AM (est.)` | At that pace, this much of the week will still be unused when it resets. |
| `~64% now (est.) · recorded 0% 33 h ago` | Claude's last recording is an hour or more old and at least 5 points below what this Mac has spent since. |
| `~13% now (est.) · not recorded this week` | Nothing has been recorded since the weekly reset; the figure is this Mac's activity since it. |
| `~4% used (est.) · little use this week` | Too little to project from: more than 12 hours into the week, under 10 % used, and nothing in the last six hours. |
| `Too early to tell — 4 h into the week` | Under 12 hours into the week, with no pace yet. |
| `~100% used (est.) · likely at the limit` | The estimate has reached the limit, though Claude has not recorded it. |
| `Week limit reached — resets Sat 9 PM` | Recorded at the limit (a sample at 100, or a limit hit Claude Code recorded); the reset time is exact and fresh. `Limit reached — resets (est.) Sat 10 PM` when it is not. |
| `5h window full — clears 9:10 PM` | The five-hour window is recorded full and Claude Code recorded when it ends. `5h full (est.) — clears 9:10 PM` when only the end is recorded; `5h full (est.) — clears by 9:13 PM` when the end is estimated too. |
| `Fable limit reached — until Sat 9 PM` | Claude Code recorded a hit on the Fable-only weekly limit (or a per-model one): medium and long sessions are not advised there until then. |
| `Reset time not known yet (est.)` | No weekly reset has been seen for this account, so its week cannot be projected. |
| `No usage recorded yet (default)` | Claude has never recorded this account's usage; its figures are defaults. |
| `Reading activity…` | The activity index is being read; recorded values only, nothing estimated. |

**Short, medium and long** are how long you expect the session to run: short under an hour, medium one to three hours, long over three hours — or a *workflow run*, a session in which subagents make at least half of the spend, whatever its length. What each size costs is measured from this Mac's own sessions of the last 30 days, once a size has eight of them (until then, defaults — the footer says which); the cost that must fit is the 75th percentile, which three sessions in four of that size did not exceed. A long session is judged on its first three hours, and its five-hour window on its first hour; its whole cost decides whether the row warns that it will likely stop at the limit part-way.

**Choosing a row** opens that account exactly as its own row in the menu does: it brings that account's Claude to the front, or starts it. It does not start a session — you do, in that window. A row is greyed out while an account is starting or when `Claude.app` is missing (as the account rows are), when nothing fits, and — `→ Personal after 9:10 PM (est.)` — until that account's five-hour window clears; if the menu is open then, the row turns on by itself. The time carries `(est.)` unless Claude Code recorded when that window ends.

**What the reasons mean.** The grey line under a row says what decided it, then, after a semicolon, one thing about an account it did not choose — never the account the reason itself has just named:

| Reason | Meaning |
| --- | --- |
| `~28% would go unused at its Mon 5 AM reset (est.)` | At its pace that account will not use this much of its week before the reset: use it or lose it, so it goes first. |
| `most headroom (~92% left, est.)` | No account it fits is projected to leave 5 points or more unused, and this one's pace is not known yet; of those, it has the most room left. |
| `resets soonest (Sat 9 PM)` | Every account it fits will use all but a few points of its week before the reset anyway, so the one that resets first goes first: what is spent there comes back soonest (A13). `(Sat 10 PM, est.)` when that reset time is not exact and fresh. |
| `comfortable margin; Personal has only ~9% left (est.)` | Medium or long, in the same case: an account with at least twice the session's cost left goes before a thin one (A13). |
| `the only account it fits` | No other account can take this session and still leave a reserve. |
| `keeps Work in reserve` | Work would rank first, but sending the session there would leave no account with room for two short sessions, so Work stays the reserve. |
| `reset time not known yet — recorded 3% used 2 h ago` | The account's weekly reset has not been seen; the recorded figure is a floor. |
| `no usage recorded yet — a short session records it` | A new account: on defaults, short sessions only. |
| `still Work — chosen 40 min ago; nothing has changed enough to switch` | An earlier choice that still fits — or falls short of fitting by less than a point, a wobble of the estimate between reads — is kept until another account would save at least 10 more points from going unused, the earlier one has to wait for its window while the other need not, or a weekly reset has passed on either. An account that will run out saves nothing, however far short it falls, so two accounts that both run out do not trade places on the difference. The tooltip gives the original reason. |
| `→ Personal (likely hits the limit about Wed morning)` with `the first 3 hours fit; Work keeps ~28% in reserve` | A long session that will likely stop at the limit part-way, placed where the reserve still holds (A14). When it will likely stop sooner than that, the reason says so: `about the first 2 h fit`, or `likely stops within the first hour`. |
| `→ Personal after 9:10 PM (est.)` with `its 5-hour window is full until then` | Medium or long only: the window clears within 15 minutes. `has too little room until then` when some room is left; no `(est.)` when Claude Code recorded the end. |
| `→ Work (last headroom)` with `this would leave no account in reserve` | Short only: no account can take it and keep a reserve, so the one with the most room is offered. |
| `→ nothing fits right now` with `both accounts are at or near the weekly limit; next chance Sat 9 PM when Personal resets` | Nothing can take it (short sessions get *last headroom* first). When the accounts are in the way for different reasons, each is named: `Personal is at or near its weekly limit; Christy’s 5-hour window has too little room; next chance 8:22 PM (est.) when Christy’s window clears`. The next chance is the earliest moment at which, on some account, everything in the way has lifted: a weekly reset, given to the hour and rounded up so that it stays a bound; or a window clearing or a limit ending, to the minute, as the account's own bar note gives it. Any of them Claude Code did not record says `(est.)`. |

The clause about another account is one of: `fits too (~40% left, est.)`, `is projected to run out`, `fits the first 3 h only (~28% of the week left, est.)`, `cannot fit: ~6% of the week left (est.)`, `’s 5-hour window is full until 9:10 PM (est.)` — or `has too little room (~24% left, est.) until …` while some is left; *full* only at none — `would leave no reserve`, `: Fable limit reached until Sat 9 PM`, `: a session is already running there (~20% committed, est.)`, `: not enough usage history yet`, `: no usage recorded yet — short sessions only`, `: on <plan>, not the Max 20x the defaults assume — short sessions only until its own history calibrates`, or `: the last recorded usage disagrees with the calibration — short sessions only until it recalibrates`. The footer says where the session costs come from, whether each account's reset time is exact or estimated and how long ago its usage was last recorded, and — when it applies — `Only one account — no reserve is possible`, or `Costs are defaults for Max 20x; Work’s plan is unknown` (`Work’s calibration uses defaults for Max 20x; its plan is unknown` when the costs are your own and only that account's calibration is a default). A `~N% left` in a clause is the cautious figure the Advisor fits against — 100 less the estimate's upper bound, after its margin — so it reads lower than the account's own line: `cannot fit: ~0% of the week left (est.)` beside `~95% used (est.)`. The tooltip of a row holds the reason, every clause the reason line does not already carry, and the basis.

**`Reading activity…`** is the switcher reading this Mac's Claude Code transcripts into its activity index. The first time, it reads every transcript changed in the last 14 days, in the background; until that is done the submenu holds only that line, the line under every account says the same, and the bars show what was recorded and nothing more. Nothing is advised from the recordings alone: the only recording of a week can be a 0 % taken just after its reset, however much has been spent since. On the Mac this was built on — an M4 Pro, about 3,700 transcripts and 5 GB in 14 days — the first read, timed with the same code in a test harness, took 5 to 7 seconds with the files already in the disk cache; from a cold disk, or on a slower Mac, it takes longer (not measured). Each later read takes only what changed and reaches seven days further back, until 45 days are covered — about a second each on that Mac — and under a tenth of a second once there is nothing new. After a long sleep the line comes back until an index more than an hour old has caught up.

**Make Claude record.** Claude records an account's usage when it starts, when a limit is reached or resets, when the account or organisation changes, and on a 15-minute timer — but the timer runs only while Claude's own menu-bar usage menu has been opened in the last 24 hours ([§2.10](#210-where-the-usage-bars-come-from)). So to have an account recorded now, **right-click Claude's icon in the menu bar**, or choose **Refresh** in the menu that opens; a left-click opens Claude's window and does not count. Without that, a running account can go a day or more without a recording, and its forecast runs on the recording from its launch plus this Mac's activity since: the line then reads like `~64% now (est.) · recorded 0% 33 h ago`, the submenu's footer says how old each account's last recording is, and the tooltip of a running account whose last recording is more than a day old says that right-clicking Claude's icon makes it record again. A right-click makes the Claude it belongs to record; with several accounts open, which icon is whose was not checked.

### Updating Claude Switcher

Claude Switcher keeps **itself** up to date from this repository's GitHub releases. This is about Claude Switcher only: Claude is never quit, started or updated by it, and every account keeps running through it. (Claude's own updates are [§2.9](#29-updates-need-every-instance-to-quit) and [§2.12](#212-blocking-claudes-auto-updates).)

**Automatic, unless you turn it off.** With **Keep Claude Switcher Up to Date** on — the default — it asks GitHub for the latest release every six hours: the first time three minutes after it starts, unless it asked less than six hours before. When there is a newer one, it downloads it and checks, in the background, that it is signed by the same developer as the copy you have, notarized by Apple, and really the version it claims to be ([§2.14](#214-claude-switcher-updating-itself)). Then it waits until nothing is going on, replaces itself and relaunches: the menu bar icon disappears for a second or two and comes back, and the next time you open the menu one line says `Claude Switcher updated itself to 0.8.0 at 3:14 PM.` No alert is shown for any of this. To turn it off, uncheck **Keep Claude Switcher Up to Date**, or set `"updateSwitcherAutomatically": false` in `~/.config/claude-switcher/config.json`. Off means no automatic network request at all.

**Checking by hand.** **Check for Claude Switcher Updates…** asks GitHub now, with the setting on or off. If there is a newer release it is downloaded and verified first — the menu says `Downloading Claude Switcher 0.8.0…` — and then one alert says what came of it: up to date; available, with **Update & Relaunch** and **Later**; could not be verified, and why (nothing was changed); or could not check, and why. A release that was refused before is tried once more.

**When it installs on its own: only when nothing is going on.** In plain words: the menu is closed; no window, alert or message is open or waiting; no account is being started, Claude is not being updated through **Quit All & Install Update…**, no session copy (or the finishing of an interrupted one) is running, accounts are not being reopened after a Claude update, and Diagnostics is not being put together; the welcome window is closed; any one-line notice in the menu has been seen; no check or download is running; and you have not used Claude Switcher in the last 90 seconds. It is checked again immediately before the swap. **Update & Relaunch** — in the alert, or as **Update Claude Switcher to 0.8.0 & Relaunch** in the menu — does not wait for the menu or the 90 seconds, but still waits for work in flight (an account starting, a session copy, a Claude update, a reopen pass, a download) to finish.

**It restarts itself, and only itself.** The new version is put in place in one atomic step and started as a new copy of Claude Switcher; the old one then quits. Claude is not touched. If the new copy cannot be started, it stays in place and starts the next time Claude Switcher is launched, and the old one keeps running until then; nothing is put back.

**The previous version is kept** in `~/.config/claude-switcher/updates/previous/<version>/Claude Switcher.app` — one version; an older one goes to the Trash. If a new version fails to start twice in a row, the next launch puts the previous one back by itself and says so.

**A copy built from source checks, but never installs.** A copy that cannot replace itself — built from source, run from `build/` or from the disk image, or not in `/Applications` or `~/Applications` — never does: its **Keep Claude Switcher Up to Date** is unchecked and greyed out, its tooltip says why, and it makes no automatic request. (A `make install` copy signed with your own Developer ID learns that it is not notarized only at its first check, so that one check goes out.) **Check for Claude Switcher Updates…** still works there, and when it finds a newer release that it can verify, the alert offers **Open Download Page** instead of installing it.

If two copies of Claude Switcher are running, only the one that holds the automation lock ([§2.11](#211-after-an-update-claude-only-brings-back-the-default-account)) checks on its own or installs.

<details>
<summary><b>Every menu item, in detail</b></summary>

The menu is rebuilt on every open so running state is fresh.

- A disabled header: `Running: Personal, Work` — or `Claude is not running`.
- **Start a session in…** — a submenu directly under the header, above the accounts; not shown with no accounts ([Reading the forecasts, and where to start a session](#reading-the-forecasts-and-where-to-start-a-session), [§2.10](#210-where-the-usage-bars-come-from)). Three rows, `Short — under an hour`, `Medium — 1 to 3 hours` and `Long — over 3 hours or a workflow run`, each `→` the account the Advisor picks, with the reason as a grey line under it. Row and reason share a tooltip: the reason, a clause on every other account the reason line does not already carry, and the basis of the estimate (`Based on the last recorded usage plus this Mac’s activity since (est.).`). A row selects its account exactly as that account's own row does, and is enabled as account rows are — never while a launch is in flight or without `Claude.app` — and also not when nothing fits, nor, for `→ Personal after 9:10 PM (est.)`, before that window clears: while the menu is open, that row is re-enabled in place at that time. Below a separator, the footer: where the session costs come from, whether each account's reset time is exact or estimated, how long ago its usage was last recorded, and, when they apply, `Only one account — no reserve is possible` and `Costs are defaults for Max 20x; Work’s plan is unknown` (or `Work’s calibration uses defaults for Max 20x; its plan is unknown`), and last `Choosing a row opens that account.` Until the first usage read lands, and while the activity index is absent or being read, the submenu holds only `Reading activity…`; it never waits for either. The answers are read in the background with the bars, and a newer read is patched into an open menu by identifier, without rebuilding it under the cursor.
- **Quit All & Install Update…**, under a disabled line naming the version — shown only while Claude has an update downloaded, its installer is alive and waiting, and at least one instance is running (see [§2.9](#29-updates-need-every-instance-to-quit)). It confirms first, naming the accounts it will quit and reopen and any unrecognized instances it will quit and *not* reopen. It then asks every instance to quit (the same as ⌘Q — never forced), waits for Claude's own installer to finish, and reopens the accounts that were running; if an instance will not quit, nothing is reopened and it says which accounts are closed. While it runs, a progress line replaces the offer. **This is the only thing in the app that ever quits Claude, and it never happens on its own.**
- Claude Switcher's own lines about updating itself ([Updating Claude Switcher](#updating-claude-switcher)), under the header: once, after a launch that finished an update, `Claude Switcher updated itself to 0.8.0 at 3:14 PM.` (its tooltip names the version it came from, where the previous copy is, and the release notes' page) — or `Claude Switcher could not update itself to 0.8.0 — still 0.7.0. See Diagnostics…`, or `Claude Switcher 0.8.0 did not start properly twice; it went back to 0.7.0. See Diagnostics…`; until it has been seen, it holds back an automatic install. While a check runs, `Checking for Claude Switcher updates…`, then `Downloading Claude Switcher 0.8.0…` when it fetches and verifies one — beside, never instead of, Claude's own update line. While it replaces itself, `Updating Claude Switcher to 0.8.0 — it relaunches in a moment…`. A verified release waiting: `Claude Switcher 0.8.0 is ready — it relaunches when nothing is going on`, shown only when it really will (the setting on, this copy holding the lock, `config.json` readable) or you chose **Update & Relaunch**; its tooltip names what it is waiting for. A new version in place that could not be started: `Claude Switcher 0.8.0 is in place — it starts the next time Claude Switcher is launched`.
- Under each account that has ever run, its **usage bars**: one drawn row per limit Claude reports for that account — `5h` (the five-hour session) and `week`, plus `Opus`, `Sonnet`, `Cowork`, `apps` or `extra` when the account has those — with the percentage Claude last recorded, a bar coloured by that recorded value (orange from 80 %, red at 100 %), and a note. Once this Mac's activity has been read, the `5h` and `week` bars also draw a lighter segment, the bar's own colour at 40 % opacity, from the recorded value up to the estimate, when the estimate is higher; the percentage stays the recorded one. The session row says when the window ends — `resets by 9:10 PM (est.)`, the latest it can be, or `resets 9:10 PM` when Claude Code recorded the end; a window that only this Mac's activity shows says the same of its estimated end. The week row says when the week resets — `resets Sat 9:00 PM` only when Claude Code recorded that time and the schedule is fresh (an anchor or a reset seen within the last 14 days agrees with it, and no reset at another time is unconfirmed), otherwise `resets Sat 9:00 PM (est.)` (a recorded time assumed to repeat) or `resets by Sat 10:09 PM (est.)` (from the drops in the recorded figure) — and how old the reading is. A dash means the period has certainly ended since the reading (for the week, under the assumed schedule); a five-hour window ends at the end Claude Code recorded for it, once that has passed, whatever the reading's bound. A five-hour limit hit Claude Code recorded after the reading is recorded too: the row reads `100%` with `resets` and that hit's exact end. The drawing is not an accessibility element: the item's title is the sentence VoiceOver reads — the recorded rows, each lighter segment as `estimated N percent`, and the end of a window only this Mac's activity shows as an *estimated* reset. Read from the account's own `plan-usage-history.json`, never fetched — [§2.10](#210-where-the-usage-bars-come-from).
- Under every account, its **forecast line**: one grey line about its week, at most 40 characters, with `(est.)` or `(default)` within its first 32 whenever it is not recorded — `~95% used (est.) · out about this eve`, `~28% unused by Mon 5 AM (est.)`, `No usage recorded yet (default)` and the others in [Reading the forecasts](#reading-the-forecasts-and-where-to-start-a-session); `Reading activity…` while the activity index is being read. The bars and the line share one tooltip: the recorded values and when; the five-hour window and how its end is known; what the lighter part of a bar is, with its numbers (`Lighter part of a bar: this Mac’s activity since the last recording (est.) — 5h ~61%, week ~15%.`); the week now — the estimate, the range it lies in, the pace this week and over the last six hours, and when the limit is reached or how much would go unused; the last four weeks; where the reset time comes from; how activity is attributed; how costs are weighted and calibrated; a running session's committed cost; that the Fable-only weekly limit is not recorded locally; and, for a running account whose last recording is more than a day old, that right-clicking Claude's own menu-bar icon makes it record again. Like the Sessions lists, all of it is read in the background; a first open can show no bars or line until the read lands, and a newer read is patched in by identifier.
- One item per account: the label and a checkmark when an instance for that account is running. Selecting a running account brings its window to the front, reopening the window if it was closed ([§2.8](#28-what-the-tool-actually-does-with-all-this)); selecting one that is not running starts it.
- Under every account, **Sessions** — a submenu of that account's Code-tab sessions ([Copying a session](#copying-a-session-to-another-account)). It lists the account's non-archived local sessions whose transcript is on this Mac, newest activity first, at most 20; a last line counts the rest (`Not listed: 3 older, 6 archived, 2 with no transcript on this Mac, 1 remote`). Each row is the session's title (or *Untitled — folder*), badged `open` while a running Claude has it open and otherwise with its age; Its submenu opens with its particulars — the title in full when the row had to cut it, its folder (`~` for home, and the end of a long path), last activity, model and transcript size — then has one **Copy to *account*…** per other account, or the reason it cannot be copied. Above the rows, one line for each copy made into this account that has not been opened yet. If the account's Claude is signed in to a different account than the sessions saved there, or several accounts or organisations have used it, the submenu says that instead of listing anything. Like the Keychain badges, the lists are read in the background — read-only: every account's session records and three keys of its `config.json`, the transcripts' folders (each listed session's transcript and working folder are looked at, not opened), the free space on the volume of `~/.claude/projects`, Claude Code's `~/.claude/sessions` registry, the session folders of every `~/Library/Application Support/Claude*` folder, configured or not (a copy needs every one of them readable), and the switcher's own copy journal — and a first open can show `Reading sessions…` until the read lands, after which only the Sessions submenus are replaced.
- **Copy terminal command** — a submenu. Its first line is a disabled note, "For the claude CLI in a terminal — it signs in separately from the Claude app.", then one item per account (see [Terminal](#terminal) above), each with a badge for the terminal CLI's sign-in, from `MenuBuilder.hintText`:

  | probe result | badge |
  | --- | --- |
  | a credential item exists | `signed in` |
  | no credential item found | `no sign-in found` |
  | not probed yet | *(no badge)* |

  No badge is what you see before the background Keychain probe reports — the menu is built from a cached snapshot and never blocks on a `security` call, so a first open can show none briefly; the badges are then patched in place rather than rebuilding the menu under the cursor. Hovering a `no sign-in found` item says what to do: run the command, then sign in once in the terminal. Note that the probe reports **failure the same as genuine absence**: `KeychainProbe.isSignedIn` returns `false` on any thrown error, timeout or non-zero exit, which is why the badge says `no sign-in found` and not "not signed in": no credential item was found, which is not always the same thing. If no `claude` CLI was found on the Mac at all, the submenu says that too, in a second disabled line (it used to be an alert at launch). **The badge describes the terminal CLI only** — the Desktop login is separate and is not something the tool can inspect, which is why the badge is here and not on the account rows.
- **Add Account…**, **Rename Account** (one item per account; changes only the label shown in the menu — the id, both directories and therefore the Keychain service name stay exactly as they are), and **Remove Account** (disabled for the default account, listed as `(default account)`, and for the active one, listed as `(active)`; confirms first; **never deletes the account's data directories**, and says so in the dialog).
- **Choose Claude.app…** — an `NSOpenPanel`, offered when the configured path is missing or on request.
- **Reveal ~/.claude in Finder**.
- **Welcome…** — reopens the welcome window ([Launched it and nothing happened?](#launched-it-and-nothing-happened)).
- **Diagnostics** — a selectable-text alert with: the config path; the resolved `Claude.app` path, its `CFBundleIdentifier` and version, any staged update and whether Claude's installer is running; the shared config dir (`~/.claude`) and confirmation that `CLAUDE_CONFIG_DIR` is unset; each account with its normalized directories, derived Keychain service name, running pid and last recorded usage, then four lines about its usage ([§2.10](#210-where-the-usage-bars-come-from)): `forecast:` (the week used with its range, the pace, run-out or unused at the reset, the five-hour room and when it clears, the committed cost of running sessions; recorded values only while the activity index is not read), `schedule:` (the weekly reset in local time and UTC, exact or estimated and why, any unconfirmed reset, samples out of order), `calibration:` (points per unit of spend with its fit, the window's, the plan, and the session costs used, each `default` or with its count) and `limits:` (the limit hits Claude Code recorded, by kind, and in how many of the last four weeks the limit was reached); and a `code sessions:` line — counts only, never a title or a folder, plus the first eight characters of the account and organisation folder the list was read from; a `SESSION COPIES` section — the count of copies made but not yet opened, one line per copy that has not finished (its account, whether it was still staging or already staged, since when, and where its `.claude-switcher-*` leftovers would be), what the last recovery pass said, and a session folder that cannot be read, by path; an `ADVISOR` section — the three answers (`short   → Work       most headroom (~92% left, est.); …`), where the session costs come from, the activity index (`activity index: 2 accounts, 412 transcripts, read through 2026-10-05 18:47, 0.2% of spend unattributed (A6), 0 unpriced calls`, or that it is not built yet, or could not be written) and the assumptions everything rests on, by number — counts and labels only, never a session's title, prompt or folder; and the `claude` CLI version for both the `PATH` binary and the app-managed sidecar if present. Right after the config, a `CLAUDE SWITCHER` section is about the switcher itself ([§2.14](#214-claude-switcher-updating-itself)): its version and path; who signed it, read from its own signature, and whether it is notarized; whether it updates itself and, if not, why; the last check and what it found, and the next one; a verified release waiting, and for what; the last update and where the previous copy went; the last failure, and whether automatic downloads are paused; the latest release's flags; a disk image or staging folder left behind; what the last relaunch found; Launch at Login; records from another Mac; what the launch-time pass did; and the network requests it makes. The report's closing `GUARANTEES` list says where usage numbers and activity are read from, that nothing is written there or fetched, and that the switcher keeps one index of those numbers in `~/.config/claude-switcher`; it also names the automatic replace (unless the setting is off), says that its only network requests are to GitHub for Claude Switcher's own releases (macOS may ask Apple's servers of its own accord while it checks a signature or a notarization), and that the only copy of itself it ever deletes is a downloaded one it never put in place — a copy that was in use is moved to its own folder or the Trash.
- **Reopen Accounts After Claude Updates** (on by default) — when Claude updates itself it closes, and its installer only ever reopens the default account. With this on, the other accounts that closed *for the update* are started again, in the background, once it is installed ([§2.11](#211-after-an-update-claude-only-brings-back-the-default-account)). It is the one thing the app does to Claude on its own initiative, and it can only launch: nothing is ever quit by it. (The other things done unasked leave Claude alone: finishing or cleaning up a session copy that was interrupted — [§2.13](#213-copying-a-session-to-another-account) — Claude Switcher updating itself — [§2.14](#214-claude-switcher-updating-itself) — and keeping its index of this Mac's activity, which only reads Claude's files — [§2.10](#210-where-the-usage-bars-come-from).) When it has acted, the next menu open says so in one line.
- **Block Claude Auto-Updates** (off by default) — stops Claude Desktop from downloading or installing updates at all, through Claude's own `disableAutoUpdates` policy, so it never closes itself to update ([§2.12](#212-blocking-claudes-auto-updates)). Turning it on asks first and spells out the cost. It applies the next time each account starts; nothing is quit to apply it.
- **Launch at Login** — a checkbox bound to `SMAppService.mainApp`, reflecting `.status`. A bundle that has never been registered reports `.notFound`, which is *not* an error: it is shown as an unchecked box and clicking it registers. The item is greyed out only when the process is not inside an `.app` bundle (`swift run`), where there is nothing launchd could register.
- **Keep Claude Switcher Up to Date** (on by default) — Claude Switcher checks GitHub for a newer release of itself every six hours, downloads and verifies it in the background, and replaces itself and relaunches when nothing is going on ([Updating Claude Switcher](#updating-claude-switcher), [§2.14](#214-claude-switcher-updating-itself)). Only Claude Switcher: Claude is never quit, started or updated by it. Its tooltip says when it last checked and what it found. Off, Claude Switcher makes no network request unless you choose **Check for Claude Switcher Updates…**; a release it has already verified in this run keeps its **Update …** item. In a copy that never replaces itself — built from source, run from `build/` or the disk image, not in `/Applications` or `~/Applications` — it is unchecked and greyed out, and the tooltip says why. It is saved to `config.json` as `updateSwitcherAutomatically`.
- **Check for Claude Switcher Updates…** — asks GitHub now, whatever the setting. When a newer release exists and this copy has a signature of its own to check it against, it is downloaded and verified before anything is said; then one alert: **Claude Switcher is up to date**; **Claude Switcher 0.8.0 is available**, with **Update & Relaunch** and **Later** (or, in a copy that never replaces itself, **Open Download Page** and **OK** — that copy removes what it verified; and in a second running copy that holds no automation lock, **OK** only, saying that the other Claude Switcher is the one that installs it); **Claude Switcher 0.8.0 could not be verified**, with the reason and that nothing was changed; **A newer Claude Switcher may exist**, from a copy with no Developer ID signature of its own, which cannot verify anything; or **Could not check for Claude Switcher updates**, with the reason. A release rejected earlier is tried once more, and automatic downloads paused after three rejected releases start again. Greyed out while a check or a replace is running, and once a new version is waiting for the next launch. Automatic checks never show an alert.
- **Update Claude Switcher to 0.8.0 & Relaunch** — only while this copy keeps a release it has downloaded and verified in this run. The same as **Update & Relaunch** in the alert: it does not wait for the menu or the quiet period, but waits for work in flight to finish, and it needs this copy to hold the automation lock — in a second copy it says another Claude Switcher is running. If the replace is refused, or undone right after the swap, or the new copy cannot be started, an alert says so; an automatic replace never shows an alert, and Diagnostics records what happened.
- **Quit** — greyed out while Claude Switcher replaces itself (that ends this process by itself, after the relaunch). Quitting, like any other way the app ends, removes a verified copy it was keeping for an update; the downloaded disk image stays for the next check.

Launches are serialized, but only the items that could start a second one are gated on the in-flight flag: **the account rows, the rows of Start a session in…, Add Account…, the Rename Account submenu and the Remove Account submenu** go disabled while a launch is in flight and re-enable on completion (a 30-second watchdog re-enables them if a completion handler never arrives); the welcome window's **Add Account…** button stays clickable and just beeps meanwhile. Nothing that saves — adding, renaming or removing an account, choosing Claude.app, **Reopen Accounts After Claude Updates**, **Block Claude Auto-Updates**, **Keep Claude Switcher Up to Date** — runs while `config.json` cannot be read: what is in memory then is the last good settings or the defaults, and saving would write them over the file you are fixing. **Copy terminal command, Choose Claude.app…, Reveal ~/.claude, Welcome…, Diagnostics…, Launch at Login and Quit stay enabled throughout** — throughout a launch, that is. The account rows, and the Advisor's rows with them, additionally require the configured `Claude.app` to exist.

While Claude Switcher replaces itself — from the decision to the relaunch — it holds the same in-flight flag, so nothing launches; **Launch at Login**, the three toggles, **Quit**, **Check for Claude Switcher Updates…** and every **Copy to …** are greyed out; and **Choose Claude.app…** does nothing, because the replace has just proved, against the configured path, that what it replaces is not Claude.

Session copies have a gate of their own: one at a time. While one runs, a progress line (`Copying “title” to Work…`) sits under the `Running:` header and every **Copy to …** item is disabled; the Sessions submenus themselves stay open to browse. Each **Copy to …** is checked again when you confirm: if either account was removed or now points at another data folder meanwhile, nothing is copied and an alert says so. The result is one alert; when the copy did not go through, recovery runs first and what it did is in the same alert. When the recovery pass at launch has finished, cleaned up or left something, one short line under the `Running:` header says how many of each (`Session copies: 1 finished or cleaned up, 1 needs attention — see Diagnostics…`), with the full notes in its tooltip, until the menu has been opened once; **Diagnostics…** shows the notes of the last recovery pass the app ran until a pass has nothing to say. For as long as any copy has not finished, a second line says so at every open (`1 session copy has not finished — see Diagnostics…`).

An update install holds the same flag from confirmation until the last account is back, and additionally disables **Choose Claude.app…** and **Quit** — quitting the switcher mid-install would leave every account closed with nothing to reopen it.

</details>

---

## What's shared, what's per-account

| State | Location | Shared or per-account |
| --- | --- | --- |
| Project + session transcripts | `~/.claude/projects/` | **Shared** across every account |
| Prompt history | `~/.claude/history.jsonl` | **Shared** |
| Skills | `~/.claude/skills/` | **Shared** |
| Subagents | `~/.claude/agents/` | **Shared** |
| Plugins | `~/.claude/plugins/` | **Shared** |
| Memory and `CLAUDE.md` | `~/.claude/` | **Shared** |
| Settings (incl. MCP servers, permissions) | `~/.claude/settings.json` | **Shared** |
| Code tab session list | `claude-code-sessions/<account>/<organisation>/` in the Electron profile | Per-account. Each record points at a transcript in the shared `~/.claude/projects/`, but an account lists only the sessions it started ([§2.5](#25-the-code-tabs-session-list-is-per-account-the-transcripts-are-shared)). A session can be copied into another account's list, as a new session with its own transcript ([§2.13](#213-copying-a-session-to-another-account)). |
| Desktop app login / identity | Electron profile (`--user-data-dir`) | Per-account |
| Cookies, Local Storage, IndexedDB | Electron profile | Per-account |
| Desktop MCP config | `claude_desktop_config.json` in the Electron profile | Per-account |
| Chat history | server-side, on the Anthropic account | Per-account (cannot be shared) |
| Cowork / remote sessions | server-side | Per-account |
| Usage limits and plan | server-side | Per-account. Claude Desktop records each account's usage into its own profile directory; the switcher shows those readings ([§2.10](#210-where-the-usage-bars-come-from)). |
| Terminal CLI credentials | Keychain item, service name from [§2.7](#27-keychain-service-name-derivation) | Per-account (per `credDir`) |

---

## How it works

Everything below was established empirically, by reading the shipped `Claude.app` JavaScript and by running live tests. It is *not* how the app is documented to behave — see [Caveats and limitations](#caveats-and-limitations). Where something has not been run against a live Claude, the section says so: the window request in [§2.8](#28-what-the-tool-actually-does-with-all-this), and the session copy in [§2.13](#213-copying-a-session-to-another-account). The forecasts and the Advisor in [§2.10](#210-where-the-usage-bars-come-from) are a different kind of claim: what Claude and Claude Code record was read in their code and checked on disk, but what the switcher makes of it is a model of Anthropic's limits, fitted to the history of two Max 20x accounts on one Mac and resting on assumptions that section lists, and the menu that shows it has not yet been seen in the running app. [§2.14](#214-claude-switcher-updating-itself) is about Claude Switcher updating itself rather than about Claude; it rests on the code, its tests, Apple's and GitHub's documentation and experiments made while it was designed, and it has not run live yet — no copy of Claude Switcher has ever updated itself.

### 2.1 The config dir is independent of the Electron profile

The app resolves its Claude config directory with exactly this function (from the shipped bundle, names minified):

```js
function RR(){ let e = process.env.CLAUDE_CONFIG_DIR; return e ? zw(e) : join(homedir(), ".claude") }
```

That is: `CLAUDE_CONFIG_DIR ?? ~/.claude`. It has **no relationship to `--user-data-dir`**. So you can give the app a completely separate Electron profile — a separate login, a separate account — and it will still read and write the same `~/.claude`.

This is the mechanism the whole tool is built on. **`claude-switcher` therefore never sets or modifies `CLAUDE_CONFIG_DIR`, anywhere.** Setting it would isolate exactly the state we are trying to share.

### 2.2 `--user-data-dir` gives you a separate account

`Claude.app` is an Electron app, and `--user-data-dir=<dir>` is Electron's own flag for choosing the profile directory. Passing it produces a fresh Electron profile: launching with a new directory populates it with `Local Storage/`, `Cookies`, `IndexedDB/` and `claude_desktop_config.json`, and the app comes up logged out. Signing in there creates a second, independent app login — **for both the chat side and the Code tab** — while `~/.claude` ([§2.1](#21-the-config-dir-is-independent-of-the-electron-profile)) remains shared.

### 2.3 Instances run concurrently

There is **no `requestSingleInstanceLock` anywhere in the app**. Multiple instances with different `--user-data-dir` values run side by side. Switching accounts is therefore *launching or focusing another instance* — there is no quitting, no logging out, no waiting. (Running side by side has one cost, and it is the only time anything needs to quit: Claude's updater — [§2.9](#29-updates-need-every-instance-to-quit).)

### 2.4 The Code tab does not read the Keychain

The Code tab's credentials do not come from the macOS Keychain. The app injects `CLAUDE_CODE_OAUTH_TOKEN` directly into the environment of the `claude-code` sidecar process it spawns. Two consequences:

- Setting `CLAUDE_SECURESTORAGE_CONFIG_DIR` on `Claude.app` has **no effect on the Code tab**. The Desktop account — chat and Code tab alike — is selected *purely* by `--user-data-dir`.
- `claude-switcher` never sets `CLAUDE_CODE_OAUTH_TOKEN` and never puts any `CLAUDE_*` variable into a launched app's environment.

### 2.5 The Code tab's session list is per account; the transcripts are shared

As of Claude Desktop 2.19675.0 the Code tab's sidebar is **not** built from `~/.claude/projects`. Each instance keeps one record per session at `<user-data dir>/claude-code-sessions/<account>/<organisation>/local_<id>.json` and lists only those: its `getStorageDir()` joins the user-data dir, the signed-in account and its organisation, and the loader reads nothing but the `local_*.json` files there. A record names its transcript by id, and the transcript is in the shared `~/.claude/projects/<cwd-slug>/<id>.jsonl` ([§2.1](#21-the-config-dir-is-independent-of-the-electron-profile)).

So every account's transcripts sit side by side on disk, but an account's list shows only the sessions it started. (On the machine this was checked on: 158 records in one profile, 17 in the other, no transcript claimed by both.) The one reader of `~/.claude/projects` that applies no account filter is the Code tab's “CLI sessions” list, and it deliberately skips sessions that were started in the desktop app.

An earlier version of this README said the list was enumerated from `~/.claude/projects` with no account filter. That is not what this version of the app does; the build it was read from is no longer available to re-check.

Making two accounts' records point at **one** transcript is not a way round it. Each instance decides whether a transcript may be deleted from the claims it can see, and the default profile cannot see the claims of a `Claude-<slug>` profile — delete the session in one account and the file the other still uses can go with it. Claude's own store also refuses symlinked directories and hard-linked transcripts. What does work is a copy with its own id and its own transcript, which is what [§2.13](#213-copying-a-session-to-another-account) makes.

### 2.6 The terminal CLI is a separate story

For the **terminal `claude` CLI only**, `CLAUDE_SECURESTORAGE_CONFIG_DIR=<dir>` selects a separate credential slot while still sharing `~/.claude`. Verified with `claude auth status`: logged in by default, `loggedIn: false` with the variable pointed at a fresh directory.

The variable must be **omitted entirely** for the default account. Never pass it as an empty string — the CLI branches on whether the variable is *defined*, not on whether it has a useful value.

### 2.7 Keychain service-name derivation

The CLI derives its Keychain service name like this (again from the shipped binary):

```js
oG(e = ""){
  t = env.CLAUDE_SECURESTORAGE_CONFIG_DIR;
  r = t !== undefined ? !t : !env.CLAUDE_CONFIG_DIR;
  n = t !== undefined ? NFC(t) : configDir();
  o = r ? "" : "-" + sha256(n).hex.slice(0, 8);
  return "Claude Code" + OAUTH_FILE_SUFFIX + e + o;
}
```

`OAUTH_FILE_SUFFIX` is `""` in production and `e` is `"-credentials"`, so:

| credential dir | Keychain service name |
| --- | --- |
| not set (`nil`) | `Claude Code-credentials` |
| set to `<dir>` | `Claude Code-credentials-` + first 8 **lowercase** hex chars of `sha256(NFC(<dir>))` |

The hash covers **exactly the string handed to the CLI**, so `claude-switcher` normalizes the path first and hashes the normalized result — the same string it would export.

> **Trap:** pointing an account's credential dir at `~/.claude` *itself* still yields a hashed service name, not the default one, because the branch keys off whether the variable is defined, not off its value.

### 2.8 What the tool actually does with all this

- **Desktop:** launch `Claude.app` via `NSWorkspace.shared.openApplication(at:configuration:)`. `arguments = ["--user-data-dir=<normalized dir>"]` is set **only** when the account has a `userDataDir`; the default account passes **no** arguments, because omitting the flag is exactly what selects the app's own profile directory. It never shells out to `/usr/bin/open`, and never modifies or duplicates the `Claude.app` bundle.
- **`createsNewApplicationInstance = true` is set unconditionally.** Not "only for named accounts" — the launch path is reached *only after* establishing that no running instance matches the requested account, and at that point a new process is always what is wanted, the default account included. This must not be made conditional on `userDataDir != nil`. With the flag `false`, `openApplication` activates **any** running instance of the bundle; it has no idea that instance belongs to a different Electron profile. Choosing the default account while only a named account was running would then bring the **wrong account's** window to the front, return that instance's pid, and have the tool record the switch as a success. That was a real, high-severity defect. Leave it unconditional.
- **Matching running instances to accounts is three-valued.** Each process's `argv` is read via `sysctl(KERN_PROCARGS2)` (so paths containing spaces parse correctly, and both the `--user-data-dir=VALUE` and `--user-data-dir VALUE` spellings are accepted) and classified into an `InstanceProfile`:
  - `.defaultProfile` — no `--user-data-dir` argument (or an empty value). This *is* the default account.
  - `.directory(String)` — launched with `--user-data-dir=<dir>`, normalized. Matches the account whose normalized `userDataDir` is equal.
  - `.unknown` — the argument vector could not be read at all. **Matches no account, ever.**

  The third case is the point: "no `--user-data-dir`" and "we could not read the command line" are entirely different claims. The first identifies the default account; the second identifies *nothing*. Folding them together (`ProcessArgs.arguments(forPID:)` returning `[]` instead of `nil`, say) would make every process the tool lacks permission to inspect masquerade as the user's default account — showing the wrong account as running, and letting a "focus" action raise an unrelated window while the UI reported success.
- **Launching when unreadable instances exist asks first.** If any running instance is `.unknown`, the tool cannot prove it is *not* the account you just picked, and starting a second Electron process against one user-data dir puts two Chromium processes on one LevelDB store. Rather than refuse, it presents a confirmation alert naming how many processes did not report a command line, offering **Start Anyway** / **Cancel**.
- If an account's instance is already running, the tool activates it instead of launching a second copy. Activation re-checks the target process's bundle identifier first, because the menu acts on a snapshot and a pid can be reused between opening the menu and clicking.
- **Activating also asks for the window.** Activation alone raises only the windows an app already has, and Claude Desktop keeps running after its main window is closed — so selecting such an account used to bring nothing up. `InstanceManager.activate` therefore first sends that one process the "reopen" Apple event (`kAEReopenApplication`, the event a Dock click sends), then activates it. Claude Desktop (as of 2.19675.0) answers by showing its main window: un-hiding it, restoring it from the Dock, or creating it again. Only a process whose bundle id was just checked against Claude's is sent the event; if that id cannot be read, the instance is activated and nothing more. The event is addressed **by pid**, for the same reason `createsNewApplicationInstance` is unconditional: every account is the same app bundle, so anything that names the app instead (`NSWorkspace.openApplication`, `open -a`) reaches whichever instance LaunchServices picks — possibly the wrong account's. It is best-effort, sent from a background queue and never waited on (`kAENoReply`), with `kAEDoNotPromptForUserConsent` so that it cannot raise a permission dialog; if macOS refuses the send, the instance is simply activated as before. A refusal would otherwise be invisible, so the result of the last request is kept and shown in **Diagnostics…** as `window request:`. This was verified with stand-in apps — of two running instances, a pid-addressed reopen sent by this code reaches only the one addressed — and by reading Claude's handler for the event. It has **not** been verified from the installed, signed app against a live Claude: whether macOS lets it through there without an Automation grant is exactly what that Diagnostics line is for.
- **Bundle identifier:** read `CFBundleIdentifier` from the configured app's `Info.plist`. Never hardcoded.
- **Terminal:** the tool does not run the CLI for you. It copies the right command to the pasteboard and reports sign-in state in the same submenu.
- **Credentials:** the tool performs **existence checks only**, via `security find-generic-password -s "<service>" -a "$USER"`. It never passes `-w`, and never reads, writes, copies, migrates or deletes a Keychain secret. Any failure degrades silently to the same answer as a genuine absence (see the badge table under [Usage](#usage)).

### 2.9 Updates need every instance to quit

Claude Desktop updates itself with Squirrel. When an update has downloaded, the app starts a helper, `ShipIt`, that notes every instance of the app running at that moment, waits until **all of them** have exited, and only then swaps the bundle. (Each running instance re-requests the install at its hourly update check, which restarts the helper with a fresh list.) Claude also updates "stealthily": after an idle timeout it quits itself (`beforeQuitForUpdate … going down for update` in `~/Library/Logs/Claude/main.log`), expecting the helper to install and bring it back.

With one instance the install goes through — observed end to end in about seven seconds — but what comes back is **only the default account**: the installer relaunches Claude with no arguments, so a named account that quit itself stays closed even after a successful update. That half of the problem is [§2.11](#211-after-an-update-claude-only-brings-back-the-default-account)'s. With two it cannot: the other account never exits, so the helper never starts installing, and **the account that quit itself stays closed**. Reopening it by hand only restarts the cycle — it re-requests the install and quits again the next time it goes idle. The tell-tale is `~/Library/Caches/<bundle id>.ShipIt/ShipIt_stderr.log` filling with `Detected this as an install request` lines that are never followed by `Beginning installation`.

The switcher cannot change how Claude's updater works, so it does the two things it can:

- **It notices.** On every menu open it reads the helper's request file (`ShipItState.plist` — JSON, despite the name), the `Info.plist` of the downloaded bundle it points at and of the installed app, and scans process names for a live `ShipIt` whose job label is `<bundle id>.ShipIt`. An update counts as blocked only when the request names the configured app, the downloaded bundle still exists inside the helper's cache directory with a different version, *and* a helper is alive to install it — the request file outlives the install it describes, so its presence alone means nothing. Versions are read straight from the plist file, never through `Bundle`, which caches per path and would not notice the app being replaced.
- **It offers the way through: Quit All & Install Update….** After you confirm, it asks each running instance to quit with `NSRunningApplication.terminate()` (the same request as ⌘Q), waits until none is left, waits for the helper to exit, and then reopens the accounts that were running — named accounts first, the default account last, skipping any that are already back, because the helper sometimes reopens the default account itself.

The sequence is deliberately timid:

- It quits only the instances that were running when you confirmed, and quits nothing if that set has changed.
- It never escalates: no `forceTerminate()`, no signals. An instance showing a dialog of its own just runs out the one-minute clock — and then **nothing is reopened**. The helper only waits for the instances it listed when it started, so it may begin the moment the last of *those* quits; an account reopened now could be running from a bundle that is about to be moved away. The alert names the accounts left closed.
- It launches nothing until the helper has *stayed* gone for three seconds. One absent poll proves nothing: a failed install attempt exits and launchd restarts the helper within about two seconds, and the restarted one installs immediately. If the helper is still going after three minutes it reopens nothing and says so. The single exception: once the new version is on disk, only the helper's own relaunch step remains, so after a 15-second grace the accounts are reopened even if it lingers.
- It will not start an account while an instance it cannot identify is running, since that could be the very account it is about to start — two processes on one profile directory can corrupt that login.

Everything here is read-only apart from the quit request itself: nothing under the helper's cache directory is written, moved or deleted, the helper is never started by this tool, and the `Claude.app` bundle is only ever replaced by Claude's own installer.

### 2.10 Where the usage bars come from

Other menu-bar meters get Claude usage by reading the OAuth token out of the Keychain, reusing browser cookies, or driving the CLI. This tool does none of that ([rules 1 and 13](#appendix-b--hard-constraints)) — and the Keychain token is the *terminal's* account anyway, not the Desktop app's. Everything here comes from files Claude Desktop and Claude Code already write on this Mac, and they are only ever read.

The menu shows two kinds of number, and its words keep them apart. A **recorded** number is one Claude wrote down: the percentage beside each bar, and a reset time Claude Code recorded. Everything else — the lighter part of a bar, the grey line under the bars, **Start a session in…** — is an **estimate**: a model of Anthropic's limits, laid over the recordings and fitted to this Mac's Claude Code activity. It rests on fifteen assumptions, listed [below](#the-assumptions) with how the menu labels each and what changes if it is wrong. It was calibrated on two accounts on one Mac, both on Max 20x. And every reset time that Claude Code has not recorded exactly is an estimate, and says `(est.)`.

#### What Claude records, and when

Claude Desktop keeps each account's usage **in its own user-data directory** — `~/Library/Application Support/Claude/` for the default account, the account's `--user-data-dir` otherwise — in `plan-usage-history.json`. Read out of the app's main process: after each successful request for its account's usage it appends a sample, `{"t": <ms>, "org": "<uuid>", "u": {…}}`, at most once every 270 seconds per organisation, keeps 30 days of them, and writes the file atomically. `u` maps each limit the account has to a utilization percentage: `fh` the five-hour session, `sd` the week, and only for accounts that have them `so` / `sn` (weekly Opus / Sonnet), `cw` (Cowork), `oa` (OAuth apps), `xu` (extra usage) and a couple of others. Reset times are not stored, and neither is the per-model part of the answer — so the Fable-only weekly limit is not in the file. A legacy `version: 1` layout (`fh`/`sd` beside `t`) reads the same.

**Samples come from events, and from a clock only while Claude's usage menu has been opened in the last day.** Read in Claude Desktop's main process and in the claude.ai page it loads, and confirmed in its log and its files on this Mac, a sample is taken:

- when that account's Claude starts;
- when its menu-bar icon is right-clicked, or **Refresh** is chosen in the menu that opens — a left-click opens the window and does not count;
- when the account or the organisation changes;
- when a limit becomes exceeded, and again at the moment an exceeded limit resets, for which the page sets a timer — so an account at its limit is sampled at its exact reset, as both accounts here were (at 21:00:00.7 and 05:00:01.1);
- and on a background timer, every 15 minutes (every 5 within half an hour of using that menu) — skipped while the Mac has been idle for 10 minutes or is locked, with one catch-up at unlock, and **paused altogether once the menu-bar usage menu has not been opened for 24 hours**. That last rule is a setting the server sends (`pollRequiresTrayOpenWithinHours`). Claude logs it at every launch — `poll requires tray open within 86400000ms` — first in this Mac's logs on 2026-10-01, and then `background poll paused: tray not opened recently`.

So a gap in the samples is not idle time, and a running account is not necessarily being recorded: since that setting, an account whose icon nobody right-clicks is sampled when it starts and at limit events, and at no other time. One account here went 33 hours without a sample while it was in use. The page's own usage requests — what Claude's Settings › Usage shows — add no sample. This is why [Reading the forecasts](#reading-the-forecasts-and-where-to-start-a-session) says to right-click Claude's icon, and why the forecasts lean on activity.

**Claude Code records the exact reset time when a limit is hit.** A request refused for a limit leaves an assistant line in the transcript with `"error":"rate_limit"` and `quotaLimits {status, rateLimitType, resetsAt}` — the reset time from the API's own headers, in epoch seconds, which jitters by about a second (it is rounded to the minute here). The kinds the switcher tells apart are `five_hour`, `seven_day`, `seven_day_overage_included` — what the CLI itself calls the "Fable limit", a weekly limit on the Fable models alone that can be reached while the all-models week still has room — and the per-model `seven_day_opus` and `seven_day_sonnet`. On this Mac there were 17 distinct limit hits in 40 days. Their weekly reset times never moved — one account's always Sunday 04:00 UTC, the other's Monday 12:00 UTC — and every five-hour reset fell on a ten-minute mark.

**The terminal CLI caches its last usage check** in `~/.claude.json` (`cachedUsageUtilization`, written at most once a minute and ignored by the CLI itself after an hour), for the one account it is signed in to, beside that account's plan tier (`oauthAccount.organizationRateLimitTier`).

#### What the switcher reads, and the one file it writes

- **The samples**, every account's, at every read, of the organisation the account is on now.
- **The transcripts**, into its *activity index*: every Claude Code transcript under `~/.claude/projects` changed in the last 45 days — Code tab and terminal sessions alike — and the subagent transcripts under each session's folder. A byte search skips every line that does not carry token usage (`"usage":{`), a limit hit (`"quotaLimits":{`) or a prompt you typed; only those are parsed. From a usage line it takes the model, the input, output and cache-write (five-minute and one-hour) token counts, the time, and a hash of the message and request ids, and keeps the call's weighted spend (below) in a ten-minute sum. One API message is written once per content block, and copies or forks of a transcript repeat it, so each call counts once, in the earliest-born file that holds it. From a limit hit, its kind, its exact reset and when it was hit — and a copy repeats those too, so each hit counts once as well, keyed on its kind, reset and hit time to the minute, for the account that owns the earliest-born file: a session copied to another account after a limit hit does not give that account the original's limit. From a prompt, its time.
- **Whose activity it is**, from each profile's session records, found by the same rule as the Sessions submenu ([§2.13](#213-copying-a-session-to-another-account)): a record names its transcript (`cliSessionId`, and the ids of the session's earlier transcripts), a subagent's transcript belongs to its parent session, and Desktop runs each session with its own profile's token. On this Mac every one of 190 Code sessions belonged to exactly one profile, and the other account's spend, added to a fit of an account's recorded figure, came out with a weight of about zero. A transcript that no record names — a terminal CLI session, a session whose record was deleted — is *unattributed*: left out of every account and counted in Diagnostics (A6). A session's spend stays with its account after its record is deleted.
- **`~/.claude.json`**, for the account the terminal CLI is signed in to, matched to a profile through the account its session store belongs to: the plan tier, which the index remembers per account (A5); and, only within an hour of its fetch, the cached usage check — its weekly and five-hour reset times as exact anchors (never described as a limit hit), its percentages as one more sample. At most 64 MB of it is read, and nothing else in it is used.
- **`~/.claude/sessions/<pid>.json`**, Claude Code's registry of running sessions: which are busy mid-turn right now (A12).
- **Not read:** Chromium's HTTP cache, which does hold the whole usage answer — exact reset times and the Fable-only weekly figure included — compressed with zstd, which macOS cannot decode without a library this project does not have (A11); and Cowork's transcripts.

**The activity index** is `~/.config/claude-switcher/activity-index.json`, beside `config.json`: the only file this feature writes, mode `0600`, written whole under a temporary name and renamed into place. A write cut short — by Quit, or by the self-updater's relaunch — can leave that temporary file, `.activity-index.json.<UUID>.tmp`; the copy holding the lock removes it at its next launch, before its first refresh, and nothing else: only a regular file of exactly that name, more than a minute old — never a folder, a link, or another switcher's write in progress. It holds numbers and ids only — session (transcript) ids, model ids, plan-tier ids, each transcript's file identity, size and how far it has been read, ten-minute sums of weighted spend, calls and prompts per session, limit hits, and 64-bit hashes of call ids. A transcript is filed under an FNV-1a hash of its path **below** the project folder (`<id>.jsonl`, `<id>/subagents/…`): the project folder's name is not stored in any form, and no title, prompt, message text or path is. A test fills transcripts, records and `~/.claude.json` with words and an e-mail address, and checks that none of them reaches the file.

The index is incremental. A transcript is read on from where the last read stopped, once its last line read is found still in place; one that shrank, was replaced or was rewritten in place is read again from the start; a missing, corrupt or older-format index is rebuilt (the format that keys limit hits as calls are keyed is the third; an index of the second is rebuilt once). The first build reads transcripts changed in the last 14 days; each later refresh reaches seven days further back, until 45 days are covered, and nothing older is kept. It is refreshed off the main thread when the app starts and at every menu open, one refresh at a time, and the menu never waits for it; the file is rewritten only when something changed, or once ten minutes have passed. Every running copy of Claude Switcher keeps it, not only the one holding the automation lock ([§2.11](#211-after-an-update-claude-only-brings-back-the-default-account)): it reads, and writes nothing but this file. `--dry-run` reads it as it is.

**Spend** is the unit all of this is measured in (A4): token counts weighted by list price per million tokens, from the Claude Code 2.1.286 model catalog — input, output and cache writes at their prices, cache reads not at all. It is a weighting, never shown as money. On this Mac it tracked both accounts' recorded weekly figure better than any other measure tried, within about 2 to 5 points; with cache reads counted, one account's error rose from 2 to 24 points. Subagent and workflow lines keep the usage from the start of the stream (a median of 8 output tokens), so their output is filled in per call — 880 tokens for Opus 5.5, 1,500 for Fable 5.1 and Opus 5, 1,000 for anything else, measured from Claude Code's own session totals. A model with no known price is weighted as Opus 5.5 and counted as unpriced.

#### The weekly schedule

The weekly limit is assumed to reset at the same weekday and time every week (A1), at a fixed instant in UTC (A8); Anthropic describes it as a fixed time each week, assigned to the account. One-off resets do not move it (A2): this Mac saw three — Anthropic's launch grants on Tue 09-22 and Thu 09-24, and a drop on Fri 09-04. Every observed reset votes for a phase on a circle one week round:

- **Exact anchors** — the `resetsAt` of a `seven_day` limit hit, or a fresh cached weekly reset time. Any anchor from the last 60 days decides outright, and the newest sets the time.
- **Brackets** — a drop in the recorded weekly figure between two consecutive samples brackets one reset between them. Only a drop that lands at 5 or below, or falls by 20 points or more, counts; a smaller decrease is a sample out of order. A bracket a week or wider is skipped. Each votes 1 / max(1, its age in weeks) × min(1, one hour / its width): a recent, tight bracket fully, an old one or a 73-hour one barely.
- **Clusters.** Brackets that line up — their intervals, shifted by whole weeks, overlap within two minutes — form a cluster, seeded narrowest first, so the answer never depends on the order the drops came in. The best-supported cluster wins, and the intersection of its brackets is the reset interval: the longer Claude has been sampled around reset time, the narrower it is.
- **One never outranks two.** A phase seen in a single sample bracket never outranks one seen in two or more. Only a *sighting* counts for this — an exact anchor, or a bracket narrower than a day; a wider bracket is consistent with every phase it spans, so it votes (barely) and establishes nothing. The design did not have this rule. It was added because the vote alone breaks A2 on this Mac's own data: without exact anchors, the five-minute bracket of the 09-22 grant (a vote of 1.0) outvoted Personal's four Saturday resets, sampled three to eight hours late (0.44 to 0.68 together), for two weeks.
- **Moving.** The schedule moves only for a newer exact anchor that disagrees, or when the two newest sample brackets both disagree with it and agree with each other. A single disagreeing bracket is an *unconfirmed* reset: it changes nothing, `(est.)` comes back on the week row, and the tooltip says it is treated as a one-off until a second one or a recorded limit hit confirms it.

The week row drops `(est.)` only when the schedule is exact and fresh: its newest agreeing anchor or bracket at most 14 days old, and nothing unconfirmed. A recorded time older than that reads `resets Sat 9:00 PM (est.)`, and a bracketed one `resets by Sat 10:09 PM (est.)`, the latest it can be. An account that has never been sampled across a reset, and has no anchor, shows no weekly reset; its first one starts the schedule. Once a scheduled reset has certainly fallen between the reading and now, the row shows `—`. These bounds hold under the assumed schedule, not beyond it: a one-off reset makes the real one sooner without moving the schedule.

#### The five-hour window

A window is assumed to start at its first message, rounded down to a ten-minute mark, and to last five hours; there is none while the account is idle (A3). Every five-hour reset Claude Code has recorded on this Mac falls on a ten-minute mark — a first message at 15:18:31 reset at 20:10.

Inside one window utilization never decreases, so the longest trailing run of non-decreasing `fh` samples spanning under five hours lies within one window. It was already running at that run's first positive sample, so it ends no later than that sample's ten-minute mark plus five hours — the `resets by` shown. The sample before the run belongs to an earlier window, so it ends no earlier than five hours after that one; the tooltip shows both bounds. A `0` sample is an ordinary member of a run, because the histories on this Mac show windows that had already started before a sample that still read 0.

Once that window has certainly ended, this Mac's activity takes over: windows are walked forward, each starting at the ten-minute mark of the first attributed call after the previous one's end, and the one `now` lies in is the open window, ending by five hours after its start. Use elsewhere could only have started it earlier, so that stays an upper bound. When Claude Code recorded a `five_hour` limit hit whose reset is still ahead, or the CLI's cached check reported the window's end within the hour, the end is exact and the row says `resets 9:10 PM`. Once a recorded end of the sampled window has passed, that window has ended, whatever its bound says — the bound is floored from the window's first sample, and on Oct 5 it lay more than three hours after the end Claude Code recorded — and the walk of this Mac's activity starts there. How full the window is now is the recorded `fh` plus this Mac's spend since that sample at the account's window calibration — or, for a window only activity shows, that spend alone. A five-hour limit hit recorded after the sample reads 100 — on the row too, as recorded — until its reset, after which this Mac's activity decides whether a new window is open. The estimate has a cautious upper bound, as the week's has: the five-hour fit's typical error (twice it, at least 4 points; 10 at the defaults) and 2 points an hour for use the transcripts cannot see, since the later of the window's last recording and its start, at most 10. The Advisor fits sessions against that bound; the line and Diagnostics keep the estimate itself. Replayed over this Mac's last 14 days, the recording that followed each estimate fell inside its bounds 57 times in 66 on one account and 50 in 71 on the other (with no upper margin: 20 and 12).

#### The forecast

For the week now — the cycle the schedule puts the present in:

- **Used.** The latest sample taken this week is a floor, since weekly usage only rises until the reset; this Mac's spend since is added to it, at the account's calibration (below). The upper bound adds a margin — 6 points, or twice the calibration's typical error if that is more — and 2 points for each day since the sample, for use the transcripts cannot see: claude.ai, the phone, other Macs (A9). With no sample since the reset, the estimate is this Mac's spend since it, between 0 and the same kind of upper bound. A weekly limit hit Claude Code recorded after the latest sample fills the week. The headroom the Advisor may spend is 100 minus the upper bound.
- **The basis** each estimate stands on, which the tooltips name: recorded (a sample under 30 minutes old, nothing spent since); recorded plus activity; activity only; recorded with no reset seen yet (the sample is still a floor, the reset time unknown); defaults (nothing ever recorded); or too little to say, and why.
- **Pace** is the faster of the week so far — counted only from 12 hours in and 10 % used, as Claude's own projection does — and the last six hours of activity. After a one-off reset inside the week, the week's pace counts from that reset.
- **The projection** is linear at that pace to the reset: the limit is reached about then (`out about Thu eve`), or this much would go unused (`~28% unused by Mon 5 AM`). The last four weeks — in how many the limit was reached, how much went unused — are in the tooltip and do not enter the projection.
- **Committed.** A session the registry reports busy is charged the 75th-percentile cost of its size — by how long it has run so far — less what it has already spent, against the week and the window (A12); a session idle between turns is not.
- **Blocked.** A Fable or per-model weekly limit that Claude Code recorded as hit, and whose reset is still ahead, keeps medium and long sessions off that account until then.
- **Unread time.** Spend after the index's last read counts as nothing in the estimate, so the upper bounds are widened for it, at the account's fastest hour of the six before that read. An index more than an hour old is not estimated from at all: recorded values only and no advice — the app shows `Reading activity…` while it catches up, and `--dry-run` says how old it is.

An account with neither a sample nor any activity in seven days is *stale*: it can still take a short session when nothing else can, never a medium or long one.

#### Calibration

How many points of an account's week one unit of spend is worth (k_w), and of its five-hour window (k_f), is fitted to that account's own history. It is worked out afresh at every read, in about a millisecond, and not stored.

- **Weekly.** The history is cut into *segments* at every reset — scheduled or one-off — so that none straddles one, and also where a scheduled reset has certainly passed and at a gap of a week or more. In each segment, the rise of the weekly figure since its first sample is regressed through the origin on the spend since; samples at 100 are left out, because the true value is cut off there. A segment counts with at least 10 samples, a rise of 20 points and R² ≥ 0.9. k_w is the median over the counting segments of the last 45 days, once there are two; the typical error is their median rms error. Spend from before the index's coverage begins is never fitted on.
- **Five-hour.** The same per window, over its longest run of samples at most an hour apart, rising at least 5 points with r ≥ 0.9; the median once 8 windows count.
- **Defaults**, until an account has calibrated: 1/13.5 of a point per unit for the week (about 0.074) and 1/3.3 for the window (about 0.30), with a typical error of 3 points — the values measured on this Mac's two Max 20x accounts (A5). Whatever rests on them says so: `(default)` in Diagnostics, *using defaults for Max 20x* in the tooltip.
- **The scale gate.** At every sample inside a segment, the rise the calibration predicts since the previous sample is compared with the rise Claude recorded. Once the prediction is 10 points or more and the recorded rise is under half or over twice it, the calibration may belong to another plan: the weekly and window weights both go back to the defaults and the segment restarts at that sample. The flag says how likely a plan change is: `plan may have changed — recalibrating` for a trip at 3 times the prediction or more (or a third or less), the smallest step between plans being 4; `recalibrating after an unusual sample` for a smaller one, which use the transcripts cannot see can cause. A confirmed move of the weekly schedule, or a new plan tier named in `~/.claude.json`, also restarts it, flagged as a plan change. The flag stays until two new segments count — on this Mac's history, 26 hours.
- **A5, as built.** The defaults are a Max 20x account's, and on Pro or Max 5x a session costs about 20 or 4 times as many points. So an account whose plan `~/.claude.json` names as anything but Max 20x is offered short sessions only while it is on the default calibration; and an account whose plan is not named is held to short sessions after a gate trip only when the trip was at 3 times or more. The design had the gate catch a Pro account after its first pair of samples, which cannot happen — that pair would need about 200 recorded points to reach a predicted rise of 10. It also had any flagged calibration hold medium and long back; on this Mac's own history the gate trips once on noise (below), and that would have held one account back for a day or more — until two new segments calibrated, 26 hours there.

#### Session costs

A session's cost is measured from this Mac's own *episodes* — activity in one session with no gap longer than 30 minutes — finished within the last 30 days, pooled across accounts in spend units, and turned into each account's points with its own calibration. Sizes go by duration alone (A10): short under an hour, medium one to three hours, long over three hours — or a *workflow run*, an episode in which subagents made at least half the spend. A size uses its own p50 and p75 once it has 8 episodes, and the defaults until then (A15). A long session is fitted on its first three hours (week) and its first hour (window); its whole p75 decides whether it will likely stall.

The defaults were re-derived from this Mac's 132 finished episodes of the 30 days to Oct 6, under exactly these sizes. In points at the default calibration, p50 / p75: short 0.4 / 1.0 of the week and 1.8 / 4.2 of a window; medium 2.1 / 3.1 and 8.5 / 12.7; long 6.7 / 12.6 of the week (5.5 / 8.0 in its first three hours) and 12.7 / 21.2 of a window in its first hour. The design's figures (short 1 / 2, medium 3 / 5, long 15 / 30) were cut by duration alone; counting a workflow run as long moves the subagent-heavy hour-or-two sessions out of short and medium. One consequence: the default reserve is about 2 points of the week, not the design's 4.

#### The Advisor

For each size the Advisor applies four goals, in the order they bind: never recommend an account the session cannot fit; always keep one account with usage available; use the accounts fully, budget that would be lost at a reset first; and be stable.

1. **Fit.** An account fits when its headroom, less what its running sessions will still take, is at least the size's p75 (a long session's first three hours), and its five-hour room, less what those sessions will still take of it, is at least the size's window p75 (a long session's first hour) — or, for medium and long, its window clears within 15 minutes, which makes the row `→ Personal after 9:10 PM`. Medium and long never go to an account that is blocked by a Fable or per-model limit, has never recorded usage, has too little data or is stale, or is held back under A5. Such an account can still take a short one — one with too little data, or stale, only when nothing else can.
2. **Reserve.** After the session, some other account must still have two short sessions' worth of week (about 2 points at the defaults) and room in its window for one, or a window that clears within the hour — or the account itself must keep that much after the session. With one account only the second can hold, and the footer says `Only one account — no reserve is possible`.
3. **Eligible** means fit and reserve. When no account is: medium and long get `nothing fits right now` with the next chance; short gets the account that fits with the most headroom, as `last headroom`, or nothing fits either.
4. **Rank**, each step keeping the accounts within its margin of the best:
   1. budget that would go unused at the reset (5 points or more) › not known (no pace yet, or no reset time) › under 5 points unused, or running out;
   2. ready now › must wait for its window;
   3. among the first, more unused (within 5); among the second, more headroom (within 10); among the third, for medium and long an account with at least twice the session's p75 left before a thinner one, then the sooner reset (within 6 hours) — short sessions go straight to the sooner reset (A13);
   4. more window room (within 10); then a running account; then the order in the config.
5. **Stability.** An earlier choice for the same size that is still eligible is kept — `still Work — chosen 40 min ago…` — unless the new one would save at least 10 more points from going unused, the earlier one now has to wait for its window and the new one does not, or a weekly reset has passed on either since. Saving counts only budget there is to save: an account that will run out scores 0, however far short it falls. The design scored the projected unused points themselves, and when both accounts were going to run out, a difference between two shortfalls (−235 against −346) counted as "clearly better" and the choice went back and forth; this is a deliberate amendment. An earlier choice also keeps fitting while it is short of the size's p75 by less than a point, so that a wobble of the estimate between reads does not drop it. There is no time limit. The earlier choices are kept in memory only, so a relaunch starts afresh. Replayed over this Mac's last 14 days, every remaining change of account for a medium or long session came because the earlier account no longer fitted or a reset had passed.
6. **Reason:** the step that set the winner apart; or `the only account it fits`; or `keeps … in reserve`, when the account that would rank first was passed over for the reserve's sake. For an account whose reset time is not known yet, or that has never recorded usage, the reason says that instead.
7. **Stall.** For a long session placed where less than a whole long session's p75 is left, when it will likely reach the limit: that headroom at the faster of the account's pace and a typical long session's (its p50 over three hours), shown coarsely (A14).

The whole read behind the menu — every account's samples, `~/.claude.json`, the forecasts and the three answers — took about 3 to 6 ms (median) over this Mac's real files in a release build, off the main thread, depending on how many sessions are busy.

#### The assumptions

The design names fifteen assumptions the owner must see. Each is labelled where the design says, and Diagnostics' `ADVISOR` section lists the five every answer rests on (A1, A3, A4, A5, A9).

| | Assumed | How the menu labels it | If it is wrong |
| --- | --- | --- | --- |
| A1 | The weekly limit resets at the same weekday and time every week; only a plan change moves it. | Week tooltip: *Assumed to repeat weekly at the same time; a plan change would move it.* Diagnostics: `(A1, A8)` on `schedule:`, `(A1)` under `ADVISOR`. | On a rolling week the schedule, the weekly cycles, the projection and the run-out are all wrong; the week would have to be modelled from first use. |
| A2 | One-off resets — the 09-22 and 09-24 grants, the 09-04 drop — do not move the schedule; a plan change does. | An unconfirmed reset: `(est.)` back on the week row, the tooltip's *treated as a one-off and unconfirmed until a second one or a recorded limit hit confirms it*, Diagnostics `unconfirmed reset at … treated as one-off (A2)`. | A real move shows a week late, when a second bracket or a limit hit confirms it. |
| A3 | A five-hour window starts at the first message, rounded down to a ten-minute mark, and lasts five hours; there is none while idle. | Tooltip: *Assumed: a 5-hour window starts at the first message, rounded down to 10 minutes.* Diagnostics: `5h window: 10-min floor assumed (A3)`. | `resets by` could be up to ten minutes early; the fix is the unfloored bound. |
| A4 | Usage is proportional to input, output and cache-write tokens at list prices, cache reads excluded, with subagent output filled in per call. | Tooltip: *Costs are weighted from token counts at list prices, calibrated to this account’s own history (4 segments, fit 1.00, ±1 point)*, or *… using defaults for Max 20x (not enough history yet)*. Diagnostics prints the fit. | The estimates drift between recordings. The recorded floor and the p75 fit test still hold, and a wrong fill-in is absorbed by the calibration, which is proportional. |
| A5 | The default calibration and costs are those of this Mac's two Max 20x accounts, and an account whose plan is not named is on Max 20x. | `(default)`; footer *Costs are defaults for Max 20x; Work’s plan is unknown* (or names the plan; *Work’s calibration uses defaults for Max 20x; its plan is unknown* when only the calibration is a default); Diagnostics `plan: unknown (defaults assume Max 20x, A5)`; clause *on …, not the Max 20x the defaults assume — short sessions only until its own history calibrates*. | On Pro or Max 5x a session costs about 20 or 4 times as many points. A plan `~/.claude.json` names is held to short sessions until it calibrates; an unnamed one only after a gate trip of 3× or more — until then it is advised on Max 20x figures, with the footer as its only warning. |
| A6 | Spend in a transcript a profile's records name belongs to that profile's account; terminal sessions outside any record belong to none. | Diagnostics: `x% of spend unattributed (A6)`. | Activity is assigned to the wrong account; recorded values are unaffected. |
| A7 | The Opus, Sonnet and Fable weekly limits reset on the same schedule as the week. | No separate reset is shown; Diagnostics `limits:` lists the hits by kind `(A7)`. | Only those rows' ended state, and when a Fable block ends, are affected. |
| A8 | The weekly reset is a fixed instant in UTC, not a local clock time across daylight saving. | Diagnostics shows it in local time and UTC. | After Nov 1, 2026 the times shown are an hour off until the next exact anchor. |
| A9 | Use from claude.ai, the phone or other Macs is unseen between recordings and is allowed for at 2 points a day in the upper bound (measured here: about 1.5 a day on one account, 0 on the other). | Tooltip: *… allowed for at 2 points/day*; Diagnostics `(A9)`. | If yours is heavier, raise `UsageForecast.unseenPointsPerDay`, one constant. |
| A10 | Sizes go by duration: under an hour, one to three hours, over three hours or a workflow run. | The row titles. | The labels and buckets change; costs recalibrate from your own sessions. |
| A11 | Chromium's HTTP cache is not read, so exact five-hour ends and the Fable-only weekly percentage stay estimated or unseen. | The `5h` row keeps `(est.)` unless Claude Code recorded the end; tooltip *The Fable-only weekly limit is not recorded locally*. | A reader would plug in at `ExactUsageSource`. |
| A12 | A session the registry reports busy will still cost its size's p75 less what it has spent; one idle between turns will cost nothing more. | Tooltip *A long session is running here (~20% of the week still committed, est.)*; clause *a session is already running there (~20% committed, est.)*; Diagnostics `committed`. | If you leave sessions idle between big turns, the reserve can be overstated. |
| A13 | When every account will run out anyway, short sessions go where the week resets soonest, and medium and long first where at least twice their cost is left. | Reasons `resets soonest (…)` and `comfortable margin; … has only ~N% left (est.)`. | One ranking step to swap. |
| A14 | A long session that will likely stop part-way is still worth placing where the reserve holds, with the time shown, rather than refused. | `(likely hits the limit about Wed morning)`, reason `the first 3 hours fit; … keeps ~N% in reserve`. | Fit long sessions on their whole p75 instead; the row would then say `nothing fits` far more often (the design's estimate: five days in seven). |
| A15 | The default session costs are this Mac's last 30 days of sessions under these sizes, p50 and p75. | Diagnostics `costs: short 0.4/1.0 default, …` `(p50/p75 week points, defaults; A15)`; footer *Costs are defaults for Max 20x — fewer than 8 sessions of each size recorded*. | The fit test is off by the difference until a size has 8 of your own sessions. As built they were re-derived ([above](#session-costs)); the design's own figures no longer hold. |

#### What is verified, and what is not

- **Read in Claude's code**, and confirmed in its log and files on this Mac: Claude Desktop's sampler — what triggers a sample, the 270-second throttle, the 30 days kept, the keys, and that no reset time is stored; the claude.ai page's requests at a limit and at its reset; the server's 24-hour tray rule, in the log since 2026-10-01; a running account with no sample for 33 hours because nobody right-clicked its icon; samples at the exact reset of an account at its limit. Claude Code 2.1.286 writing `quotaLimits` on a refused request, and its `~/.claude.json` usage cache.
- **Measured on this Mac's own data**, with throwaway programs that read the real files and printed numbers only (an index built for them was written to a scratch folder and deleted). The two accounts are called Personal and the second account here.
  - The weekly weight: Personal 0.0704 per unit (1/14.2; 4 counting segments, median R² 0.998, rms error 0.81 points); the second account 0.0760 (1/13.2; 4 segments, R² 0.997, 1.21 points). An independent analysis made while the feature was designed had 1/13.8 and 1/13.0. Personal's segments, one by one: 0.132, 0.088, 0.065, 0.072, 0.077 and 0.069 — the first two inflated by use the transcripts cannot see; the second account's from 0.066 to 0.081.
  - The window weight: 0.345 (1/2.90, 17 windows) and 0.314 (1/3.18, 20 windows), about 10 % steeper than that analysis (1/3.16 and 1/3.52).
  - The scale gate over the whole history: one false trip, Personal on Sep 21 at 07:17, when the two inflated segments predicted 12.7 points and Claude recorded 6 (a ratio of 0.47) — now labelled an unusual sample, not a plan change; the flag lasted about 26 hours, until two new segments counted. Every other pair predicting 10 points or more fell between 0.66 and 1.87, and the final calibration is not flagged.
  - Spend against an independent count: Personal's from its Sat 10-03 21:00 reset to 10-05 18:47 came to 887 units against the analysis's 858 (3.4 % apart) — about 64 % of its week, where the analysis said 62 %.
  - Unseen use: two unexplained jumps on Personal, of about 15 and 13 points, and a drift of about 1.5 points a day with nothing on this Mac; none on the second account. Hence A9's 2 points a day.
  - Attribution: 0.2 % of spend unattributed over the first 28 days of history, 4.3 % at 35 days, about 9 % at 45 — older transcripts no current record names. No call had an unknown model once Claude Haiku 4.5 was added to the price table.
  - Session costs: the 132 episodes behind the defaults — 49 short, 14 medium, 69 long (the long ones' whole p90 was 31.4 points).
  - The index over the real transcripts: the first 14-day build 5.1 to 7.4 seconds over about 3,700 transcripts (5.2 GB), 4.3 to 5.4 seconds in a later set of runs, which also measured the memory it leaves behind: about 50 MB (49 to 54) with 256 KB reads, which stays for as long as the app runs. With the 2 MB reads first used it was 105 to 116 MB, almost all of it allocator fragmentation — memory in use was under 10 MB — for no gain in speed; each reach-back 0.3 to 1.2 seconds, up to about 5,350 transcripts at 45 days; a refresh with nothing new 0.06 to 0.08 seconds; a relaunch from the file 0.12 to 0.20 seconds; the file about 5 MB. All with the disk cache warm — emptying it needs administrator rights, so a cold build was not timed.
  - The answers over the real files on Oct 6, about 13:40, with Personal recorded at 93 % that morning: Personal `~93% used (est.) · out about this eve`, the second account `~13% now (est.) · recorded 0% 3 h ago`; every size to the second account, `the only account it fits; Personal cannot fit: ~0% of the week left (est.)`; costs from this Mac's own sessions (short 67, medium 16, long 59); both reset times exact.
- **Tested** — 182 tests on fixtures, in temporary homes where files are involved, none of which touches the real transcripts, Claude's files or `~/.config`: the schedule (the vote, the one-vs-two rule, re-anchoring, wide brackets, every input order), the window and its floor, the timeline, the index (duplicate lines, the subagent fill-in, cache reads, attribution, incremental reads, truncated and rewritten files, a corrupt index, and that it holds no text), the `~/.claude.json` reader, calibration and the gate, the forecast, session costs, every rule of the Advisor, the wording (every forecast line at most 40 characters with its hedge within 32, the `(est.)` rule) and the snapshot (no advice while the index is being built or is stale) — and the 43 usage-history tests, now on the schedule model. The menu built from all this, the patching of an open menu, the after-time row, Diagnostics and `--dry-run` are checked by 18 tests in a scratch package that imports the app target, kept outside this repository, and the bars were drawn offscreen in light and dark. While it was built, rule by rule, 46, 94 and 53 weakenings of the Core code in three rounds, and 39 of the wording and the app's wiring, were each made in a scratch copy, and each made its named test fail; after the second review, 43 more of the Core code and one of the wiring, all of them caught.
- **Not verified.**
  - **The running app.** The Advisor has not yet been seen in the menu bar: the menu's width with the longer notes, the lighter segment in a real menu, the patching of an open menu, an after-time row coming on, and the first build of the index inside the app have run only in tests and harnesses. Until the app has run, no index exists on disk, and `--dry-run` says so.
  - **The model.** A1 to A15 are what Anthropic's limits look like from two Max 20x accounts' history on one Mac, not something Anthropic documents — its documentation gives no relative weights between models or token types. A Pro or Max 5x account, a plan change, the daylight-saving change on Nov 1, 2026 (A8), a new model or effort setting — 124 of the 126 sessions measured ran at the same effort — and a change to the server's tray rule have been tried on fixtures only, or not at all.

#### Two review rulings that were not applied

A second review, of the app's side and this README, confirmed 18 more findings, and all were applied — among them the copied session that carried its account's limit hits to the other account, a recorded five-hour end that was ignored once it had passed, estimated window times in **Start a session in…** without `(est.)`, and "tonight" said of yesterday in the small hours. One amends the design: the stability score ([above](#the-advisor)).

The build was reviewed adversarially, and a judge confirmed 26 findings. 24 were fixed as ruled and one in part; two of the judge's instructions were not applied, each because, applied as written, it broke a test the design of record requires. Both conflicts were reproduced in scratch copies.

- **"The first phase seen stands until it is confirmed."** With no exact anchor and no phase seen twice, the ruling would take the schedule from the oldest bracket narrower than a day, and treat every newer disagreeing one as unconfirmed until two agree. Applied, it made `testWideBracketBarelyVotesAndOrderDoesNotMatter` answer Friday in every order — there the vote and the first sighting want opposite answers. Left as it is, an account with no exact anchor can, in its first weeks, take a narrow one-off bracket for its schedule and call the real reset the one-off: replayed without anchors, the second account on 09-24 still resolves to the Thursday grant. On this Mac that is hidden, because Claude Code recorded exact anchors for both accounts. A rule that satisfies both — the first sighting holds only while the disagreeing one comes within a week of it — is a design decision, and has not been made.
- **A cumulative scale gate.** The ruling would compare the rise since a segment's first sample, as well as each pair's, so that a move to a smaller plan is caught. Applied, it broke `testKIsMedianOfQualifyingSegments` and `testScaleGateDropsToDefaultsOnPlanChange`, and against the defaults it would keep a Pro or Max 5x account from ever calibrating. Without it, a calibrated account that moves to a smaller plan is caught only when `~/.claude.json` names the new plan. The other half of that ruling was applied: the index remembers each account's plan tier, and a change of tier restarts the calibration, flags it, and holds medium and long sessions back.

#### The first live look

This is the check the Advisor is waiting for: until it has been done, the menu that shows it has not been seen.

1. **Open the menu right after the first launch.** Expect `Reading activity…` in **Start a session in…** and under every account, then — within seconds on a Mac like this one — the lighter segments, a grey line under each account and three rows. **Diagnostics…** should then show `activity index:` with a few thousand transcripts and little spend unattributed (0.2 % for two weeks of history on the Mac this was built on), and each account's `schedule:` should say `exact` if Claude Code has recorded a weekly limit hit in the last 60 days.
   - `Reading activity…` that does not go away: the build has not finished, and Diagnostics says `activity index: not built yet`. `activity index could not be written (…)` in Diagnostics: what was read is used, but kept in memory only, until the app quits.
2. **Look at the width.** Every note after a bar should be whole, and every line keep its `(est.)` visible.
3. **Compare with Claude's own Settings › Usage**, in each account. The percentage beside a bar should be the one Claude last recorded; the estimate should be near what Claude shows now; a week row without `(est.)` should show Claude's own reset time.
   - A week row without `(est.)` whose time differs from Claude's: the schedule is wrong — read its `schedule:` line.
4. **Right-click Claude's icon** for one account, then reopen the menu: that account's age in the submenu's footer (`usage last recorded …`) should now be a minute or less.

The files are only ever read; nothing is fetched, and no token or cookie is touched. If a Claude update changes the samples' format, the bars disappear rather than mislead.

### 2.11 After an update, Claude only brings back the default account

Observed: a named account quit itself for an update at 00:58:00 (stopping two Code sessions on the way down); the install ran 00:58:01–05; the installer relaunched Claude at 00:58:07 — with no arguments, which is the *default* account. The named account stayed closed for eight hours.

Claude leaves a precise record of this. Every quit-for-update — the idle "stealth" update and "install now", and no other kind of quit — writes `update-attempt` into that account's own user-data directory: `{"fromVersion", "toVersion", "ts"}`. Only that account's next launch reads and deletes it (it is how Claude logs "Previous update install succeeded"). So a marker that is still there, for an account that is not running, whose `fromVersion` is no longer the installed version, means exactly: *this account closed itself for an update that has since been installed.* An account you quit yourself has no marker and is never reopened.

With **Reopen Accounts After Claude Updates** on, the switcher watches for Claude instances going away (and looks once at startup and on wake), and then:

- waits for Claude's installer to have *stayed* gone — and never launches while one is alive, not even the one that lingers after installing;
- stands down when another instance is blocking the install ([§2.9](#29-updates-need-every-instance-to-quit)): an account reopened then would only quit itself for the same update again, so nothing is launched and no timer is left running — the install cannot start without another instance quitting, which is what triggers the next look;
- starts the named accounts in the background — it asks macOS not to bring them to the front; how Claude then restores its own window is Claude's decision — skipping any that are already up, checking again before *each* launch that no installer has appeared, never while an instance it cannot identify is running, and one launcher at a time with the menu;
- treats the **default account** more warily: Claude's installer relaunches it itself, just before it exits, so it is only started here if it is still absent fifteen seconds after the installer has gone. Two processes on the default account's data is the failure this guards against;
- does all of this from **one** switcher process only: a lock file in `~/.config/claude-switcher/` means a second copy of the switcher (a `swift run` next to the installed app) never doubles a launch;
- ignores markers from before the last boot, older than a day, or already acted on.

The default-account instance the installer starts is left alone even if you did not have it open: **anything this app does to Claude on its own initiative only ever launches.** The code that runs it is handed effects that can start things and nothing else — there is no way to quit from it — and the marker file is only ever read. (The other things the app does unasked leave Claude alone: finishing or cleaning up an interrupted session copy, [§2.13](#213-copying-a-session-to-another-account), updating Claude Switcher itself, [§2.14](#214-claude-switcher-updating-itself), and keeping its index of this Mac's activity, which only reads Claude's files, [§2.10](#210-where-the-usage-bars-come-from).)

### 2.12 Blocking Claude's auto-updates

Reopening puts an account back, but the sessions it was running were still stopped. Claude Desktop has a supported switch for not updating at all: the policy key `disableAutoUpdates` ("Block auto-updates"). With it set the updater never starts.

Claude reads policy from a root-owned plist in `/Library/Managed Preferences` — an administrator's channel, which this tool never touches — and, when no such plist is in force, from a per-profile *configuration library*: `<user-data dir>-3p/configLibrary/_meta.json` names the applied configuration and `<id>.json` holds it (`Claude-3p` for the default account). Verified against a throwaway instance on a temporary profile: with `{"disableAutoUpdates": true}` applied, Claude logged `[updater] Auto-updates disabled by enterprise policy` and never enabled its updater, and nothing else about the app changed.

**Block Claude Auto-Updates** writes exactly those two files for every account (and for accounts added later, before their first launch). What it costs, from the app's own code: security and compatibility fixes stop arriving; the Code tab's `claude` CLI stops updating too; "Check for Updates…" disappears from Claude's menu; Claude reports `update disabled: enterprise_policy` in its telemetry; and an update that is *already* downloaded still installs. To update, turn the block off and restart an account.

Apart from a session copy's files ([§2.13](#213-copying-a-session-to-another-account)), made only when you confirm a copy, these are the only files this tool ever creates inside Claude's data area, and only on your toggle. The rule for everything it does here: **a file is ours only if it is a regular file, readable, and says exactly what this tool wrote.** Anything else at either path makes the whole library someone else's, and it is then **never touched** — not overwritten, not merged into, not removed; the account is reported as left alone. That covers another configuration being applied, an organization-managed pointer, an index that cannot be read, a directory or a symbolic link where a file should be, a symlinked library directory — and the subtle one: Claude's own setup screen saves into whichever configuration is open, and with the block on ours is the only one, so a file *with our id* may come to hold your provider settings. "Exists but is not exactly ours" is never treated as "ours, but damaged"; only one of our two files being cleanly absent is. Each path is looked at again immediately before it is written or unlinked. Turning the block off unlinks only files that are still exactly ours, then `rmdir`s the library directory — which succeeds only if it is truly empty; its parent is Claude's own directory and is never removed.

### 2.13 Copying a session to another account

Claude Desktop can already turn one session into two. Its Code tab's fork (`LocalSessionManager.forkSession`, read in Desktop 2.19675.0) copies the transcript, unchanged, to a new id in the same project folder; appends one line for each Remote Control pointer still live, clearing it; copies the subagent transcripts the conversation references; and files a new record. It will not fork across accounts — *"Cannot fork: the account changed while the fork was being prepared."* Claude Switcher makes the same copy into another account, with a record built for that account instead of one carried over.

**Where a session is.** A record in the account's store, `<user-data dir>/claude-code-sessions/<account>/<organisation>/local_<id>.json` ([§2.5](#25-the-code-tabs-session-list-is-per-account-the-transcripts-are-shared)), names a transcript, `~/.claude/projects/<slug>/<cliSessionId>.jsonl`; the transcripts of its subagents are in `~/.claude/projects/<slug>/<cliSessionId>/subagents/agent-<agent id>.jsonl` (older ones flat, as `~/.claude/projects/<slug>/agent-<agent id>.jsonl`). `<slug>` is Desktop's `cliProjectDirSlug` of the record's `cwd`, ported exactly: the raw string NFC-composed, every UTF-16 unit that is not an ASCII letter or digit replaced by `-`, and past 200 units the first 200 followed by `-` and the base-36 magnitude of a 31-multiplier hash of the whole string. The `cwd` is deliberately not normalized first — collapsing a `//` or dropping a trailing `/` would name a different folder.

**What a copy creates.** With `<X>` the original's transcript id and `<Y>` a fresh lowercase UUID — this, and nothing else:

| Where | What |
| --- | --- |
| `~/.claude/projects/<slug>/`, the original's own project folder | `<Y>.jsonl` — the transcript |
| the same folder | `<Y>/subagents/agent-<id>.jsonl` — one per referenced subagent transcript found; the folders only when there is at least one |
| the target's store, `claude-code-sessions/<account>/<organisation>/` in its profile | `local_<Y>.json` — the record |
| `~/.config/claude-switcher/copies/` (made `0700` if absent) | `<Y>.json` — the journal, written by way of `.<Y>.json.partial` |

While a copy is under way, the three pieces in Claude's folders exist under staging names instead — `.claude-switcher-copy-<Y>.jsonl.partial` and `.claude-switcher-copy-<Y>.dir` (holding `subagents/`) in the project folder, `.claude-switcher-record-<Y>.partial` in the store — and are renamed into place at the end. Claude does not load them: Desktop loads only `local_*.json` and its startup repair touches only `local_*.json.tmp`, a transcript is `<id>.jsonl`, and the names avoid every temporary-file pattern Claude uses. The one Claude process known to look inside the staging folder — the terminal CLI's cleanup, which removes old files from any `subagents/` folder — goes by modification time, one more reason every file is written fresh, never cloned: its own inode, one link, a modification time of now. Files are `0600` and folders `0700` whatever the umask. Nothing is written into the source account's store, into `<X>.jsonl` or `<X>/`, or into `~/.claude/file-history`, `uploads` or any tool-results folder.

**The transcript.** `<X>.jsonl` is opened once, without following a link and without blocking (so a pipe planted at the name cannot hang the copy); it must be a regular file with one link, yours, and not empty. It is read with `pread` up to the size seen at open; then the same descriptor's `fstat` and an `lstat` of the name must show the same size, modification time, change time and inode, and no read may have come up short. Anything else — Claude appending, rewriting in place, truncating, replacing — throws the read away; it is taken again every 250 ms for up to five seconds, and then the copy is refused as *still being written*. (Before that, a session that Claude Code's own registry, `~/.claude/sessions/<pid>.json`, shows mid-turn in a live process is refused as *still replying* — advisory; the before-and-after comparison is the guarantee.) The copy is that read, cut after its last line feed — anything after it is a line still being written — byte for byte. No line is rewritten: each keeps the original's `sessionId`, `uuid` and everything else, as in Desktop's own fork. Claude Code looks a session's state up through the `sessionId` of its last message and never compares a transcript's file name with its lines; both were read in its code.

Then, for every `sessionId` whose **last** `bridge-session` line still holds a live `bridgeSessionId`, in the order those ids first appear, one line:

```json
{"type":"bridge-session","sessionId":"<that id>","bridgeSessionId":"","lastSequenceNum":0}
```

— exactly the bytes Desktop's fork appends and Claude Code's own `clearBridgeSession` writes. Without it, the other account's Claude would reattach to the original's Remote Control session — or, seeing a different owner, refuse, and mark the conversation so that its history is never uploaded again. Every line is parsed, not only those Desktop's quick text filter would pass, and the copy is refused when a session's last `worktree-state` line binds a worktree (Claude Code re-enters it on resume; only its own fork strips it), when an `artifact-comment-monitor` was last in any state but `stopped` (restored on resume; what it would do under another account was not traced), when a live pointer's session id is not all `[A-Za-z0-9_-]` (no clearing line can be written for it the way Claude writes one), or when a line that does not parse mentions any of those three types.

**Subagent transcripts.** The ids are the `toolUseResult.agentId` of Desktop's ten row types, skipping compact summaries and transcript-only rows, as Desktop's fork takes them — and only ids made of `[A-Za-z0-9_-]`, which keeps a `..` out of the path. Each is looked for where Desktop looks: `<X>/subagents/agent-<id>.jsonl`, and only when that path does not exist, the older flat `agent-<id>.jsonl`. A link on either path refuses the copy; a file that is missing or unusable is skipped and counted, and the result says how many. Each is copied byte for byte up to its last line feed, always into the nested layout, one open at a time. Nothing else under `<X>/` comes along: no `.meta.json`, tool-results or workflows. Copying them unchanged is safe from Claude Code's cleanup: both versions read skip `<Y>/subagents` entirely while `<Y>.jsonl` exists, and never look at the session ids on those files' lines.

**The record.** Built field by field — never copied from the original's — and written compact, in this order:

```json
{
  "sessionId": "local_<Y>", "cliSessionId": "<Y>",
  "cwd": "<the original's cwd>", "originCwd": "<the same>",
  "createdAt": <now>, "lastActivityAt": <now>, "indexedAt": <now>,
  "isArchived": false,
  "title": "<title> (copy)",
  "permissionMode": "default",
  "model": "<the original's>", "effort": "<the original's>",
  "sessionPermissionUpdates": [], "alwaysAllowedReasons": []
}
```

- `title` only when the original has one that is not blank, numbered as Claude numbers its forks — `(copy)`, `(copy 2)`, `(copy 3)` — and cut to 200 UTF-16 units with the suffix kept. `model` and `effort` only when the original has them, verbatim. No key is ever `null`.
- `<now>` is one wall-clock time in whole epoch milliseconds, taken after the transcript is staged. Claude declines to remove a deleted session's transcript when `lastActivityAt` is more than a minute older than the transcript's last line, so an earlier time would leak the copy's files.
- `originCwd` is `cwd`: a different value becomes the base repository Claude deletes branches in.
- The bytes are read back after writing and compared, and must contain neither `<X>` nor the original record's id, in any letter case.

Everything else is left out because, in Desktop's delete, archive and startup code, each field arms something in the other account:

- any other transcript id — `<X>` as `cliSessionId`, `priorCliSessionIds`, `unarchivedCliSessionId`, `preClearCliSessionId`: deleting the copy could delete the original's transcript and its folder (the default account cannot see a named account's claim on them). `rewindEdges` would keep renewing the original's file.
- worktree and branch fields (`worktreePath`, `branch`, `keptWorktreeLeftover`, …): archiving or deleting the copy would remove the shared worktree or delete a branch in the shared repository.
- Remote Control ids: deleting the copy would archive the original's Remote Control sessions, with the other account's token.
- `importedFrom`, `stagedTranscriptPath`, the scratch-workspace and SSH/WSL fields: more paths a delete would remove.
- `interruptedByQuitAt`: the other account's Claude would resume the copy by itself at launch.
- `chromePermissionMode`: it would give the other account unsupervised browser actions it never turned on.
- connectors, enabled tools, e-mail address, environment and space ids: they belong to the original's account.

Nor is `titleSource` written (Desktop's own fork leaves it out too), or `adoptedFromOtherSurface`, which tells Claude a conversation arrived from another app.

**In what order.**

1. Resolve both accounts, holding their folders (below), and re-read the original's record from disk rather than the menu's copy of it. Refused here: a row that has changed; a session deleted meanwhile (a `deleted_` tombstone in the source store, or `<X>.desktop-released.json` beside the transcript); a transcript another account's record also claims; too little room for the transcript plus 1 GB.
2. Choose `<Y>` and prove it unused: `<Y>.jsonl`, `<Y>/`, `<Y>.desktop-released.json` and the staging names in the project folder; `~/.claude/file-history/<Y>`; and `local_<Y>.json`, `deleted_<Y>` and `deleted_local_<Y>` in every store folder of every configured account and of every `~/Library/Application Support/Claude*` folder, in any letter case. Only "no such file" counts as absent, and a store that cannot be read refuses the copy. The exclusive creates and renames below are the real guarantee against a clash; this keeps one from being attempted.
3. Write the journal — its contents under a temporary name, then its name by an exclusive rename — each flushed past the drive's cache (`F_FULLFSYNC` — `fsync` alone does not, on macOS) before the first staged byte.
4. Read and scan the original; check the space again, the subagent transcripts counted.
5. Stage the transcript, the subagent transcripts and the record under their staging names — each entered in the journal the moment it exists, each file `fsync`ed — and read the record back, keeping its SHA-256.
6. Mark the journal *staged*, flushed past the drive's cache.
7. Check again: the target still resolves, by the rule below, to the very folder held; the project folder is still the one held; the original's record still names the same transcript and folder; every new name is still free.
8. Rename into place with `renameatx_np(…, RENAME_EXCL)`, each staging name first re-proven to be the file created, at the size written: (1) the transcript to `<Y>.jsonl` — **the point of no return**; (2) the subagent folder to `<Y>`, if there is one; then, with the project folder flushed (past the cache too when the store is on another volume) and the target resolved once more, (3) the record to `local_<Y>.json`. Both folders are flushed, past the drive's cache, and the journal is marked *committed*.

The transcript goes first so that from the point of no return there is always something to finish, never something to undo: undoing would mean removing a file under a name Claude uses, which is never done. Before it, a failure removes exactly what this copy staged — every piece first proven to be the one it created — and then the journal, and the result is *Nothing was copied*. If any piece can no longer be proven (a `.DS_Store` in the staging folder, say), nothing at all is removed and the journal is kept for recovery to report. After it nothing is undone: a failed rename is tried once more, and otherwise the copy is left for recovery, which is tried at once — before the result is shown, usually registering the copy within seconds, and then the result is *Copied to …* like any other — and again at each start. If it still cannot, the result is *The copy is not finished*: *The copy is on disk but is not yet in Work's list. Claude Switcher will finish registering it — now if it can, otherwise at its next start.*, with what recovery said.

**The journal, and recovery.** `~/.config/claude-switcher/copies/<Y>.json` is the switcher's own record of a copy in flight: its phase; the project folder, the target's user-data folder and its store, each by absolute path and inode — never by account, since an account may be removed or re-added meanwhile; and every object created, by name and inode, with its size and, for the record, its SHA-256. It is the switcher's own folder, opened the way the app opens its config — a link to it, from a dotfiles manager say, is followed — but it must be yours and writable by nobody else, since recovery acts on what is in it. A journal is written whole under a temporary name and then moved into place, so a crash never leaves a half-written one to act on.

Recovery runs when the switcher starts and right after a copy that did not finish, before its result is shown — both only when `config.json` has loaded — and before every copy, and only in the switcher that holds the automation lock; a pass started while a copy runs waits for it to end ([§2.11](#211-after-an-update-claude-only-brings-back-the-default-account)). It acts on journal entries and nothing else; it never looks for names. Each journalled folder is walked to again and must be the same inode, and each object is proven before it is touched. Then:

| What it finds | What it does |
| --- | --- |
| Still staging, or `<Y>.jsonl` not in place | Removes the proven staging pieces, then the journal — *its partial files were removed and nothing was copied*. (If a record for `<Y>` is in place even so — two volumes and a power cut — nothing is touched.) |
| `<Y>.jsonl` in place, with the journalled inode, and no record for `<Y>` anywhere | Rolls forward: the subagent folder to `<Y>`; then, if the target is still signed in to the account the copy was made for and resolves to the same store, and the staged record still has the journalled bytes, the record to `local_<Y>.json` — *has been finished*. If the target no longer qualifies, everything stays as it is, to be tried again at the next start. |
| The record in place with the journalled bytes | Marks the copy committed. |
| The record in place, already rewritten by Claude | Finishes without a word: the copy has been opened. |
| Another record or a tombstone for `<Y>` — another account registered the transcript meanwhile, or something else is at `local_<Y>.json` | Files no second record. Removes only its own staged record, proven by its bytes, and completes the subagent folder — *registered by another account*. |
| Anything that fails a proof, a folder others can write to, or a store it cannot read | Touches nothing, keeps the journal, and says so — at each start until it can act. |
| A committed copy | Keeps the journal while `local_<Y>.json` holds exactly the bytes written — that is the *not opened yet* line — and deletes it once the record has changed or gone. |

No branch removes `<Y>.jsonl`, `<Y>/` or any `local_*.json`. Before every unlink the name must be the exact staging name, a regular file with one link, yours, with the journalled inode — and for the record, the journalled bytes. A folder is removed only when empty, with `unlinkat(AT_REMOVEDIR)`, after its inode is checked. Nothing is ever removed recursively. What recovery has done, or could not do, is said in the copy's result alert when it follows a copy, and otherwise in one short line under the menu's `Running:` header (the notes in its tooltip) until the menu has been opened once; a journal it keeps brings its note back at each start. **Diagnostics…** shows the last pass's notes, and lists every copy whose journal is still there and not committed — without acting on any — with where its leftovers would be.

**No links, held folders, exclusive renames.** `O_NOFOLLOW` guards only the last component of a path — `open("a/link/b", O_NOFOLLOW)` follows `link`, as checked on macOS — so nothing below the home directory is reached by path. Every folder from the home directory down to the project folder, and down to the target's store, is opened one component at a time with `openat(…, O_DIRECTORY|O_NOFOLLOW)` and kept open, and every later create, stat, rename and unlink is an `*at()` call on those descriptors; a folder swapped for a link after it was checked redirects nothing. A link anywhere on the way refuses the copy, a symlinked `~/.claude` included. Every folder must be yours, and the project folder and the target's store writable by nobody else. Whether a path is under the home directory is decided by device and inode, not spelling, so `/Users/ME/…`, another Unicode form or `/private/var` for `/var` cannot skip the walk; a user-data folder outside the home directory is opened as its own starting point, a link there followed as Claude follows it — and a path that is spelled outside the home directory but leads into it (a link in `/tmp` to `~/Library`, say) is refused: where the starting point landed is checked on the opened folder, climbing `..` by device and inode to the root, and the same folder spelled from home would be refused for the link below home on its way. The switcher's own journal folder, where a copy starts, must rename exclusively too; when it cannot, the copy is refused with a message that names that folder. Creates are exclusive — `O_CREAT|O_EXCL|O_NOFOLLOW`, and `mkdirat` followed by a re-open without following and a check — and so are the renames: `renameatx_np` with `RENAME_EXCL`, with no fallback to `rename()`, which silently replaces an empty folder, exactly what would be at `<Y>/` if anything were. A volume that cannot rename exclusively refuses the copy. The two accounts' folders are compared by device and inode, so one folder under two spellings (the data volume ignores case) counts as one. The source account's store is only ever read.

**Which folder of the other account.** For the menu the rule is lenient: the account Claude last recorded for the profile — `lastKnownAccountUuid` in its `config.json` — picks the folders; one folder is the list; between several organisations, the one named in the newest `dxt:allowlistLastUpdated:<organisation>` key decides. For a copy it is strict, because Claude loads only the folder of the account and organisation it is signed in to now, and a signed-out profile keeps its old folder:

- signed in: `windowSizeWasSignedIn` is not `false` (when it is absent, an account is recorded), as Claude itself reads it at startup;
- the folder of the account `lastKnownAccountUuid` names — even when it is the only folder there;
- exactly one organisation folder under that account. Which organisation is current is kept only in Claude's `lastActiveOrg` cookie, encrypted with a key in the Keychain, which the switcher does not read;
- and if any `dxt:allowlistLastUpdated:<organisation>` key exists, the newest must name that folder's organisation.

Ids are compared without regard to case, and the rule is applied again immediately before the record is renamed into place. `config.json` is read for those three keys only and is never written; it also holds Claude's encrypted token cache, which is not used. The rule was read in Desktop's code; on the Mac it was checked on, both profiles' keys and folders agree with the folder each Claude's own log says it loaded.

**What is verified, and what is not.**

- **Read in Claude's code** — Desktop 2.19675.0 and the Claude Code 2.1.286 it runs, with 2.1.220 as a cross-check: where records and transcripts live and how Claude loads them; Desktop's own fork, its clearing lines and its subagent copy; the project-folder slug; what each record field arms; that an account's list is read when its Claude starts and not again on closing the window, **View › Reload**, opening a window or waking from sleep; the rule for the target's folder; that deleting the copy in Claude removes only the copy's files, and deleting the original never the copy's conversation; Claude Code's 30-day cleanup and what exempts a transcript from it; the Import hazard under [Caveats](#caveats-and-limitations).
- **Tested** — in a temporary home, never the real `~/.claude` or Claude's folders. The tests snapshot the whole tree — each entry's type, mode, owner, inode, link count, size, modification time, SHA-256 and link target — and compare: a successful copy adds exactly `<Y>.jsonl`, the referenced `<Y>/subagents/agent-<id>.jsonl`, `local_<Y>.json` and one committed journal, and leaves every other entry identical, the original's files and the whole source store included; every refusal leaves Claude's folders as they were, unless a staged piece can no longer be proven the copy's own — then the staging and the journal stay and recovery reports it; a link at any component, or a folder swapped for one after the checks, receives nothing; something planted at any final or staging name is never replaced; a crash at each step before the point of no return is undone exactly by recovery — except one that lands between creating a staging object and recording it in the journal, where recovery removes nothing and says so ([Caveats](#caveats-and-limitations)) — and a crash after it is finished to the same tree as a success; no recovery branch removes anything but the copy's own staging names and journal; the flushes come in the order a power cut needs. The guards were also mutation-checked: in one round 69 of them were each removed in turn, in a scratch copy, and each removal made its test fail. The final gate then found three guards with no failing test — recovery's "folder cannot be held" arm, the check that a subagent transcript is still the file found, and recovery's flush failure before the record's rename — and tests were added for them; in that gate's round those three and 13 more (the descriptor check on a path spelled outside home, the first journal's name flushed past the drive's cache, and the other fixes it made) were each removed in turn and each removal made its test fail. That covers those 85, not every line; one arm known to have no failing test is the lock file whose `flock` fails with something other than "held by another process", which cannot be brought about on a local disk. The order of the flushes is tested; that the data survives a power cut is not, and a target store on another volume was only stood in for.
- **Not verified against a live Claude.** No copy has yet been made with a real Claude or a real `~/.claude`. Three things can only be settled that way: that the copy appears in the other account after a restart; that its first turn works under another account — the conversation may carry thinking signed for the original's organisation, and Claude Code's handling of that (a warning, or stripping thinking the API rejects and retrying) was read, not seen; and which permission mode it starts in — the record says Default, but Claude Code keeps the original's mode in the transcript, and Desktop adopts whatever mode Claude Code reports. It is also inferred, not traced, that Claude keeps `<Y>` as the copy's transcript id once it has run. The check below settles all four.

#### The first live copy

This is the check the feature is waiting for: until it has been run, no copy has been made with a real Claude. Each step says what to expect and what each outcome means.

Use a throwaway session in the default account, in a throwaway folder: two or three turns, one file edit, one subagent call if convenient, Remote Control never switched on, then left idle. Note the size and modification time of its transcript — the newest `.jsonl` in `~/.claude/projects/<slug of that folder>/`.

1. **Copy it to the other account.** Expect the *Copied to …* alert, the *not opened yet* line in the other account's **Sessions**, and the original's transcript with its size and modification time unchanged.
   - The original's transcript changed, or anything new appeared in the default account's store (`~/Library/Application Support/Claude/claude-code-sessions/…`): stop — the copy is not safe as built.
2. **Quit the other account's Claude yourself** once it is idle, and open it again from the switcher.
   - The copy is listed as *“title (copy)”*: the record and the folder rule are right.
   - It is not: find the newest `Loaded N persisted sessions from …` line for that profile in `~/Library/Logs/Claude/main.log` and compare its folder with the one the switcher used (**Diagnostics…**, that account's `code sessions:` line). A different folder means the target rule is wrong; the same folder means Claude rejected the record. Either way, stop.
3. **Open the copy**, check that the history shows, and send *reply with OK*.
   - A normal reply: the first turn across accounts works.
   - An API error about thinking or signatures: sessions with thinking cannot be copied as they are, and the feature needs another design step before it is used.
   - *model not found*: expected when the other plan lacks the model; pick one with `/model` and go on.
   - The session refuses to start with a worktree message: the worktree refusal is missing a case — stop.
4. **After the reply, look at two fields of `local_<Y>.json`, and at both transcripts.**
   - `cliSessionId` is `<Y>`, or a fresh id: right. If it is `<X>`, stop — deleting the copy could then remove the original.
   - `permissionMode` is `default`: the confirmation could promise Default outright. Anything else: it keeps saying Claude Code may restore the original's mode.
   - `<Y>.jsonl` grew and `<X>.jsonl` did not: one writer each. If `<X>.jsonl` grew, stop.
5. **Delete the copy** in the other account's Claude.
   - `<Y>.jsonl` and `<Y>/` gone, the original's transcript and record intact, and the original still answers in the default account: deletion is isolated.
   - Anything of the original's missing: stop.
   - `<Y>.jsonl` left behind beside a `<Y>.desktop-released.json`: Claude declined to remove it. Harmless — Claude Code's own cleanup removes it after 30 days ([Caveats](#caveats-and-limitations)).

### 2.14 Claude Switcher updating itself

Claude Switcher replaces itself with newer releases of itself from `github.com/kevinchau/claude-switcher`. Nothing in this section quits, starts, signals or changes Claude. It describes the code; it has not run live — the end of the section says what is verified and how.

**Which copy may replace itself.** The running copy is read once, at launch, and kept for the life of the process: its own signature (`SecCodeCopySelf` — team, identifier, flags, and the `CFBundleShortVersionString` sealed in it), its bundle path, the real path of its executable, and whether its volume, bundle and folder are writable. After a swap `Bundle.main` names the new bundle, while the signature read at launch still describes the code that is running. All of these must hold; the first that does not is the reason the greyed-out toggle and Diagnostics give:

| Must hold | Otherwise |
| --- | --- |
| A Developer ID team in its own signature, not ad-hoc, hardened runtime | `development build (…)` |
| The signature's identifier is the bundle's `CFBundleIdentifier`, and its own version can be read | `signature identifier does not match the bundle`, `cannot read this copy's own version` |
| An `.app` bundle, not translocated, not on a read-only volume | `not running from an app bundle`, `running translocated (…)`, `running from a read-only volume (the disk image?)` |
| In `/Applications` or `~/Applications`, compared with links resolved | `not installed in /Applications or ~/Applications (<its folder>)` |
| The bundle and its folder writable by you | `this copy cannot be replaced by you (owned by another user?)` |
| Not moved since it started: `proc_pidpath` still names the executable read at launch | `moved since it was started` |
| Notarized | `this copy is not notarized — a build from source`, `notarization not confirmed yet (…)` |

Notarization is asked in-process, at the first check — `SecStaticCodeCheckValidityWithErrors` on its own code, against its own team and identifier and `notarized`; `spctl` is never run on the running copy. A yes or a no is kept for the life of the process; anything else is asked again at the next check. The location rule exists because `build/Claude Switcher.app` is signature-identical to the installed copy; the notarization rule, because `make install` signs with a Developer ID but does not notarize.

A copy that fails one of these makes no automatic request — except that notarization is only known after the first check, so a copy that fails only that makes its first check, and one whose notarization could not be confirmed yet goes on checking (but downloads nothing) until it is. When you ask, it still checks: with a trust anchor (its own team, identifier and version) it downloads and verifies the release exactly as below, then removes what it staged and offers the download page; without one (a `swift run` build) it can only say that a newer tag exists.

**The feed.** One request, `GET https://api.github.com/repos/kevinchau/claude-switcher/releases/latest`, with `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2026-03-10` and `User-Agent: ClaudeSwitcher/<its sealed version> (macOS)` — no `Authorization`, token or cookie; there is no field for one. An ephemeral `URLSession` with no URL cache and no cookie or credential storage, 30 s per request and 60 s in all; no conditional request (GitHub counts an unauthenticated 304 against the limit anyway); a redirect is refused and reported, never followed. Automatic checks run only in the copy holding the automation lock, and only while `config.json` reads; a check you ask for runs in any copy. What an answer means, and when the next automatic check is due:

| Answer | Reported as | Next check |
| --- | --- | --- |
| 200 that reads as a release | `up to date`, or the release | 6 h |
| 200 that does not | `GitHub's feed changed: <why>` | 6 h |
| 3xx | `feed moved: <host and path>` | 6 h |
| 404 | `no release published (404)` | 6 h |
| 403 or 429 | `GitHub rate limit; next check after <time>` | the latest of `retry-after`, `x-ratelimit-reset` and 1 h, never more than 24 h ahead; `retry-after` counts only as whole seconds up to a day, or a date up to a day ahead |
| 410 | `this version of Claude Switcher can no longer read GitHub's feed — download by hand` | 24 h |
| anything else | `GitHub answered <code>` | 1 h |
| no answer | `could not reach api.github.com: <why>` | 1 h |

**What is read, and what is not.** From an answer of at most 1 MB: `tag_name`, `draft`, `prerelease`, `immutable`, and of the assets `name`, `state`, `size` and `digest`; a field of another type counts as missing. In this order: `draft` and `prerelease` both present and `false`; a tag of exactly `v<major>.<minor>.<patch>`, ASCII digits, no leading zeros; exactly one asset named `Claude.Switcher.dmg` (GitHub's name for the uploaded `Claude Switcher.dmg`); its `state` is `uploaded`; its size is above 0 and at most 50,000,000 bytes; its `digest` is `sha256:` and 64 lowercase hex digits — a missing digest refuses the release, it never reads as "no hash". `immutable` is shown in Diagnostics and decides nothing. Everything else is ignored, the release notes and the asset's own `browser_download_url` included: the download address is built from the checked tag, `https://github.com/kevinchau/claude-switcher/releases/download/<tag>/Claude.Switcher.dmg`.

**The download.** Only when the tag is strictly newer than the running copy's sealed version, and only with ten times the file's size plus 50 MB free both where `updates/` is and where the app is (otherwise it waits, and that is not an attempt). The same session settings, 600 s in all. It must start at `github.com`; each redirect must be https, with no port or user name, and only `github.com` may redirect — to `release-assets.githubusercontent.com`, to `objects.githubusercontent.com`, or, as the first hop only, to `github.com`; three hops at most. Anything else is cancelled and refuses the release (`the download was sent to an unexpected host (<host>)`). The transfer is cancelled the moment it passes the size the feed gave, a `Content-Length` must equal that size, and the bytes land in `downloads/<tag>/Claude.Switcher.dmg.partial`, renamed to `Claude.Switcher.dmg` only once their count and streamed SHA-256 match the feed's. A disk image already there for that tag is hashed again rather than fetched again.

**The checks, in order.** Every signature check is Apple's `SecStaticCodeCheckValidityWithErrors` with every architecture, nested code, strict validation (nothing unsealed at the bundle's root), symlinks and sideband data restricted, and network access left on — never a flag that skips resources or the executable. The requirements are built from the running copy's own team and identifier, each validated and quoted, never from a literal: the *app* requirement is Developer ID (Apple's anchor, the Developer ID intermediate and leaf) and that team and that identifier and `notarized`; the *image* requirement is the same without the identifier.

1. The file's byte count, then its SHA-256, equal the feed's.
2. The disk image's own signature is valid, and it meets the *image* requirement: this team's, notarized.
3. It carries no license agreement (`hdiutil imageinfo -plist`).
4. It is attached read-only and out of sight — `hdiutil attach -plist -nobrowse -readonly -noautoopen -mountrandom updates/mounts` — within 60 s.
5. It holds `Claude Switcher.app`, a folder and not a link, and nothing else but the `Applications` link to `/Applications` that `scripts/dmg.sh` puts there, which is read, never followed.
6. The app on it: a valid signature; the *app* requirement; and, read from that signature, the running copy's team and identifier, hardened runtime, not ad-hoc, and a sealed version equal to the tag's and strictly newer than the running one.
7. It is copied into the staging folder (below), and the image is detached at once. A busy detach is tried five more times, 200 ms apart, then forced; the only images ever detached are those whose file is under `updates/downloads/`.
8. Quarantine is cleared, now that the app has been verified: `com.apple.quarantine` is removed from the copy and everything in it, depth first, never following a link, wherever it is set.
9. Step 6 again, on the staged copy: a signature check holds only for code that is not changing, so the copy that will be installed is the one checked.
10. Gatekeeper: `spctl --assess --type execute --raw` on the staged copy must exit 0 with a verdict of true. A no (exit 1 or 3) refuses the release; no answer within 60 s tries again later. Then `gktool scan`, where macOS has it, which can refuse nothing.
11. The staged copy is a folder on the same volume as the app it is to replace.

A refusal about the release itself — digest, signature, identity, version, host, layout, license, Gatekeeper's no — rejects that tag and digest: its disk image is deleted, its emptied `downloads/<tag>/` folder is removed, and it is not tried again automatically. **Check for Claude Switcher Updates…** tries it once more; a new tag or digest is a new release; after three rejections in a row, automatic downloads pause until you check by hand. A refusal about the moment — the network, a timeout, a busy image, disk space, the copy — only puts the next attempt off. A staged copy that is refused is removed by the process that staged it, before any swap.

**Staging.** The copy lives in a folder macOS makes for replacing that very item, on its volume — `FileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor:create:)`, which for `/Applications` is `/var/folders/…/TemporaryItems/NSIRD_<…>`. The process that made and verified it keeps it, in memory, until nothing is going on. A later process never takes a path from a file to be its own: it prepares again, from the kept disk image. Quitting removes the staged copy, not the image.

**The swap.** It may go ahead when a verified release newer than the running one is kept, this copy may replace itself and holds the lock, and — unless you asked — the setting is on, `config.json` reads and nothing is going on. Then, in one turn of the main thread, it takes the launch flag, greys out Quit, the settings and session copies, and shows `Updating Claude Switcher to 0.8.0 — it relaunches in a moment…`; the rest runs off the main thread:

1. The target is proven to be this copy, as it is now: the running copy's own bundle path, a folder and not a link; its `CFBundleIdentifier`, read from disk, the running copy's; the process's executable still where it was at launch; not the configured `Claude.app`, nothing inside it and nothing containing it — compared as written and with links resolved, ignoring case; writable, and its folder too; on the same volume as the staged copy.
2. The version on disk is still the running one, and the release is newer.
3. The staged copy is checked again — step 6, in-process, a matter of milliseconds.
4. Back on the main thread: nothing has started meanwhile (not asked when you chose **Update & Relaunch**).
5. `handoff.json` is written, phase `swapping`.
6. **One `renamex_np(staged, installed, RENAME_SWAP)`.** The two folders trade places in one step, and both names exist throughout: the new version is in place, the old one where the staged copy was. An error here has moved nothing (`cannot replace this copy`, `staging on another volume`, `the volume cannot swap folders`).
7. What is now in place is checked: a folder, its `Info.plist` version the release's, a valid signature meeting the *app* requirement at that version. If not, the two are swapped back — the only swap back there is — and the record says `rolledBack`.
8. The new bundle is registered with Launch Services (`LSRegisterURL`); the record says `swapped`.
9. The relaunch, below.
10. The old copy is moved to `updates/previous/<old version>/Claude Switcher.app`; if it cannot be (`~/.config` on another volume), to the Trash; if not even that, it stays where it is and the record names it. One previous version is kept; an older one goes to the Trash.
11. The record says `launched`, with the new copy's pid, and this process quits.

The old process can keep running after step 6 because it loads nothing lazily from its bundle, which by then holds the new version — the menu bar icon is an SF Symbol, and a test fails if a lazy load is added. Every move is made by the app itself, in-process — Apple documents App Management (macOS 13 and later) as letting an app modify the bundle of an app from its own team — and there is no helper, no shell and no script. `FileManager.replaceItemAt`, which deletes the item it replaces, is not used.

**The relaunch, and never two icons.** The new copy is started by path — `NSWorkspace.openApplication` with `createsNewApplicationInstance`, not brought to the front, with `--after-update <old pid>` — while the old process still holds the automation lock, `~/.config/claude-switcher/automation.lock`, a `flock` the kernel lets go of only when that process exits. The new copy counts its start, then takes the lock — retrying every 250 ms for up to a minute, because it was started with `--after-update` — and only then puts up its icon. One that still cannot get it records `a relaunch at <time> found pid <old> still running and exited` in `state.json`, takes its start back, and exits without ever having shown an icon. The relaunch waits while the menu or a window is open, five minutes at most.

**Restart pending.** If the launch fails, or macOS does not answer within 60 seconds, nothing is swapped back and nothing is deleted: the new version stays in place, the old process keeps running (its bundle now in `updates/previous/`), the record says `restartPending`, and the menu says `Claude Switcher 0.8.0 is in place — it starts the next time Claude Switcher is launched`. That process checks for nothing more; the next launch starts the new version.

**When the new version does not start.** Every start writes `starting.json` first: this Mac, this version, and how many starts of it never got going — the marker is deleted once the icon has been up for a minute. **Quit Claude Switcher** within that minute takes the start back, and so does an after-update copy that exits for the lock; any other end — a crash, a force quit, a logout — counts. At launch, the copy holding the lock that finds two such starts of the running version, and this Mac's `handoff.json` of the update that installed it, goes back: it verifies `updates/previous/<old version>/Claude Switcher.app` (step 6, at that version), proves the target as in step 1 of the swap, writes a `revert` record, swaps the previous copy in, checks it in place (swapping back if that fails), moves the version that did not start to the Trash, rejects that release (`did not start properly twice`), and starts the previous version the same way. `handoff.json` is deleted, by the copy holding the lock, once a start of the new version has lasted a minute — so a version that has run once is never sent back. With no previous copy there, there is nothing to go back to, and Diagnostics says so.

**At every launch**, the copy holding the lock (any other copy only reports) finishes what the last process recorded — a success becomes the one-line notice and Diagnostics' `last update`, and its disk image is deleted; a failure is named in Diagnostics and its record kept as `handoff.failed.json`, and a release that did not take over is rejected — then detaches any disk image of ours still attached, deletes partial downloads and those of releases that are no longer the latest, deals with a staging folder a crash left (only by the rule below), keeps only the newest `previous/` version, and removes the temporary file of a write a crash interrupted. Every record carries this Mac's hardware UUID (`gethostuuid`); one written on another Mac — a synced `~/.config` — is ignored, left where it is, and named in Diagnostics.

**Files.** Under `~/.config/claude-switcher/updates/`, whose folders are created `0700`:

| File | What it is | Goes away |
| --- | --- | --- |
| `state.json` | the schedule; the last check and its answer; the latest release; rejections and back-off; the last update and the last failure; the staging folders to look after (one per running copy — each copy adds and removes only its own) and a disk image that may still be mounted; the one-line notice; what a relaunch found | never; rewritten |
| `handoff.json` | what the process replacing itself leaves for the one it starts, written before the swap and at each phase | deleted a minute after the new copy's icon is up; after a failure, renamed `handoff.failed.json` (one kept) |
| `starting.json` | this Mac's count of starts of this version that never got going | deleted a minute after the icon is up |
| `prepare.lock` | an exclusive `flock`, so that two running copies (say the installed one and one from `build/`) never detach or delete what the other is checking | never |
| `.state.json.<uuid>.tmp`, and the same for `handoff` and `starting` | a record being written | renamed into place; one a crash left is unlinked at the next launch |
| `downloads/<tag>/Claude.Switcher.dmg`, `.partial` while it downloads | the release's disk image | after a successful hand-off; when its release is refused for what it is; at launch, when its tag is no longer the latest; the `.partial` on any failure |
| `mounts/` | the parent of the image's random mount point while it is attached | the mount point goes with the detach |
| `previous/<version>/Claude Switcher.app` | the copy that was replaced, one version | moved to the Trash when a newer one replaces it; never deleted |

A record is written as a new file (`O_EXCL`, no link followed, mode `0600`), flushed past the drive's cache (`F_FULLFSYNC`), and renamed into place, so a crash leaves the old record or the new one, never part of either. Outside `updates/` the updater touches the staging folder; `/Applications/Claude Switcher.app` itself (or the one in `~/Applications`) and its Launch Services registration; `automation.lock`, which it only takes; and the Trash.

**What may be deleted.** The updater has one recursive removal, and it accepts a path only when, with links resolved, it lies under `updates/downloads/` or `updates/mounts/` — the config folder resolved, `updates` and those two folders not, so that if any of them is a link nothing under it is the updater's — or when it is the staged copy this very process made and has not swapped, recorded in memory as it copied it. No path read from `state.json` or `handoff.json` is ever handed to it. A copy of the app that was ever in place is never deleted: it is moved, to `updates/previous/` or the Trash. A staging folder named in `state.json` is touched only if its name is `NSIRD_…`, its parent is `TemporaryItems` in this user's temporary folder (resolved), it is a folder and not a link, and it holds exactly one item, `Claude Switcher.app`, whose `CFBundleIdentifier` is the running copy's. That app is then moved — to `previous/` if it is older than the running version, otherwise to the Trash, since it was never installed — and the emptied folder removed with `rmdir`, which removes only an empty folder.

**When it runs.**

- A first look three minutes after launch, then one every 30 minutes, and one 30 seconds after the Mac wakes; a check runs when one is due.
- Due when the table above says. Nothing is ever scheduled more than 24 hours ahead, and a date found further ahead — or a last check in the future, after a wrong clock or a hand edit — makes a check due now.
- A release refused for the moment is tried again after 1 h, then 2, 4, 8 and 16 h, then every 24 h; the count starts again at 1 h once an attempt gets further than the one before. Too little free space, or a network failure before the first byte, counts as no attempt.
- Downloading and checking need no quiet: they write only under `updates/` and into the staging folder, in the background, after a check has found a newer release.
- The swap waits for nothing to be going on ([Updating Claude Switcher](#updating-claude-switcher) says what that means) and is looked at again whenever something that could hold it ends, with one more look 91 seconds later.
- With **Keep Claude Switcher Up to Date** off, none of this: a check only when you ask, and a release verified then is installed only when you choose **Update & Relaunch**.

At one check every six hours a Mac makes about four requests a day; GitHub allows 60 an hour per address without a token.

**What it can start and end.** The only application the updater can start is a new copy of Claude Switcher, by path; the only process it can end is its own (`NSApp.terminate`). Every effect it has is handed to it in an environment, and none of those has a field that could start, quit, signal or script Claude; tests read the environments and the updater's source to keep it so — no `kill`, `NSRunningApplication`, `forceTerminate`, AppleScript, Apple event, `/usr/bin/open`, shell or `posix_spawn`. Beyond that it runs three of Apple's tools — `/usr/bin/hdiutil`, `/usr/sbin/spctl` and `/usr/bin/gktool` — each by absolute path, with an empty environment, input from `/dev/null`, and a deadline on a clock that stops while the Mac sleeps; one that overruns its deadline is left to finish, never killed. The real swap-and-relaunch environment is in the app target, which no test can import.

**The network.** Its own requests go only to GitHub: the feed at `api.github.com`, and the release's disk image from `github.com` and the asset host it redirects to. No token, cookie or account data is sent, and nothing at all while the setting is off and you do not ask. The signature checks it asks macOS for leave network access on, so that revocation and notarization are really checked; macOS may consult Apple to answer them, as it does for any app Gatekeeper looks at.

**What is verified, and what is not.**

- **Tested** — 284 of the 947 tests, none of which touches the installed app, the real `~/.config`, the network or Claude. The feed: every refusal, every status, the 24-hour bounds against forged headers, the redirect rule, the request's headers; the real feed and download code driven through a stand-in network layer (redirects followed or refused, too many bytes, a wrong length, error statuses, a failure before the first byte). Prepare: every step in order, each refusal and what it leaves behind, the prepare lock, an attach that times out. The swap and going back: every precondition and step against fakes — the target proofs, swap errors, the single swap back, restart pending, the old copy to `previous/`, to the Trash or left and named, the five-minute wait for the menu, and that nothing is removed but the process's own unswapped staged copy. Launch: every hand-off outcome; the crash-loop guard (two aborted starts go back once, a version that has started once never does, another Mac's records count for nothing); the staging-folder rule clause by clause; the removal rule against links in a real temporary tree; one previous version kept. The records: written whole, a crash's leftovers swept, starts counted and taken back, and the new copy's wait for the lock and its exit without an icon. The source: no seam can reach Claude or end another process, the real swap environment is out of the tests' reach, nothing is loaded lazily from the bundle, and every process the real prepare would start is one of the three tools with an empty environment.
- **Tested with the real release, when `build/` has it.** Ten tests use real code signatures, offline. Eight of them skip unless `build/` has what they need — six the notarized `build/Claude Switcher.app` (0.7.0), two the published v0.7.0 disk image at `build/Claude Switcher.dmg` (or wherever `CLAUDE_SWITCHER_TEST_DMG` points), recognised by its size and SHA-256: the built app is this team's notarized app; another team or identifier fails with the requirement error; a file added at the bundle's root fails the strict check; an edited `Info.plist` fails; the release image meets the *image* requirement and a copy with one flipped byte does not; a requirement that does not compile fails closed; and one prepare runs end to end with the real `hdiutil` — attached read-only, copied into a real `NSIRD` folder, quarantine cleared, verified again, detached — leaving nothing mounted, and is then discarded. That run takes the disk image from a local copy instead of GitHub, and stands in for Gatekeeper's assessment, since `spctl` may ask Apple. In the run made for this README all 947 tests passed and none was skipped.
- **Mutation-checked.** In three rounds the updater's guards were weakened one at a time in scratch copies — 168, 33 and 59 of them, beside control edits — and every weakening made its test fail, except `O_NOFOLLOW` on a record's exclusive create, which `O_EXCL` already makes redundant. The 33 are the app shell's, checked by a test package kept outside this repository. That covers those guards, not every line: nothing fails without the flush past the drive's cache (that takes a power cut) or without deadlines that stop while the Mac sleeps (that takes a sleeping Mac), and the flags of a signature check are tested up to the one line that hands them to Apple's call, not past it.
- **Read in Apple's and GitHub's documentation**, not exercised by the code: `releases/latest` returns the most recent release that is neither a draft nor a pre-release; without a token the limit is 60 requests an hour per address, answered with 403 or 429 and `retry-after` or `x-ratelimit-reset`; `release-assets.githubusercontent.com` is GitHub's host for release downloads; release assets carry a SHA-256 `digest`; an API version is eventually retired with 410 (the request pins `2026-03-10`); `createsNewApplicationInstance` always starts a new instance; from macOS 13 an app may modify the bundle of an app from its own team; `kSecCSNoNetworkAccess` turns off online revocation and notarization checks; a static signature check holds only while the code is not modified; `LSRegisterURL` updates a registration; `spctl`'s exit codes.
- **Checked by hand while it was designed**, on this Mac, with `curl`, throwaway images and probe apps — never with Claude Switcher updating itself: the download takes two hops, `github.com` then `release-assets.githubusercontent.com`, and the bytes' SHA-256 equals GitHub's digest for v0.7.0; the API's answers are cacheable for 60 s, and an unauthenticated 304 still counts against the limit (hence no cache and no conditional request); a valid signature alone does not say who signed — an ad-hoc re-signed copy passes — strict validation is what catches a file added at the root, and `notarized` in a requirement is the public way to ask for notarization; files copied out of a quarantined disk image are quarantined, and their owner can clear it; `RENAME_SWAP` on APFS left the target present at every one of about 35,000 checks during swaps; the staging folder for `/Applications` is on its volume; a process whose bundle is swapped keeps running, but loads lazy resources from the new bundle; the release disk image is itself signed, notarized and stapled.
- **Not verified against a live run.** No copy of Claude Switcher has updated itself yet. The swap in `/Applications`, the relaunch, the lock hand-off and the move to `previous/` have run only against fakes; the code has never fetched the real feed or a real release, nor run `spctl` or `gktool`; and the app's own wiring — the launch order, the idle state built from its real flags, when a swap is looked at, Quit during one, the alert buttons — is checked by a warning-free build, by review and by tests that read the source. Not known until then: whether macOS answers `openApplication` for a second instance of the same app while the first still runs, in time (if not, the first run shows restart pending rather than a clean relaunch); whether Launch at Login survives the replacement (inferred from how macOS keys its login-item records, not observed); whether App Management lets the in-process swap through, as documented; and the running copy's in-process notarization check, which was checked offline for stapled copies with a test tool, never in the app. The first live self-update is the maintainer's, and it is the check below.

#### The first live self-update

This is the check the updater is waiting for. It needs **two** releases: the first release with the updater reaches nobody on its own — every copy before it has no updater — so it is installed by hand, and only the release after it can arrive by itself. Each step says what to expect and what each outcome means; the version numbers are examples.

1. **Publish 0.8.0, the first release with the updater** ([Releases the updater accepts](#releases-the-updater-accepts)): tag `v0.8.0` equal to the app's `CFBundleShortVersionString`, the app and the disk image both notarized and stapled, published (not a draft or pre-release) and marked Latest. Install it by hand from its disk image into `/Applications` and open it from there — not from `build/`, which only ever checks. Note whether Launch at Login is on, and the pid **Diagnostics…** shows for each running account.
2. **Publish 0.8.1** — any trivial change, under the same rules.
3. **On the Mac running 0.8.0, choose Check for Claude Switcher Updates….** Expect `Checking for Claude Switcher updates…`, then `Downloading Claude Switcher 0.8.1…`, then the alert **Claude Switcher 0.8.1 is available**.
   - **Claude Switcher 0.8.1 could not be verified**, with a reason: the release does not pass the checks — team, identifier, notarization, the tag against the version, the digest, the image's layout. Nothing changed on disk. Fix the release before anything else; the next check by hand tries it again.
   - **Claude Switcher is up to date**: GitHub's Latest is not 0.8.1. Is it published, not a pre-release, and marked Latest?
   - **Could not check for Claude Switcher updates**: the reason is the feed's answer.
4. **Click Update & Relaunch.** Expect the icon to disappear for a second or two and come back once, and the next menu open to show `Claude Switcher updated itself to 0.8.1 at <time>.`
   - **Claude Switcher did not update**, with a reason: refused before the swap, or swapped back right after it — permissions, a translocated or moved copy, the path. 0.8.0 is in place and running, unchanged.
   - **Claude Switcher 0.8.1 is installed** — *It could not be relaunched*: restart pending. Quit Claude Switcher, open it again by hand, and confirm 0.8.1 runs. The relaunch needs another look.
   - **The icon vanishes and does not come back**: the new copy crashed or could not take the lock. Open `/Applications/Claude Switcher.app` by hand and read **Diagnostics…** — its `relaunch:` line says whether a relaunch found the old pid still running. If it fails to start twice, the start after that must go back to 0.8.0 by itself and say `Claude Switcher 0.8.1 did not start properly twice; it went back to 0.8.0.` If it does not, the crash-loop guard is broken; the previous copy is in `~/.config/claude-switcher/updates/previous/0.8.0/Claude Switcher.app`, to put back by hand.
   - **Two icons**: the lock hand-off is broken — the new copy should have waited, or exited. Quit the newer one from its own menu, and report it.
5. **A minute later, look.** **Diagnostics…**: `version: 0.8.1`; `last update: 0.8.0 → 0.8.1 at …; previous copy: …/updates/previous/0.8.0/Claude Switcher.app`; `launch at login: enabled` if it was on — `needs to be turned on again` means the inference under [Caveats](#caveats-and-limitations) was wrong. In `~/.config/claude-switcher/updates/`: no `handoff.json`, no `starting.json`, no `downloads/v0.8.1`. `plutil -extract CFBundleShortVersionString raw "/Applications/Claude Switcher.app/Contents/Info.plist"` prints `0.8.1`, and `codesign -dvv "/Applications/Claude Switcher.app"` shows the same `TeamIdentifier` as before. Every account has the pid it had in step 1: Claude was not touched.
6. **Before announcing it, publish 0.8.2** and leave the Mac idle, the menu closed. Within about six and a half hours of its last check it should update itself, with no alert, and Diagnostics' `last update` should read `0.8.1 → 0.8.2`.

---

## Signing and distribution

`make bundle` resolves a signing identity in this order: `$CODESIGN_IDENTITY` if set, otherwise the first **Developer ID Application** identity in the keychain, otherwise **ad-hoc** (`codesign --sign -`).

**An ad-hoc build runs only on the machine that built it.** On any other Mac, Gatekeeper rejects it — "unidentified developer" / "damaged". This is not theoretical: `spctl -a -t exec` reports `rejected` for an ad-hoc bundle, and `source=Unnotarized Developer ID` for one that is signed but not yet notarized. Only a notarized, stapled build reports:

```
Claude Switcher.app: accepted
source=Notarized Developer ID
origin=Developer ID Application: …
```

To ship a build to other people you need an Apple Developer Program membership and a Developer ID Application certificate, then:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make bundle
make notarize
```

`make notarize` (`scripts/notarize.sh`) needs notarytool credentials. Store a profile once:

```sh
xcrun notarytool store-credentials claude-switcher \
    --apple-id you@example.com --team-id TEAMID \
    --password <app-specific-password>
```

and run with `NOTARY_PROFILE=claude-switcher` (the default), or pass `APPLE_ID` / `TEAM_ID` / `APP_PASSWORD` in the environment.

Preferred, and how the releases here are built — an **App Store Connect API key**, which needs no app-specific password, so no secret is typed or pasted anywhere:

```bash
ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8 \
ASC_KEY_ID=XXXXXXXXXX \
ASC_ISSUER_ID=<issuer-uuid> \
make notarize
```

The script zips the app with `ditto --keepParent`, submits it and waits, staples the ticket, validates it, re-zips the stapled app, and prints a final Gatekeeper assessment. It refuses up front if the bundle is ad-hoc signed, rather than failing after a slow upload — Apple will not notarize an ad-hoc signature.

`make dist` produces `build/Claude Switcher.zip`, and warns on stdout if what it just zipped is ad-hoc signed.

The hardened runtime (`--options runtime`) and a secure timestamp (`--timestamp`) are applied **only** for real identities, because notarization requires both and an ad-hoc signature supports neither.

> Releases are signed with a Developer ID Application certificate, notarized by Apple, and stapled — a downloaded copy opens with no Gatekeeper prompt, verified offline against the stapled ticket. A build you make yourself without a certificate is ad-hoc signed and will only run on the machine that built it.

### Automated releases

`.github/workflows/release.yml` builds, signs, notarizes, staples and publishes a release when you push a version tag (`v0.1.0`). It is gated on the signing secrets being present, so it no-ops safely until they are configured:

| Secret | What it is |
| --- | --- |
| `MACOS_CERT_P12` | base64 of your exported **Developer ID Application** `.p12` (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERT_PASSWORD` | the password set when exporting the `.p12` |
| `APPLE_ID` | Apple ID email |
| `APPLE_TEAM_ID` | 10-character team id |
| `APPLE_APP_PASSWORD` | app-specific password from [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security |

The certificate is imported into a throwaway keychain that dies with the runner, and the `.p12` is deleted immediately after import.

**Getting the certificate.** An Apple Developer Program membership does *not* give you one automatically, and an iOS project cannot supply it — iOS apps sign with `Apple Development` / `Apple Distribution`, which are a different certificate type. Create it once in Xcode → **Settings → Accounts → (your team) → Manage Certificates → + → Developer ID Application**, then export it from Keychain Access as a `.p12`.

### Releases the updater accepts

An installed copy takes a release only if it passes every check in [§2.14](#214-claude-switcher-updating-itself). For whoever publishes one, that means:

- It is published — not a draft, not a pre-release — and it is GitHub's **Latest** release. Every installed copy that updates itself finds it at its next check, every six hours.
- Its tag is `v<major>.<minor>.<patch>` and equals the app's `CFBundleShortVersionString`, and that version is higher than the one it is to replace. `release.yml` builds with `VERSION="${GITHUB_REF_NAME#v}"`; a local build must set `VERSION`, whose default in `scripts/bundle.sh` is `0.7.0`.
- It has exactly one asset named `Claude Switcher.dmg` (GitHub stores it as `Claude.Switcher.dmg`), of at most 50 MB, with the SHA-256 digest GitHub computes on upload.
- The disk image is signed by the same team and notarized, and holds the app and the `Applications` link and nothing else — what `scripts/dmg.sh` makes.
- The app is signed by the same team with the same identifier (`tech.local.claude-switcher`), with the hardened runtime, notarized, and accepted by Gatekeeper.

`make release-artifacts` and `release.yml` both notarize and staple the app, build the disk image, then notarize and staple that too. Whether a release made this way really passes is the first thing [the first live self-update](#the-first-live-self-update) checks. GitHub's *immutable releases* setting is shown in Diagnostics (`release flags`) and decides nothing.

---

## Build and develop

```sh
make            # same as `make build` — it is the default goal
make build      # swift build -c release
make test       # swift test
make icon       # regenerate assets/AppIcon.icns from assets/AppIcon.png (the .icns is committed)
make bundle     # build, then scripts/bundle.sh: assemble + sign build/Claude Switcher.app
make install    # bundle, then replace /Applications/Claude Switcher.app with it
make notarize   # scripts/notarize.sh: submit, staple, re-zip (Developer ID required)
make dmg        # bundle, then scripts/dmg.sh: build/Claude Switcher.dmg, signed like the app
make notarize-dmg       # notarize and staple the disk image
make release-artifacts  # bundle, notarize the app, build the disk image, notarize it: a release's asset
make dist       # bundle, then zip it to build/Claude Switcher.zip
make clean      # rm -rf .build build
make dry-run    # swift run -c release claude-switcher --dry-run
```

`make bundle` wraps the release binary in a minimal app bundle (an `Info.plist` carrying `LSUIElement`, plus the `CFBundleIdentifier` the login item is registered under — `tech.local.claude-switcher`) because `SMAppService.mainApp` needs a bundle. The script lints the generated plist, strips extended attributes, signs, and verifies the signature. Set `VERSION` to override the default `0.7.0`. No Xcode project is involved.

### Layout

A SwiftPM package (`swift-tools-version:6.0`, every target compiled with `.swiftLanguageMode(.v6)`), macOS 14+, AppKit only, **no external dependencies**. The app is an `LSUIElement` menu-bar agent with a single `NSStatusItem` and one window, the welcome window.

| Target | Path | What it is |
| --- | --- | --- |
| `ClaudeSwitcherCore` (library) | `Sources/ClaudeSwitcherCore` | Pure, testable logic: `Config`, `PathNormalizer`, `KeychainProbe`, `ProcessArgs`, `InstanceManager`, `LaunchPlanning`, `UpdateProbe`, `UpdateInstaller`, `LoginItem`, `UsageHistory` (the samples, the five-hour window, the week row's words), `UpdateReopen`, `UpdateBlock`, `AutomationLock`, `Onboarding`; and for usage and the Advisor ([§2.10](#210-where-the-usage-bars-come-from)): `WeeklySchedule` (the weekly reset: anchors, brackets, the vote), `ActivityLedger` (spend by ten minutes, limit hits, episodes), `ActivityIndex` (the transcripts read into `activity-index.json`, and whose they are), `ExactUsage` (`~/.claude.json`), `UsageTimeline` (windows, segments, weeks), `UsageForecast` (the estimates, calibration and the scale gate), `SessionCosts`, `UsageAdvisor`, `AdvisorText` (every word the menu, Diagnostics and `--dry-run` say about them) and `UsageSnapshot`, their one façade; and for sessions ([§2.13](#213-copying-a-session-to-another-account)): `SessionCatalog` (records, stores, the listing, the slug), `SessionRegistry` (`~/.claude/sessions`), `TranscriptScan`, `CopyRecord`, `HeldDirectory` (the descriptor walk), `StoreSurvey`, `CopyJournal`, `CopyRun`, `CopyRecovery`, and `SessionCopy`, their public face; and for updating itself ([§2.14](#214-claude-switcher-updating-itself)): `SwitcherRelease` (versions, the feed, the redirect rule), `SwitcherRunningCopy` (the running copy, its trust anchor, why it may not replace itself), `SwitcherSignature` (the Security framework calls), `SwitcherIdle`, `SwitcherUpdatePolicy` (the pure rules), `SwitcherUpdateState` and `SwitcherUpdateStore` (`state.json`, `handoff.json`, `starting.json`), `SwitcherRelaunch` (the lock hand-off), `SwitcherUpdateAlerts`, `SwitcherUpdater` (check, prepare, swap, go back, the launch pass) and `SwitcherUpdaterLive` (the real disk, tools and network, the removal rule, `prepare.lock`) |
| `claude-switcher` (executable) | `Sources/ClaudeSwitcher` | Thin AppKit shell: `main.swift`, `AppDelegate`, `MenuBuilder`, `SessionMenu`, `UsageMenu` (the usage under each account and **Start a session in…**, patched by identifier), `UsageBarView` (the bars and their lighter estimate), `Diagnostics`, `WelcomeWindow`, and `SwitcherUpdates` — the updater's menu text and the real swap-and-relaunch environment, kept here, out of the tests' reach |
| `ClaudeSwitcherTests` | `Tests/ClaudeSwitcherTests` | Tests, importing `ClaudeSwitcherCore` |

The split is deliberate: a test target cannot import an executable target cleanly across all toolchains, so every unit-testable type lives in the library.

### Tests

`make test` runs **947 tests**, covering config round-trip and file IO, path normalization, Keychain service-name derivation (including known-good vectors, NFC equivalence and spelling collapse), profile mutation and validation rules, `KERN_PROCARGS2` argv parsing (padding, embedded spaces, truncated and garbage buffers), instance-to-profile binding, the pid-addressed reopen event, launch planning, when the welcome window opens on its own, usage-history parsing and session-window inference (including series shaped like the real ones), the usage forecasts and the Advisor, reopening accounts after Claude's own update (the launch-only sequence, run against the same scripted fake), the update-block policy files under a temporary home (including every case where a library it did not create must be left alone), staged-update detection against fixture bundles (JSON request file, percent-encoded and symlinked paths, lingering requests, fresh version reads), and the whole quit → install → reopen sequence run against a scripted fake with virtual time — no test ever quits, signals or launches Claude, or replaces or launches Claude Switcher. (The processes tests start are `/usr/bin/true`, so that a reopen request has a pid that is certainly gone; `/bin/ps`, for a process start time; `/usr/bin/env`, `/bin/cat` and `/bin/sleep`, to check how the updater runs a tool; and, in the real-release tests, `/usr/bin/hdiutil` on a temporary copy of the release image.)

The session copy ([§2.13](#213-copying-a-session-to-another-account)) accounts for 219 of them, every one in a temporary home with a fake clock, id source, owner, process table and disk — never the real `~/.claude` or Claude's folders: reading records and stores and choosing the target's folder, the slug on ASCII, decomposed Unicode, emoji and over-long paths, the running-session registry, the transcript scan (clearing lines byte for byte, worktree and monitor state, subagent ids that could name another path), the record's exact keys and title numbering, the descriptor walk (a link at every component, other spellings of home, folders swapped after they are checked), the copy against a full-tree snapshot with every refusal, and recovery from a crash at each step — finished or undone exactly, except a crash between creating a staging object and journalling it, which recovery leaves in place and reports — with journals that name other files. Its guards were mutation-checked as §2.13 describes.

The usage Advisor ([§2.10](#210-where-the-usage-bars-come-from)) accounts for 182, every one on fixtures in a temporary home or in memory — never the real transcripts, `~/.claude.json`, Claude's folders or `~/.config`: the weekly schedule (the vote, the one-vs-two rule, re-anchoring, wide brackets, every input order), the five-hour window and its ten-minute floor, the timeline, the activity index (duplicate lines, the subagent fill-in, cache reads, attribution through records and earlier transcript ids, incremental reads, truncated and rewritten files, a corrupt index, and that no text reaches it), the `~/.claude.json` reader, calibration and the scale gate, the forecast, session costs, every rule of the Advisor, the wording, and the snapshot that ties them together; the 43 usage-history tests now run on the schedule model too. The app target's side — the menu, patching an open one, the after-time row, Diagnostics, `--dry-run` and the drawn bars — is checked by 18 more tests in a scratch package that imports the app target, kept outside this repository. §2.10 lists what is verified and what only a live run can show.

The self-updater ([§2.14](#214-claude-switcher-updating-itself)) accounts for 284: the feed and the redirect rule, the download through a stand-in network layer, every prepare step and refusal, every swap step and the way back, the launch-time pass against a real temporary tree, the records and the lock hand-off, the running of tools, tests that read the source for what must never be there, and ten real-release tests that use `build/Claude Switcher.app` and the published v0.7.0 disk image when they are there — eight of them skip without — including one end-to-end prepare with the real `hdiutil`. None reaches the network, the real `~/.config`, the installed app or Claude; the real swap-and-relaunch code lives in the app target, which tests cannot import. §2.14 lists what they cover and what only a live run can show.

### `--dry-run` and `--help`

`claude-switcher --dry-run` prints the resolved launch plan for every account and exits `0` **without creating a status item, creating any directory, or launching anything**. It does enumerate running processes, read-only, so the plan can say what is already up — see the [output above](#what-it-looks-like) — and, only when Claude has an update downloaded but not installed, adds an `Update:` line saying what is in its way. It also adds one `Claude Switcher:` line about updating itself, from `~/.config/claude-switcher/updates/state.json`, which it only reads; nothing is fetched from GitHub. To say whether this copy could replace itself it checks its own signature in-process, with network access turned off (`kSecCSNoNetworkAccess`), so that nothing goes out; a release is stapled, which lets that check pass offline. After each account's `usage:` line it prints `forecast:`, `schedule:` and `calibration:`, and after the accounts one `advice:` block ([§2.10](#210-where-the-usage-bars-come-from)), from the activity index as it is on disk: it never reads a transcript, never builds or refreshes the index, and writes nothing. It reads the samples, `~/.claude.json`, the session records (to know whose activity is whose) and, with an index to charge them against, the running-session registry. With no index — it is built when the app runs — the forecast says the estimates need it and the block reads `advice: needs the activity index (built when the app runs)`; an index more than an hour old is not estimated or advised from, and the block says how old it is. This is the fastest way to confirm what the tool *would* do before letting it do it.

`claude-switcher --help` (or `-h`) prints usage — the two modes, the config path, how accounts differ, what stays shared and what does not, what is recorded and what is estimated about usage, how it updates itself, and the internal `--after-update` flag — and exits `0`. The flag scan is a plain `contains` over the arguments, and `--help`/`-h` is checked before `--dry-run`. `--after-update <pid>` is given by Claude Switcher to the copy it starts after replacing itself ([§2.14](#214-claude-switcher-updating-itself)); it only makes that copy wait for the old one's lock, and is not for use by hand. The text, with the home directory rewritten to `/Users/me`:

```
claude-switcher — switch between Claude Desktop accounts from the menu bar.

USAGE
  claude-switcher             Run the menu bar app (no Dock icon; a welcome window the first time).
  claude-switcher --dry-run   Print the resolved launch plan for every account, with its usage
                              and the Advisor's advice, then exit. Launches nothing, creates
                              no directories, touches no state.
  claude-switcher --help      Show this message.

CONFIG
  /Users/me/.config/claude-switcher/config.json

HOW ACCOUNTS DIFFER
  Desktop app   a separate Electron user-data dir (--user-data-dir) — its own login for
                both chat and the Code tab. Instances run side by side.
  Terminal CLI  a separate CLAUDE_SECURESTORAGE_CONFIG_DIR credential slot, applied by
                you in your shell via "Copy terminal command".

WHAT STAYS SHARED
  ~/.claude — projects, session history, skills, agents, plugins, memory, settings and
  CLAUDE.md — is shared by every account. claude-switcher never sets CLAUDE_CONFIG_DIR,
  never sets CLAUDE_CODE_OAUTH_TOKEN, and never reads or writes Keychain secrets (it only
  checks whether a credential item exists). Usage shown per account is read from that
  account's own plan-usage-history.json, which Claude Desktop writes; it is never fetched.

WHAT DOES NOT
  Conversations. Chats live with each account on claude.ai, and Claude Desktop keeps the
  Code tab's session list per account inside each user-data dir. The transcripts are in
  ~/.claude, but an account's list only shows the sessions that account started.
  The menu's Sessions submenu can copy one Code session to another account: an independent
  copy, which that account's Claude lists the next time it starts.

USAGE AND THE ADVISOR
  The bars show what Claude recorded for each account. The grey line under them, the
  lighter part of a bar and "Start a session in…" are estimates: this Mac's Claude Code
  transcripts (token counts and times only) are read into one index of numbers,
  ~/.config/claude-switcher/activity-index.json, and weighed against what was recorded.
  A reset time shown without "(est.)" was recorded by Claude Code; every other one is an
  estimate. --dry-run reads that index as it is and never reads a transcript.

UPDATES
  Claude Switcher keeps itself up to date from github.com/kevinchau/claude-switcher: every
  few hours it asks GitHub for the latest release, checks that it is signed by the same
  developer team and notarized by Apple, replaces itself when nothing is going on, and
  relaunches. Only Claude Switcher — Claude is never quit, started or updated by this.
  Menu: "Keep Claude Switcher Up to Date" (the off-switch: off means no automatic network
  request at all; config key updateSwitcherAutomatically), "Check for Claude Switcher
  Updates…", and "Update Claude Switcher to X & Relaunch" once a verified release is
  waiting. A copy built from source, or not in /Applications or ~/Applications, never
  replaces itself; it checks only when asked.

INTERNAL
  --after-update <pid>        Given by Claude Switcher to the copy it starts after replacing
                              itself; not for use by hand.
```

<details>
<summary><b>Config file reference — <code>~/.config/claude-switcher/config.json</code></b></summary>

Written atomically with mode `0600` (parent directories created as needed). If the file is absent, a default config is used. The app says "account" where the file says `profiles` — only the wording on screen changed, so existing config files keep working.

Four other things live beside it: `automation.lock` ([§2.11](#211-after-an-update-claude-only-brings-back-the-default-account)); `copies/`, one journal file per session copy in flight or not yet opened ([§2.13](#213-copying-a-session-to-another-account)); `updates/`, Claude Switcher's own update records, downloads and previous copy ([§2.14](#214-claude-switcher-updating-itself)); and `activity-index.json`, the numbers the forecasts are made from ([§2.10](#210-where-the-usage-bars-come-from)) — a cache: deleting it loses nothing that cannot be read again from the transcripts. None is meant to be edited. The folder is meant for one Mac: syncing `~/.config/claude-switcher` between Macs is not supported — the updater ignores records written on another Mac, and names them in Diagnostics, but each Mac's next save of `updates/state.json` replaces the other's.

```json
{
  "claudeAppPath": "/Applications/Claude.app",
  "activeProfileId": "default",
  "profiles": [
    { "id": "default", "label": "Personal", "userDataDir": null, "credDir": null },
    {
      "id": "work",
      "label": "Work",
      "userDataDir": "/Users/me/Library/Application Support/Claude-work",
      "credDir": "/Users/me/.claude-accounts/work"
    }
  ],
  "reopenAfterUpdate": true,
  "blockClaudeUpdates": false,
  "updateSwitcherAutomatically": true
}
```

| Field | Meaning |
| --- | --- |
| `claudeAppPath` | Path to the `Claude.app` bundle. Never modified or duplicated; only read. |
| `activeProfileId` | The account last selected. Must name an existing entry in `profiles`. |
| `profiles[].id` | Unique, non-empty. |
| `profiles[].label` | Menu title. Change it with **Rename Account**; nothing else about the account changes. |
| `profiles[].userDataDir` | `null` ⇒ the app's own default profile dir; **pass no `--user-data-dir` argument**. Otherwise the Electron profile dir, created (`mkdir -p`) at launch if missing. |
| `profiles[].credDir` | `null` ⇒ the default credential slot; **omit `CLAUDE_SECURESTORAGE_CONFIG_DIR` entirely**. Otherwise the terminal CLI's credential dir. |
| `reopenAfterUpdate` | Default `true`. Reopen accounts that closed themselves for a Claude update ([§2.11](#211-after-an-update-claude-only-brings-back-the-default-account)). Launch-only. |
| `blockClaudeUpdates` | Default `false`. Keep Claude from updating itself ([§2.12](#212-blocking-claudes-auto-updates)). Editing this by hand does not write or remove the policy files; the menu item does. At startup a `true` is (re)applied, a `false` removes nothing. |
| `updateSwitcherAutomatically` | Default `true`. Claude Switcher checks GitHub for a newer release of itself and replaces itself when nothing is going on ([§2.14](#214-claude-switcher-updating-itself)). Only Claude Switcher — Claude is never quit, started or updated by it. `false`: no automatic network request at all; **Check for Claude Switcher Updates…** still works. In a copy that cannot replace itself the menu shows it off and greyed out, whatever the file says. |

An entry with `userDataDir == nil && credDir == nil` is *the default account* (`isDefaultProfile`). Note the id derived from a label is lowercased (`Work` ⇒ `work`), and so is the directory it names (`Claude-work`), which is why the example above reads `Claude-work` and not `Claude-Work`.

**Decoding tolerance:** `reopenAfterUpdate`, `blockClaudeUpdates` and `updateSwitcherAutomatically` may be absent — a file written by an older version loads with the defaults. `userDataDir` and `credDir` may be omitted entirely from a hand-edited file, and an **empty string decodes as `nil`** — so a stray `""` can never reach the launcher as a real path or be exported as a blank `CLAUDE_SECURESTORAGE_CONFIG_DIR`. Both keys are always written back as explicit `null`s so the file on disk documents both knobs.

**Validation rules.** These are enforced by pure, throwing mutators on `Config` (nothing here touches disk), *and* — for the subset that keeps accounts distinguishable — again at **load** time, because this file is advertised as hand-editable and a bad edit must not produce a config the tool cannot reason about.

Checked when adding an account (`addProfile`):

- **empty id** ⇒ `malformed("an account id must not be empty")`.
- **duplicate id** ⇒ `duplicateID`. Ids are the primary key for every lookup and mutation.
- **a second account that omits `userDataDir`** ⇒ `duplicateDefaultProfile`. Only **one** entry may omit it. An account's *Desktop identity* **is** its `userDataDir` and nothing else — that argument is the only thing that selects a different app login. Two accounts without one would therefore both bind to the same single default instance: selecting either would focus the same window while the menu reported a switch, which is exactly the mis-attribution the three-valued matching in [§2.8](#28-what-the-tool-actually-does-with-all-this) exists to prevent. (It would also strand the duplicate permanently, since `removeProfile` refuses any entry that is `isDefaultProfile`.)
- **a reserved `userDataDir`** ⇒ `reservedUserDataDir(dir, why)`. Rejected, after normalization: `$HOME`, `~/.claude`, `~/Library/Application Support/Claude`, and **any directory whose name ends in `-3p`** (case-insensitively) — Claude keeps an account's policy files in `<its directory>-3p`, and `Claude-3p` is the default account's ([§2.12](#212-blocking-claudes-auto-updates)). The reason is what `--user-data-dir` *does*: Claude.app treats that directory as its own Chromium profile and writes `Cookies`, `Local Storage/`, `IndexedDB/` and `SingletonLock` into whatever it is given. Aimed at `~/.claude`, it would scribble Chromium state through the one directory this tool exists to keep shared and intact. Aimed at the app's *own* default profile dir, it would put two concurrent Chromium processes on a single LevelDB store — which can corrupt the user's primary Desktop login.
- **duplicate `userDataDir`** ⇒ `duplicateUserDataDir`, and **duplicate `credDir`** ⇒ `duplicateCredDir`, each compared across accounts after `PathNormalizer` normalization (so `~/x` and `/Users/me/x/` collide as they should) and with `nil`/`""` folded together as "not set".

Checked when removing or switching:

- the default account cannot be removed (`cannotRemoveDefaultProfile`).
- the currently-active account cannot be removed (`cannotRemoveActiveProfile`).
- `setActive` on an unknown id throws `unknownProfile`.

Checked again at **load** time (`Config.init(from:)`), since the file is hand-editable:

- an **empty id**, or a **duplicate id**, is rejected as `malformed` — either would make `profile(id:)` ambiguous.
- **more than one entry in `profiles` omitting `userDataDir`** is rejected as `malformed`, naming the offending ids (the same rule as `duplicateDefaultProfile`, surfaced as a file-level complaint rather than that case).
- every entry's `userDataDir` is put through the same **reserved-directory** check, so `reservedUserDataDir` can surface on load too.
- directory *collisions* are deliberately **not** fatal on load: they are rejected when adding an account, but an existing odd file still loads so the user can see it in Diagnostics and fix it. A load failure is not fatal to the app either — the last good config stays in the menu and the problem is shown as a header line.

**Path normalization** — every path is normalized before it is used *or hashed*: expand a leading `~`, make absolute, collapse duplicate slashes, strip trailing slashes (but never reduce `/` to `""`), then NFC-normalize. The normalized result is both what gets passed to `Claude.app` and what feeds the Keychain service-name hash.

</details>

---

## Caveats and limitations

- **This relies on undocumented behavior.** `--user-data-dir` is an Electron flag, not a Claude Desktop feature; `CLAUDE_SECURESTORAGE_CONFIG_DIR` is an undocumented environment variable; the config-dir resolver and the Keychain service-name derivation were read out of the shipped app, and so were the Code tab's session store, the transcript format and every rule a session copy follows. Any Claude update may change or remove all of it. If it breaks, the failure mode should be "the tool stops helping", not "your data is damaged" — but treat it as unsupported.
- **Two instances share `~/.claude`.** That is the feature, and it is also the risk: concurrent writes to shared state (`history.jsonl`, `settings.json`, session files under `projects/`) are possible, and last-writer-wins. Avoid editing settings in two instances at once.
- **Chat history is per-account and cannot be shared.** It lives server-side on the Anthropic account. Cowork/remote sessions and usage limits are likewise per-account. Only the local `~/.claude` state is shared.
- **The tool never reads, writes or migrates credentials.** Each account is signed in by you, interactively, once. Keychain interaction is an existence check with `security find-generic-password -s <service> -a "$USER"` and never `-w`; any failure is indistinguishable from a genuine absence and is reported the same way (see the badge table under [Usage](#usage)). `CLAUDE_CODE_OAUTH_TOKEN` is never set by this tool.
- **The "signed in" badge in Copy terminal command is about the CLI only.** It says nothing about whether the Desktop account is logged in.
- **After an update Claude only reopens the default account.** The switcher reopens the others that closed for it ([§2.11](#211-after-an-update-claude-only-brings-back-the-default-account)), but the sessions they were running were still stopped by Claude on the way down, and it relies on an undocumented marker file — if Claude stops writing it, the reopening simply stops.
- **Blocking auto-updates means no security fixes until you unblock.** It also freezes the Code tab's CLI version, and it works through a policy file Claude documents for administrators, not end users ([§2.12](#212-blocking-claudes-auto-updates)). It was verified on a throwaway profile; your own accounts pick it up at their next start.
- **Claude cannot update itself while two accounts are open.** Its installer waits for every instance to quit, so an account that quits itself to be updated stays closed until the rest do too ([§2.9](#29-updates-need-every-instance-to-quit)). The menu says when this is happening and offers **Quit All & Install Update…**; using it interrupts whatever Claude is doing on every account, like any quit. Detection reads Squirrel's internal files, so a Claude update may break it — in which case the menu simply stops mentioning updates, and quitting Claude on every account by hand still works.
- **The percentages are Claude's own last recording, not a live figure.** They come from a file Claude Desktop writes for itself ([§2.10](#210-where-the-usage-bars-come-from)); it is undocumented, and Claude now records into it when an account starts, when its menu-bar icon is right-clicked, at limit events and on an account change — and on a timer only while that menu has been opened in the last 24 hours, a server setting that can change again. A dash means the reading is certainly out of date; a five-hour limit hit Claude Code recorded since shows as `100%`, recorded.
- **The forecasts and the Advisor are a model, not Anthropic's accounting.** They are fitted to two Max 20x accounts' history on one Mac and rest on fifteen assumptions ([§2.10](#the-assumptions)). Every reset time Claude Code has not recorded exactly is an estimate and says `(est.)`, and so does every estimated number — the lighter part of a bar in its tooltip, since the bar itself has no text. None of it has been seen in the running app yet ([the first live look](#the-first-live-look)).
- **The Fable-only weekly limit is invisible until it is hit.** It can bind while the week still shows room. Medium and long sessions are kept off an account only after Claude Code has recorded a Fable hit there, so the first refused session is one too late. Seeing it sooner would need the per-model figures that only Chromium's HTTP cache and the CLI's cached usage check hold; the first is not read (A11), and the second's are not used.
- **Use the transcripts cannot see is allowed for at 2 points a day.** claude.ai, the phone, cloud sessions and deleted transcripts are invisible until Claude next records; Personal showed two unexplained jumps of about 15 and 13 points. The allowance and the 75th-percentile fit absorb a typical day, not a heavy phone day.
- **The scale gate can trip on that unseen use.** A heavy stretch of it between two recordings can push the ratio past 2 and send the account back to the defaults — labelled *recalibrating after an unusual sample* below 3×, *plan may have changed* from 3× — for a day or more, until two new segments calibrate: 26 hours on this Mac's history, where it happened once (Sep 21). Here the defaults equal the calibrated values, so the advice barely moves. Conversely, a calibrated account that moves to a smaller plan is caught only when `~/.claude.json` names the new plan ([§2.10](#two-review-rulings-that-were-not-applied)).
- **An idle session costs nothing in the reserve.** Only sessions the registry reports busy mid-turn are counted as still to spend; a workflow between turns, or a session you are about to resume, does not reduce its account's headroom.
- **A reset of a light week can be missed.** A drop counts as a reset only when it lands at 5 % or below or falls by 20 points; a week used under 25 % and first sampled above 5 % after its reset leaves no bracket. It has not happened on this Mac's accounts, but a lightly used account could go a week without one.
- **An account's first weeks can take a one-off reset for its schedule.** With no exact anchor and no reset seen twice, a narrow one-off bracket can win the vote and the real reset be called the one-off; on this Mac exact anchors hide it ([§2.10](#two-review-rulings-that-were-not-applied)).
- **The weighting is empirical.** Two accounts, one plan, cache reads excluded, nearly every session at one effort level: a new model, an effort change or a change in Anthropic's own weighting shifts the calibration until enough new segments fit again. Diagnostics prints the fit.
- **Daylight saving.** Weekly anchors are treated as instants in UTC (A8). If Anthropic's schedule follows a local clock, the times shown are an hour off after Nov 1, 2026 until the next exact anchor.
- **Exact five-hour ends stay estimates** unless Claude Code recorded a five-hour limit hit whose reset is still ahead, or the CLI's own usage check is less than an hour old: the HTTP cache that holds them is not read (A11).
- **The first read of the activity index takes a while**, in the background: 5 to 7 seconds on this Mac with a warm disk cache; from a cold disk, or on a slower Mac, longer (not measured). Until it has finished, the Advisor has no rows and nothing is estimated.
- **Two profiles signed in to the same Anthropic account count as two accounts.** The Advisor treats them separately, so either can count as the other's reserve.
- **New and other-plan accounts start on Max 20x figures.** An account with no history is offered short sessions only until Claude records its first sample. An account on another plan that `~/.claude.json` does not name is advised on the Max 20x defaults until two of its own segments have calibrated, with *plan is unknown* in the footer as the only warning.
- **Stall times are coarse.** "Likely hits the limit about Wed morning" is a linear projection over the first hours of a long session, and will be wrong for bursty workflows; the row says *likely*, and the tooltip gives both paces.
- **Terminal sessions are unattributed.** Transcripts no session record names — terminal CLI sessions, sessions whose record was deleted — count for no account: 0.2 % of spend over this Mac's first four weeks of history, about 9 % at 45 days. Cowork's transcripts are not read.
- **A copied session has not yet been run against a live Claude.** Everything in [§2.13](#213-copying-a-session-to-another-account) was read in Claude's code and tested in a temporary home; whether the copy appears after a restart, whether its first turn works under the other account, and which permission mode it starts in are what [the first live copy](#the-first-live-copy) checks.
- **A copy is filed for the account the target is signed in to.** It appears the next time that account's Claude starts, and only while it is signed in to the same account and organisation: if it later signs in to another, the copy is not shown until it signs back in. Its files stay where they are.
- **Do not let Claude's Import adopt a copy.** Claude's **Help › Troubleshooting › Import Claude Code CLI Sessions…** in one account can offer sessions that live in another account — the default account's Import does not see a named account's records (read in Desktop's code) — copies included. Import one, then open or delete it, and two accounts share one transcript: deleting it, or Claude cleaning it up, in one removes it from the other. Every session a named account started already has this exposure; a copy adds one more, and a copy into the default account is not exposed. Claude Switcher marks a session registered in two accounts and will not copy it.
- **A copy no Claude has loaded for 30 days can be cleaned up.** Claude Code removes transcripts that have not changed for 30 days (its default), but exempts the Code tab's, and Desktop renews the ones it has loaded. A copy that no running Claude has loaded — because that account's Claude has not been restarted since — is not renewed, and a cleanup without the exemption can remove it: the terminal `claude` CLI's (version 2.1.220 has none), or the Code tab's own whenever any Claude Code settings file has a validation error. Restart that account's Claude soon after copying, and keep the original until you have opened the copy.
- **An interrupted copy can leave files behind, but never removes one of Claude's.** If Claude Switcher is interrupted mid-copy, it finishes or cleans up at its next start — or, when it cannot prove a leftover is its own, leaves it exactly as it is — and says which. It removes only its own `.claude-switcher-*` staging files, each first proven to be the one it made — never a file Claude made. What it cannot prove is its own stays where it is, with its journal, and a line at each start says so, without naming files; **Diagnostics…** lists such a copy and says where to look (`.claude-switcher-*` in the session's project folder and in the other account's session folder). Usually that is a stray file in its staging folder (a `.DS_Store`, say), or an empty object it created in the instant before it could record it: an empty staging file, an empty staging folder (`.claude-switcher-copy-<id>.dir`), or an empty agent file inside it. In that last case everything else the copy staged stays too — the staged transcript, `.claude-switcher-copy-<id>.jsonl.partial`, as large as the conversation, included — although it is provably the switcher's, because the journal must keep naming every piece until the empty object is gone. Remove that empty object by hand, and the next start removes the rest and finishes the job. A `.<id>.json.partial` left in `~/.config/claude-switcher/copies/` by a crash is never read and never removed. Claude itself adds to a copy's files once it opens them — a title line in the transcript, a rewritten record — as expected.
- **Deleting a copy, or its original.** Deleting the copy in Claude removes only the copy's files; deleting the original never removes the copy's conversation, though the saved tool outputs and uploads it points at go with the original. Deleting through Claude's session-management tool rather than the Code tab leaves the transcript on disk, as it does for any session. And when Claude declines to remove a deleted session's transcript, `<id>.jsonl` stays beside a `<id>.desktop-released.json` marker until Claude Code's own cleanup removes it after 30 days — Claude's own forks show this on disk too.
- **Removing an account never deletes its data.** The Electron profile dir and credential dir are left on disk; delete them yourself if you want them gone.
- **Claude Switcher has not yet updated itself for real.** Everything in [§2.14](#214-claude-switcher-updating-itself) is tested against fakes, the real release's signatures and the real `hdiutil`, but no copy has yet replaced itself in `/Applications` and relaunched; [the first live self-update](#the-first-live-self-update) is that check. Until it has passed, the first run may well show *restart pending* instead of a clean relaunch — the new version then starts at the next launch.
- **Updating depends on GitHub.** Without a token GitHub allows 60 API requests an hour per address, shared by everyone behind the same router or VPN; at one check every six hours a Mac makes about four a day, and a 403 or 429 puts the next check off, never by more than 24 hours. If GitHub serves release files from a host other than the two allowed, or the API answers with a redirect (as it may for a renamed repository), the updater stops there and names the host or the location; that release is installed by hand.
- **A compromised GitHub account cannot ship you an unsigned build — but it can hold you back.** Installing anything takes the developer's own signing key: this team, this identifier, Developer ID, notarized by Apple, the version sealed in it equal to the tag. The same attacker can keep you on the version you have — by marking an older genuine release Latest, or by publishing a newer tag that fails verification — and can make checks download up to 50 MB each until three rejected releases in a row pause automatic downloads. A manifest signed by the developer would close the first; it is out of scope.
- **Launch at Login after the swap is inferred, not observed.** macOS keys a login item by its bundle identifier, and the new copy has the same identifier at the same path, so it is not registered again. That it survives has not been seen on this app; Diagnostics reads the real state after an update and says `needs to be turned on again` if it was lost.
- **A previous copy stays on disk.** `~/.config/claude-switcher/updates/previous/<version>/Claude Switcher.app` is an older Claude Switcher; Launch Services may register it, and whether macOS could ever pick it over `/Applications`, for Launch at Login say, is not known. Diagnostics names its path. Delete it by hand if you like — the automatic return after two failed starts then has nothing to go back to.
- **`~/.config` on another volume from `/Applications`.** The replaced copy cannot be moved into `updates/previous/` across volumes, so it goes to the Trash (Diagnostics: `previous copy: in the Trash`), and the automatic return after two failed starts is not available.
- **The guard against a version that does not start counts force quits.** Until a start of a new version has lasted a minute, any end other than **Quit Claude Switcher** — a force quit, a crash, a logout — counts as a start that failed; two of them send it back to the previous version and reject that release until you check by hand. A notice and Diagnostics say so when it happens.
- **A replaced copy can wait in a temporary folder.** Between the swap and its move to `updates/previous/`, the old copy is in `/var/folders/…/TemporaryItems`; after a crash in that moment it is moved at the next launch, but macOS may clean that folder after some days, so a very long gap could lose it. The installed new version is unaffected.

---

## Not affiliated with Anthropic

This is an independent, unofficial project. It is not affiliated with, endorsed by, or supported by Anthropic. "Claude" and "Anthropic" are trademarks of Anthropic, PBC. The tool never modifies, copies or duplicates the `Claude.app` bundle — it only reads its `Info.plist`, launches it with a standard Electron flag, asks a running instance to show its window when you pick that account and, solely when you ask it to, asks it to quit so that Claude's own updater can run. On its own initiative it only ever starts Claude for an account — and finishes or cleans up a session copy that was interrupted.

On its own initiative it also looks after itself, unless you turn **Keep Claude Switcher Up to Date** off ([§2.14](#214-claude-switcher-updating-itself)): it asks GitHub for its own latest release (`api.github.com`, unauthenticated) and downloads it (from `github.com` and GitHub's asset host) into `~/.config/claude-switcher/updates/`, where it also keeps its records; it mounts that disk image read-only and copies the app into a temporary folder on the same volume as the installed one; it replaces its own bundle in `/Applications` (or `~/Applications`) with the verified new version, moving the old one to `updates/previous/`; and it restarts itself. Nothing in that touches Claude, and no token, cookie or account data is sent.

It writes into Claude's data in two cases, each only when you ask. The small update-block policy, if you turn that on ([§2.12](#212-blocking-claudes-auto-updates)). And a session copy, when you confirm one ([§2.13](#213-copying-a-session-to-another-account)): that creates files in `~/.claude/projects` — the copy's transcript `<id>.jsonl` and, if the session used subagents, `<id>/subagents/agent-*.jsonl`, next to the original's — and one record, `local_<id>.json`, in the other account's session store (`claude-code-sessions/<account>/<organisation>/` in its profile), each first under a `.claude-switcher-*` name it then renames. It never changes the original session, never writes to the source account's store, and never removes or replaces a file Claude made. To list and copy sessions it reads, and only reads: each account's session records and three keys of its `config.json`; Claude Code's `~/.claude/sessions` registry; the transcript of the session being copied and the subagent transcripts it references; and, to prove a copy's new id unused, the session folders of every `~/Library/Application Support/Claude*` folder, configured or not, and `~/.claude/file-history`. Each listing also looks at — without opening — every listed session's working folder and transcript, the markers and tombstones that say Claude deleted it, and the free space on the volume of `~/.claude/projects`, and lists the session folders of every `Claude*` folder. For the usage bars, the forecasts and the Advisor ([§2.10](#210-where-the-usage-bars-come-from)) it reads, and only reads: each account's `plan-usage-history.json`; every Claude Code transcript in `~/.claude/projects` changed in the last 45 days, of which it parses only the lines that carry token counts, a limit hit or a prompt's time; each account's session records, to know whose transcript is whose; `~/.claude.json`, for the plan tier and the CLI's cached usage check; and the `~/.claude/sessions` registry. What it keeps of them — numbers and ids, never text, never a project folder's name — goes into one file of its own, `~/.config/claude-switcher/activity-index.json`, which it keeps up to date on its own initiative, at launch and at each menu open. Nothing else of Claude's is opened for its content.

**It never handles your credentials.** You sign in to each account yourself, interactively, in the app or the CLI. Keychain access is an existence check only — `security find-generic-password -s "<service>" -a "$USER"`, **never** with `-w` — so no secret is ever read, written, copied, migrated or deleted. No `CLAUDE_*` variable is ever injected into a launched app's environment, and `CLAUDE_CODE_OAUTH_TOKEN` is never set.

---

## License

[MIT](LICENSE).

---

## Reference

The project was written specification-first — the sections above describe behavior that was designed before it was implemented, and they remain the intended contract. The two appendices below are the detailed version of that contract.

<details>
<summary><b>Appendix A — implementation contract</b></summary>

The public surface of `ClaudeSwitcherCore`, by owning file. **The source is the source of truth for these signatures** — this appendix is a map, not a spec: if it and the code disagree, the code wins and this appendix is stale. (That is the one place where this document defers; everything above it still governs.)

```swift
// ── Sources/ClaudeSwitcherCore/Config.swift ──────────────────────────────────
public struct Profile: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var label: String
    public var userDataDir: String?          // "" decodes as nil
    public var credDir: String?              // "" decodes as nil
    public var isDefaultProfile: Bool { userDataDir == nil && credDir == nil }
    public init(id: String, label: String, userDataDir: String? = nil, credDir: String? = nil)
}

public enum ConfigError: Error, LocalizedError, Equatable, Sendable {
    case duplicateID(String)
    case unknownProfile(String)
    case cannotRemoveDefaultProfile
    case duplicateDefaultProfile                 // only one profile may omit userDataDir
    case reservedUserDataDir(String, String)     // (directory, why it is reserved)
    case cannotRemoveActiveProfile(String)
    case duplicateUserDataDir(String)
    case duplicateCredDir(String)
    case emptyLabel
    case malformed(String)
}

public struct Config: Codable, Equatable, Sendable {
    public var claudeAppPath: String
    public var activeProfileId: String
    public var profiles: [Profile]
    public var reopenAfterUpdate: Bool      // default true; launch-only
    public var blockClaudeUpdates: Bool     // default false
    public var updateSwitcherAutomatically: Bool   // default true; Claude Switcher only; off = no automatic network request
    public static var configURL: URL { get }              // ~/.config/claude-switcher/config.json
    public static func defaultUserDataDir(home: String = NSHomeDirectory()) -> String   // ~/Library/Application Support/Claude — the one place that name lives
    public static let policyDirectorySuffix: String       // "-3p": Claude's policy directory for a profile is <user-data dir>-3p
    public static func load() throws -> Config            // defaultConfig() when the file is absent
    public static func load(from url: URL) throws -> Config
    public func save() throws                             // atomic, parent dirs created, mode 0600
    public func save(to url: URL) throws
    public static func defaultConfig() -> Config
    public func profile(id: String) -> Profile?
}

extension Config {                                        // pure; nothing here touches disk
    public mutating func addProfile(_ p: Profile) throws
    public mutating func removeProfile(id: String) throws
    public mutating func renameProfile(id: String, label: String) throws   // label only; trims; emptyLabel
    public mutating func setActive(id: String) throws
}

// ── Sources/ClaudeSwitcherCore/PathNormalizer.swift ──────────────────────────
public enum PathNormalizer {
    // Expand a leading "~", make absolute, collapse duplicate slashes,
    // remove trailing slashes (but never reduce "/" to ""), NFC-normalize last.
    // The RESULT is both what gets passed to Claude and what gets hashed.
    public static func normalize(_ raw: String, home: String = NSHomeDirectory()) -> String
}

// ── Sources/ClaudeSwitcherCore/KeychainProbe.swift ───────────────────────────
public enum KeychainProbe {
    public static func serviceName(forCredDir dir: String?) -> String
    public static func isSignedIn(credDir: String?) -> Bool   // existence only; false on any failure
}

// ── Sources/ClaudeSwitcherCore/ProcessArgs.swift ─────────────────────────────
public enum ProcessArgs {
    // Read argv via sysctl KERN_PROCARGS2 so paths containing spaces parse correctly.
    // Failure is nil, NEVER [] — an unreadable argv must not look like "no arguments",
    // which is what identifies the default profile.
    public static func arguments(forPID pid: pid_t) -> [String]?
    public static func parseArgumentBuffer(_ buffer: [UInt8]) -> [String]?   // testable parser
}

// ── Sources/ClaudeSwitcherCore/InstanceManager.swift ─────────────────────────
public enum InstanceProfile: Equatable, Sendable {
    case defaultProfile          // no --user-data-dir: the app's own profile
    case directory(String)       // --user-data-dir=<normalized>
    case unknown                 // argv unreadable; matches NO profile, ever
}

public struct RunningInstance: Equatable, Sendable {
    public let pid: pid_t
    public let profile: InstanceProfile
    public init(pid: pid_t, profile: InstanceProfile)
    // Convenience only: nil for .defaultProfile AND for .unknown.
    // Use `profile` wherever the difference matters.
    public var userDataDir: String? { get }
}

public enum InstanceManagerError: Error, LocalizedError {
    case launchFailed(String)
    case activationFailed(pid_t)
}

public enum InstanceManager {
    public static func bundleIdentifier(appPath: String) -> String?   // from Info.plist, never hardcoded
    public static func runningInstances(appPath: String) -> [RunningInstance]
    public static func profileBinding(fromArguments arguments: [String]?) -> InstanceProfile
    public static func binding(for profile: Profile) -> InstanceProfile
    // Sends that pid the Dock's "reopen" Apple event first (best effort, never waited on), then activates
    public static func activate(pid: pid_t, expecting bundleID: String? = nil) -> Bool
    // The ONLY call that ever ends a Claude process. Graceful; bundleID is non-optional so
    // the pid-reuse guard cannot be skipped. Returns "request sent", not "has quit".
    @discardableResult
    public static func terminate(pid: pid_t, expecting bundleID: String) -> Bool
    // activates: false = started in the background; an instance already up is left where it is
    public static func launch(profile: Profile, appPath: String, activates: Bool = true,
                              completion: @escaping @Sendable (Result<pid_t, Error>) -> Void)
}

// ── Sources/ClaudeSwitcherCore/LaunchPlanning.swift ──────────────────────────
public enum ProfileMatching {
    public static func instance(for profile: Profile, in running: [RunningInstance]) -> RunningInstance?
    public static func isRunning(_ profile: Profile, in running: [RunningInstance]) -> Bool
    public static func unmatched(_ running: [RunningInstance], profiles: [Profile]) -> [RunningInstance]
}

public enum LaunchPlanning {
    public static func launchArguments(for profile: Profile) -> [String]   // [] for the default profile
    public static func terminalCommand(for profile: Profile) -> String     // "claude" for the default slot
    public static func shellQuoted(_ value: String) -> String
}

// ── Sources/ClaudeSwitcherCore/LoginItem.swift ───────────────────────────────
public enum LoginItemState: Equatable, Sendable { case enabled, disabled, requiresApproval, unavailable }

public enum LoginItem {
    // .notFound (never registered) -> .disabled, i.e. registrable; only "not in an .app" is unavailable
    public static func state(for status: SMAppService.Status, runsFromBundle: Bool) -> LoginItemState
    public static func runsFromBundle(_ bundle: Bundle = .main) -> Bool
}

// ── Sources/ClaudeSwitcherCore/UpdateReopen.swift ────────────────────────────
public struct UpdateAttempt: Equatable, Sendable { fromVersion: String; toVersion: String?; at: Date }

public enum UpdateAttemptMarker {              // read-only: never written, moved or deleted
    public static let fileName = "update-attempt"
    public static func fileURL(forUserDataDir dir: String?, home: String = NSHomeDirectory()) -> URL
    public static func parse(_ data: Data) -> UpdateAttempt?
    public static func read(userDataDir: String?, home: String = NSHomeDirectory()) -> UpdateAttempt?
}

public enum UpdateReopen {
    public struct Environment: Sendable {      // no terminate member exists
        public var steps: UpdateInstaller.LaunchOnly
        public var marker: @MainActor (Profile) -> UpdateAttempt?
        public var now: @MainActor () -> Date
        public var bootTime: @MainActor () -> Date?
        public var claimLaunching: @MainActor () -> Bool
        public var releaseLaunching: @MainActor () -> Void
        public static func live(appPath: String, bundleID: String, claimLaunching: …, releaseLaunching: …) -> Environment
    }
    public struct Timing: Equatable, Sendable   // blockedGrace 10 s, claimTimeout 60 s, defaultProfileQuietPeriod 15 s, maximumMarkerAge 24 h
    public struct Reopened: Equatable, Sendable { profile: Profile; attempt: UpdateAttempt }
    public enum Outcome: Equatable, Sendable {
        case nothingToDo, blocked, updaterStuck, notInstalled, busy
        case reopened(AppVersion, [Reopened], notReopened: [Profile])
    }
    public static func candidates(profiles:running:markers:installed:now:bootTime:maximumAge:handled:) -> [Profile]
    @MainActor public static func run(profiles: [Profile], handled: [String: Date] = [:],
                                      environment: Environment, timing: Timing = Timing()) async -> Outcome
    public static func systemBootTime() -> Date?   // kern.boottime
}

// ── Sources/ClaudeSwitcherCore/AutomationLock.swift ──────────────────────────
public enum AutomationLock {                   // one switcher process acts on its own; the rest stand by
    public static var defaultURL: URL { get }  // ~/.config/claude-switcher/automation.lock
    public enum Acquisition: Equatable, Sendable { case acquired(Int32), heldElsewhere, unavailable(errno: Int32) }
    public static func take(at url: URL = defaultURL) -> Acquisition  // non-blocking flock, and why it failed
    public static func acquire(at url: URL = defaultURL) -> Int32?   // the same; nil = do nothing automatic
    public static func release(_ descriptor: Int32)
}

// ── Sources/ClaudeSwitcherCore/Onboarding.swift ──────────────────────────────
public enum Onboarding {                       // whether the welcome window opens by itself
    public static func shouldShowWelcome(alreadyShown: Bool, accountCount: Int) -> Bool   // once, and only with ≤ 1 account
}

// ── Sources/ClaudeSwitcherCore/UpdateBlock.swift ─────────────────────────────
public enum UpdateBlock {
    public static let configID: String             // the one configuration this tool owns
    public enum State: Equatable, Sendable { case off, on, foreign(String), damaged }
    public static func policyDirectory(forUserDataDir dir: String?, home: String = NSHomeDirectory()) -> URL
    public static func state(userDataDir: String?, home: String = NSHomeDirectory()) -> State
    @discardableResult public static func apply(userDataDir: String?, home: String = NSHomeDirectory()) throws -> State   // only from .off / .damaged
    @discardableResult public static func remove(userDataDir: String?, home: String = NSHomeDirectory()) throws -> State  // only files still exactly ours
}

// ── Sources/ClaudeSwitcherCore/UsageHistory.swift ────────────────────────────
public struct UsageSample: Equatable, Sendable { sampledAt: Date; org: String?; utilization: [String: Int] }

public enum UsageHistory {                     // read-only, every member
    public static let fileName = "plan-usage-history.json"
    public static func fileURL(forUserDataDir dir: String?, home: String = NSHomeDirectory()) -> URL
    public static func samples(from data: Data) -> [UsageSample]?          // v1 + v2, sorted; nil unless a history
    public static func read(userDataDir: String?, home: String = NSHomeDirectory()) -> [UsageSample]?
    public static func currentOrgSamples(_ samples: [UsageSample]) -> [UsageSample]
}

public struct SessionWindow: Equatable, Sendable {   // bounds under A3, not estimates
    public static let length: TimeInterval           // 5 h
    public static let startQuantum: TimeInterval     // 10 min (A3)
    public let utilization: Int
    public let resetsAfter: Date                     // exclusive
    public let resetsBy: Date                        // inclusive — what the row shows
    public let exactEnd: Date?                       // a five_hour limit hit or a fresh cached check, still ahead
    public let exactEndCheckedAt: Date?              // set when exactEnd came from the cached check
    public let activityStart: Date?                  // a window only this Mac's activity shows
    public static func floorToStart(_ date: Date) -> Date
    public static func infer(from samples: [UsageSample]) -> SessionWindow?
    public static func infer(from samples: [UsageSample], anchors: [LimitAnchor], activity: ActivityLedger?, now: Date) -> SessionWindow?
}

public struct WeeklyReset: Equatable, Sendable {     // the next occurrence of the WeeklySchedule
    public static let period: TimeInterval           // 7 d
    public let resetsAfter: Date, resetsBy: Date     // under the assumed schedule (A1, A2)
    public let source: WeeklySchedule.Source?, isFresh: Bool   // isFresh: shown without "(est.)"
    public init(schedule: WeeklySchedule, now: Date)
    public static func infer(from samples: [UsageSample], now: Date) -> WeeklyReset?
    public static func infer(from samples: [UsageSample], anchors: [LimitAnchor], now: Date) -> WeeklyReset?
    public func hasCertainlyReset(since sampledAt: Date, now: Date) -> Bool
}

public enum UsageLevel: Equatable, Sendable { case normal, warning, limit   // < 80, 80…99, ≥ 100
    public static func of(_ percent: Int) -> UsageLevel }

public struct UsageReading: Equatable, Sendable {
    public enum Value: Equatable, Sendable { case percent(Int), ended }
    public struct Row: Equatable, Sendable { key: String; label: String; value: Value }
    public static let rowTable: [(key: String, label: String)]   // fh 5h, sd week, so Opus, sn Sonnet, cw Cowork, oa apps, xu extra
    public let sampledAt: Date, age: TimeInterval, rows: [Row], session: SessionWindow?, weekly: WeeklyReset?, unlisted: [String: Int]
    public static func make(samples: [UsageSample], now: Date) -> UsageReading?
    public static func make(samples: [UsageSample], anchors: [LimitAnchor], now: Date) -> UsageReading?
}

public enum UsageText {                        // `time` renders a clock time; injected
    public static func age(_ interval: TimeInterval) -> String?                    // nil under 30 min
    public static func row(_ row: UsageReading.Row) -> String                      // "5h 22%" / "5h —"
    public static func trailing(for row: UsageReading.Row, in reading: UsageReading, time: (Date) -> String) -> String?
    public static func windowReset(_ session: SessionWindow, time: (Date) -> String) -> String   // "resets by 9:10 PM (est.)" / "resets 9:10 PM"
    public static func weekReset(_ weekly: WeeklyReset, time: (Date) -> String) -> String       // "(est.)" unless exact and fresh
    public static func tooltip(_ reading: UsageReading, time: (Date) -> String) -> String       // the recorded part only; the menu uses ForecastText.tooltip
    public static func accessibilityText(_ reading: UsageReading, profileLabel: String, time: (Date) -> String) -> String
    public static func summary(_ reading: UsageReading?, time: (Date) -> String) -> String
}

// ── The usage forecasts and the Advisor (§2.10): the main entry points, by file ──

// WeeklySchedule.swift — the weekly reset, from exact anchors and sample brackets
public struct WeeklySchedule: Equatable, Sendable {
    public enum Source { case exact(anchors: Int, lastHitAt: Date, recordedBy: LimitAnchor.Source), bracketed(support: Double, newestAt: Date) }
    public static let period: TimeInterval, exactAnchorMaximumAge: TimeInterval /* 60 d */, freshnessAge: TimeInterval /* 14 d */
    public let phase: TimeInterval, halfWidth: TimeInterval, source: Source   // phase: seconds into a UTC week (A8)
    public let unconfirmedPhase: TimeInterval?, confirmedAt: Date, reanchoredAt: Date?, outOfOrderSamples: Int
    public func next(after now: Date) -> (after: Date, by: Date)
    public func cycle(containing now: Date) -> (start: Date, end: Date)
    public func hasCertainlyReset(since: Date, now: Date) -> Bool
    public func isFresh(now: Date) -> Bool                      // exact, ≤ 14 d, nothing unconfirmed
    public static func isResetDrop(from previous: Int, to current: Int) -> Bool   // lands ≤ 5 or falls ≥ 20
    public static func infer(samples: [UsageSample], anchors: [LimitAnchor] = [], now: Date) -> WeeklySchedule?
}

// ActivityLedger.swift — one account's activity, in ten-minute buckets
public enum LimitKind: Hashable, Sendable { case fiveHour, sevenDay, fable, model(String), other(String)   // from quotaLimits.rateLimitType
    public var label: String }                                  // "Fable limit", …
public struct LimitAnchor: Hashable, Sendable { resetsAt: Date; kind: LimitKind; hitAt: Date; source: Source   // .transcript / .cachedUsage
    public static func merged(_ anchors: [LimitAnchor]) -> [LimitAnchor] }
public struct ActivityLedger: Equatable, Sendable {
    public struct Bucket, Episode                               // Episode: start, end, spend, prompts, subagentShare, sessionId, first-hour and first-3-h spend
    public let buckets: [Bucket], sessions: [String: [Bucket]], anchors: [LimitAnchor], indexedThrough: Date
    public let unattributedSpend: Double, unpricedCalls: Int, coveredSince: Date?, tier: String?, tierChangedAt: Date?
    public func spend(from: Date, to: Date) -> Double           // weighted spend units (A4), pro-rated within a bucket
    public func episodes(idleSplit: TimeInterval = 1800) -> [Episode]
}

// ActivityIndex.swift — the transcripts, read into ~/.config/claude-switcher/activity-index.json
public enum ActivityWeights {                                   // list prices as a weighting; never money (A4)
    public static func price(for model: String) -> (price: ModelPrice, known: Bool)
    public static func fillInOutput(for model: String) -> Int   // 880 / 1 500 / 1 500 / 1 000
    public static func spend(model: String, input: Int, cacheWrite5m: Int, cacheWrite1h: Int, output: Int) -> Double
}
public struct ActivityAttribution { accounts: [String: String]; claims: [String: String]   // transcript id -> account (A6)
    public static func read(profiles: [Profile], home: String) -> ActivityAttribution }  // only reads
public enum ActivityIndexState: Equatable, Sendable { case building, ready(indexedThrough: Date), stale(indexedThrough: Date) }
public struct ActivityIndexFile: Codable, Equatable, Sendable   // numbers and ids only; paths below the project folder hashed
public struct ActivityIndexSummary { accounts; transcripts; indexedThrough; unattributedShare; unpricedCalls }
public enum ActivityIndex {
    public static var defaultURL: URL { get }                   // ~/.config/claude-switcher/activity-index.json
    public struct Options                                       // first build 14 d, step 7 d, kept 45 d, anchors 60 d, 256 KB reads, ≤ 4 workers
    public struct Refresh: Sendable { file; ledgers: [String: ActivityLedger]; summary; writeError: String? }
    // Blocking: off the main thread. Reads transcripts and records; writes only indexURL, atomically.
    public static func refresh(profiles: [Profile], home: String, indexURL: URL, previous: ActivityIndexFile? = nil,
                               now: Date, options: Options = Options()) -> Refresh
    public static func stored(profiles: [Profile], home: String, indexURL: URL, now: Date, options: Options = Options()) -> Refresh?   // --dry-run: no scan, no write
    // The lock holder at launch: removes only regular files named .activity-index.json.<UUID>.tmp, over a minute old.
    @discardableResult public static func sweepTemporaryFiles(in directory: URL, now: Date = Date(), minimumAge: TimeInterval = 60) -> Int
}

// ExactUsage.swift — ~/.claude.json, read only
public struct ExactUsage: Equatable, Sendable { accountID; rateLimitTier: String?; fetchedAt: Date?; fiveHour…; sevenDay…
    public static let maximumAge: TimeInterval                  // 1 h, the CLI's own
    public var anchors: [LimitAnchor] { get }                   // .cachedUsage: exact times, never a limit hit
}
public protocol ExactUsageSource: Sendable { func exact(for profile: Profile, home: String, now: Date) -> ExactUsage? }   // the seam (A11)
public struct ClaudeConfigUsageSource: ExactUsageSource

// UsageTimeline.swift — windows, calibration segments (cut at every reset) and weekly cycles
public struct UsageTimeline: Equatable, Sendable {
    public let windows: [Window], segments: [Segment], cycles: [Cycle]
    public var limitHitWeeks: (hit: Int, of: Int) { get }      // over the last 4 complete weeks
    public static func build(samples: [UsageSample], activity: ActivityLedger?, schedule: WeeklySchedule?, now: Date) -> UsageTimeline
}

// UsageForecast.swift — estimates with their basis, calibration, the forecast
public enum Basis { case recorded, recordedPlusActivity, recordedNoSchedule, activityOnly, defaults, insufficient(String) }
public struct Estimate<Value> { value; low; high; basis }
public enum PlanLabel { case max20x, unknown, named(String) }   // from oauthAccount.organizationRateLimitTier (A5)
public struct BusySession { cliSessionId
    public static func attribute(running: RunningSessions, attribution: ActivityAttribution, ledgers: [String: ActivityLedger]) -> [String: [BusySession]] }
public struct Calibration: Equatable, Sendable {               // k_w, k_f; the scale gate
    public static let defaultWeekly = 1 / 13.5, defaultWindow = 1 / 3.3, defaultRMSE = 3.0, defaultWindowRMSE = 5.0
    public static let planChangedFlag: String, unusualSampleFlag: String   // a trip at 3× / ⅓× or more, a move or a new tier; a smaller trip
    public let weekly: Double, window: Double, rmse: Double, windowRMSE: Double, segments: Int, medianR2: Double?, windows: Int
    public let flag: String?, tripRatio: Double?
    public var weeklyIsDefault: Bool { get }, windowIsDefault: Bool { get }
    public static func fit(timeline: UsageTimeline, activity: ActivityLedger?, schedule: WeeklySchedule?, now: Date) -> Calibration
}
public struct UsageForecast: Equatable, Sendable {
    public static let unseenPointsPerDay = 2.0                  // A9
    public let weekUsed: Estimate<Double>, headroom: Estimate<Double>, paceWeek: Double?, paceRecent: Double?, pace: Double?
    public let projectedAtReset: Estimate<Double>?, runOutAt: Date?, waste: Int?, weekStart: Date?, weekEnd: Date?
    public let window: SessionWindow?, windowUsed: Estimate<Double>, windowClearsAt: Date?, windowExact: Bool   // windowUsed.high: + max(4, 2 × windowRMSE) + 2/h unseen, ≤ 10
    public let committedWeek: Double, committedWindow: Double, blockedUntil: Date?, blockReason: String?
    public let timeline: UsageTimeline, calibration: Calibration, plan: PlanLabel, stale: Bool, activityKnown: Bool
    public func estimatedPercent(for key: String) -> Int?       // the lighter bar segment; nil before activity is read
    public func widened(unread: TimeInterval, activity: ActivityLedger) -> UsageForecast
    public static func make(profileID: String, samples: [UsageSample], activity: ActivityLedger?, exact: ExactUsage?,
                            busySessions: [BusySession], costs: SessionCosts, now: Date) -> UsageForecast
}

// SessionCosts.swift — what a session of each size costs, in spend units
public enum SessionSize: String, CaseIterable, Sendable { case short, medium, long   // A10
    public static func of(duration: TimeInterval, subagentShare: Double) -> SessionSize
    public var title: String }                                  // "Short — under an hour", …
public struct SessionCosts: Equatable, Sendable {
    public static let defaults: SessionCosts                    // A15, re-derived from 132 episodes
    public static let minimumEpisodes = 8
    public static func calibrate(from ledgers: [ActivityLedger], now: Date) -> SessionCosts
    public func points(for calibration: Calibration) -> SessionCostsPoints   // .reserve = 2 × short p75
}

// UsageAdvisor.swift — fit, reserve, rank, stability, stall
public struct Advice: Equatable, Sendable {
    public indirect enum Reason { case useItOrLoseIt, resetsSoonest, mostHeadroom, comfortableMargin, onlyFit, keepsReserve,
                                  resetUnknown, noUsageRecorded, unchanged(since: Date, original: Reason) }
    public enum Outcome { case start(profileID:, reason:, afterWindowClearsAt: Date?, stallsAbout: Date?), lastHeadroom(profileID:),
                          nothingFits(next: NextChance?, why: Blocker) }
    public struct NextChance { at: Date; profileID: String; event: Event; exact: Bool }   // .weeklyReset, .windowClears, .limitEnds
    public let size: SessionSize, outcome: Outcome, alternatives: [Alternative], basis: Basis, at: Date
}
public enum UsageAdvisor {
    public static let tieWaste = 5, tieReset = 6 h, tieRoom = 10, beatBy = 10, clearSoon = 15 min, reserveClear = 1 h
    public static let recalibratingRatio = 3.0                  // A5 as built
    public static let keepFitting = 1.0                         // an earlier choice keeps fitting this far short of the p75
    public static func advise(size: SessionSize, forecasts: [String: UsageForecast], costs: SessionCosts, order: [String],
                              previous: Advice?, running: Set<String> = [], now: Date) -> Advice
}

// AdvisorText.swift — every word about usage the menu, Diagnostics and --dry-run show
public struct UsageClock: Sendable { now; timeZone; locale }    // time, hour (rounded up: a bound), coarse ("Thu eve"), report, reportUTC
public enum ForecastText {                                      // the grey line: ≤ 40 characters, the hedge within the first 32
    public static func line(_ f: UsageForecast, indexState: ActivityIndexState, clock: UsageClock) -> String
    public static func trailing(for row: UsageReading.Row, forecast f: UsageForecast, clock: UsageClock) -> String?
    public static func tooltip(_ f: UsageForecast, indexState: ActivityIndexState, running: Bool, clock: UsageClock) -> String
    public static func accessibilityText(_ f: UsageForecast, profileLabel: String, clock: UsageClock) -> String?   // the bars' VoiceOver sentence
    public static func keepsTheRule(_ line: String) -> Bool
}
public struct AdvisorMenu: Equatable, Sendable { rows: [Row]; footer: [String]; placeholder: String?   // Row: identifier, title, reason, tooltip, profileID, enabledFrom, isEnabled
    public static let title = "Start a session in…" }
public enum AdvisorText { public static func menu(_ snapshot: UsageSnapshot, labels: [String: String], clock: UsageClock) -> AdvisorMenu }
public enum DiagnosticsText {                                   // forecast, schedule, calibration, limits; ADVISOR; --dry-run's advice
    public static let guarantee: String, assumptions: String
    public static func accountLines(_ f: UsageForecast, costs: SessionCosts, clock: UsageClock, indent: String = "    ",
                                    indexState: ActivityIndexState? = nil) -> [String]
    public static func advisorSection(_ snapshot: UsageSnapshot, labels: [String: String], summary: ActivityIndexSummary?, clock: UsageClock) -> [String]
    public static func dryRunAdvice(_ snapshot: UsageSnapshot, labels: [String: String], clock: UsageClock) -> [String]
}

// UsageSnapshot.swift — the one façade the menu, Diagnostics and --dry-run read usage through
public struct UsageSnapshot: Sendable {
    public let forecasts: [String: UsageForecast], costs: SessionCosts, advice: [SessionSize: Advice], indexState: ActivityIndexState, order: [String]
    public static let maximumUnread: TimeInterval               // 1 h: an older index is .stale — no estimates, no advice
    // Blocking and read-only: each account's samples and ~/.claude.json. Never on the main thread.
    public static func read(profiles: [Profile], home: String, activity: [String: ActivityLedger]?, indexState: ActivityIndexState,
                            previous: [SessionSize: Advice], busy: [String: [BusySession]], running: Set<String> = [], now: Date,
                            exactSource: any ExactUsageSource = ClaudeConfigUsageSource()) -> UsageSnapshot
}

// ── Sources/ClaudeSwitcherCore/StagedUpdate.swift ────────────────────────────
public struct AppVersion: Equatable, Sendable, CustomStringConvertible {
    public let short: String     // CFBundleShortVersionString
    public let build: String     // CFBundleVersion
}

public struct StagedUpdate: Equatable, Sendable {
    public let installed: AppVersion
    public let staged: AppVersion
    public let updateBundlePath: String
}

public struct UpdateStatus: Equatable, Sendable {
    public let installed: AppVersion?
    public let staged: StagedUpdate?
    public let updaterIsRunning: Bool
    public var blocked: StagedUpdate? { get }   // staged, but only while an installer is alive
}

public enum UpdateProbe {                        // read-only, every member
    public static func shipItDirectory(bundleID: String, home: String = NSHomeDirectory()) -> String
    public static func version(ofBundleAt path: String) -> AppVersion?   // plist file, never Bundle
    public static func stagedUpdate(appPath: String, bundleID: String,
                                    shipItDirectory: String? = nil) -> StagedUpdate?
    public static func status(appPath: String) -> UpdateStatus
    public static func isUpdaterCommandLine(_ arguments: [String]?, bundleID: String) -> Bool
    public static func isUpdaterRunning(bundleID: String) -> Bool
}

// ── Sources/ClaudeSwitcherCore/UpdateInstaller.swift ─────────────────────────
public struct UpdatePlan: Equatable, Sendable {
    public let quit: [RunningInstance]     // every instance, recognised or not
    public let reopen: [Profile]           // named profiles first, the default profile last
    public let strays: [RunningInstance]   // quit, but no profile to reopen them from
}

public enum UpdateInstaller {
    public static func plan(running: [RunningInstance], profiles: [Profile]) -> UpdatePlan
    public static func reopenOrder(_ profiles: [Profile]) -> [Profile]   // named first, default last

    public struct LaunchOnly: Sendable {   // what automatic behaviour is handed: no way to quit
        public var runningInstances: @MainActor () -> [RunningInstance]
        public var installedVersion: @MainActor () -> AppVersion?
        public var updaterIsRunning: @MainActor () -> Bool
        public var launch: @MainActor (Profile) -> Void
        public var sleep: @MainActor (Duration) async -> Void
        public static func live(appPath: String, bundleID: String, activates: Bool) -> LaunchOnly
    }
    // on Environment (the confirmed flow's effects):  public var launchOnly: LaunchOnly { get }

    public struct Environment: Sendable {  // every effect, injected; tests use a fake
        public var runningInstances: @MainActor () -> [RunningInstance]
        public var terminate: @MainActor (pid_t) -> Bool
        public var installedVersion: @MainActor () -> AppVersion?
        public var updaterIsRunning: @MainActor () -> Bool
        public var launch: @MainActor (Profile) -> Void
        public var sleep: @MainActor (Duration) async -> Void
        public static func live(appPath: String, bundleID: String) -> Environment
    }

    public struct Timing: Equatable, Sendable   // poll 0.5 s, quit 60 s, install 180 s, settle 3 s, …
    public enum Phase: Equatable, Sendable { case quitting([RunningInstance]), installing, reopening(Profile) }
    public enum Outcome: Equatable, Sendable {
        case changedSinceConfirmation, quitRefused, updaterStuck
        case quitTimedOut(stillRunning: [RunningInstance], closed: [Profile])   // nothing reopened
        case installed(AppVersion, notReopened: [Profile])
        case notInstalled(notReopened: [Profile])
    }

    @MainActor
    public static func run(plan: UpdatePlan, environment: Environment, timing: Timing = Timing(),
                           onPhase: @MainActor (Phase) -> Void = { _ in }) async -> Outcome
}

// ── Sources/ClaudeSwitcherCore/SessionCatalog.swift ──────────────────────────
public struct SessionRecord: Equatable, Sendable, Identifiable {   // a read-only view of local_<uuid>.json
    public let id: String                          // "local_<uuid>"
    public let cliSessionId: String?               // names ~/.claude/projects/<slug>/<cliSessionId>.jsonl
    public let title: String?, cwd: String, originCwd: String?
    public let createdAt: Date?, lastActivityAt: Date?, isArchived: Bool
    public let model: String?, effort: String?, chromePermissionMode: String?
    public let isRemote: Bool, hasWorktree: Bool, hasEarlierTranscripts: Bool, earlierCliSessionIds: [String]
    public var isInClaudeWorktreeFolder: Bool { get }
    public var isInScratchWorkspace: Bool { get }
}
public struct SessionStoreFolder: Equatable, Sendable { url: URL; accountID: String; organizationID: String }
public enum SessionStoreLocation: Equatable, Sendable {
    case none, otherAccountOnly, ambiguous(Int), folder(SessionStoreFolder)
    public var folder: SessionStoreFolder? { get }
}
public enum SessionStore {                         // reads; never writes
    public static let directoryName: String        // "claude-code-sessions"
    public static func userDataDirectory(_ dir: String?, home: String = NSHomeDirectory()) -> URL
    public static func locate(userDataDir: String?, home: String = NSHomeDirectory()) -> SessionStoreLocation   // the listing rule
    public static func records(in folder: SessionStoreFolder) -> [SessionRecord]                             // newest activity first
}
public enum TranscriptLocator {
    public static func projectsDirectory(home: String = NSHomeDirectory()) -> URL   // always ~/.claude/projects
    public static func projectSlug(forCwd cwd: String) -> String                    // Desktop's cliProjectDirSlug, on the raw cwd
    public static func transcriptURL(cwd: String, cliSessionId: String, home: String = NSHomeDirectory()) -> URL
}
public struct SessionListing: Equatable, Sendable {   // what the menu shows for one account; read() blocks, off the main thread
    public let location: SessionStoreLocation
    public let sessions: [ListedSession]              // non-archived, local, transcript on disk; newest first
    public let hidden: HiddenCounts                   // archived, withoutTranscript, remote, total
    public static func read(profile: Profile, allProfiles: [Profile], environment: SessionCopy.Environment = .live) -> SessionListing
}
public struct ListedSession: Equatable, Sendable, Identifiable {
    public let record: SessionRecord
    public let transcriptBytes: Int
    public let isRunning: Bool                        // open in a running Claude: a registry entry with a live pid
    public let obstacle: SessionCopy.Refusal?         // why it cannot be copied to ANY account
}

// ── Sources/ClaudeSwitcherCore/SessionRegistry.swift ─────────────────────────
public struct RunningSessions: Equatable, Sendable {  // ~/.claude/sessions/<pid>.json; read-only, advisory
    public struct Entry: Equatable, Sendable { pid: Int32; cliSessionId: String?; hostSessionId: String?; isBusy: Bool }
    public let entries: [Entry]                       // live processes only: the pid, and its start time where recorded
    public func isOpen(_ record: SessionRecord) -> Bool
    public func isBusy(_ record: SessionRecord) -> Bool
    public static func read(home: String = NSHomeDirectory(), isAlive: … = isProcessAlive) -> RunningSessions
    public static func isProcessAlive(pid: Int32, procStart: String?) -> Bool   // sysctl, never kill(pid, 0)
}

// ── Sources/ClaudeSwitcherCore/SessionCopy.swift ─────────────────────────────
public enum SessionCopy {
    public struct Environment: Sendable {          // every seam; `.live` for the app, a temporary home for tests
        public var home: String
        public var holdsAutomationLock: Bool       // the app sets it from its own AutomationLock
        public var lockFileUnavailable: Bool       // without it because the lock file could not be taken at all
        public var journalDirectory: URL           // ~/.config/claude-switcher/copies
        // …now, newID, expectedUID, isAlive, freeBytes, renameExclusive, pause, hook
        public static var live: Environment { get }
    }
    public enum Step: Hashable, Sendable           // the points a test can stop a copy at, as a crash would
    public struct Request: Equatable, Sendable { source: Profile; target: Profile; sessionID: String; cliSessionId: String; cwd: String }
    public enum Refusal: Error, Equatable, Sendable { …; public var message: String { get } }   // one plain sentence; no id or path but the cwd
    public struct Success: Equatable, Sendable { newSessionID; title; copiedSubagentTranscripts; skippedSubagentTranscripts; transcriptBytes }
    public enum Outcome: Equatable, Sendable { case copied(Success), refused(Refusal), pendingRegistration(newSessionID: String, detail: String) }
    public struct RecoveryNote: Equatable, Sendable { message: String; kind: Kind; copyID: String?; needsAttention: Bool }
    public struct Pending: Equatable, Sendable, Identifiable { id; title; targetStore: URL; copiedAt: Date }
    public struct Unfinished: Equatable, Sendable { targetLabel: String?; state: State (staging, staged, unreadable); since: Date? }
    public struct UnreadableStore: Error, Equatable, Sendable { path: String }   // for Diagnostics only

    // These do blocking file I/O: call them off the main thread, never from menu-building code.
    public static func obstacle(for session: ListedSession, from source: Profile, to target: Profile,
                                allProfiles: [Profile], environment: Environment = .live) -> Refusal?   // nil: offer it
    public static func copy(_ request: Request, allProfiles: [Profile], environment: Environment = .live) -> Outcome   // recovery first
    @discardableResult
    public static func recover(allProfiles: [Profile], environment: Environment = .live) -> [RecoveryNote]   // lock holder only; waits for a running copy
    public static func pending(environment: Environment = .live) -> [Pending]      // committed, not yet opened
    public static func unfinished(environment: Environment = .live) -> [Unfinished]   // read-only: journals not committed
    public static func unreadableStore(allProfiles: [Profile], environment: Environment = .live) -> UnreadableStore?
    public static func confirmationCaveats(sourceLabel: String, targetLabel: String, cwd: String) -> [String]
}

// ── Claude Switcher updating itself (§2.14): the main entry points, by file ──

// SwitcherRelease.swift — versions, the feed, the download's redirects; pure
public struct ReleaseVersion: Comparable, Hashable, Sendable, Codable {   // major.minor.patch
    public init?(tag: String)        // "v0.8.0", ASCII digits only
    public init?(string: String)     // "0.8.0", a sealed CFBundleShortVersionString
}
public struct ReleaseCandidate { version; tag; assetSize; digestHex; immutable   // downloadURL is built from the tag
}
public enum CheckOutcome { case candidate(ReleaseCandidate), noRelease, rateLimited(until: Date), apiRetired,
                           feedMoved(String), feedChanged(String), serverError(Int), offline(String) }
public enum SwitcherReleaseFeed {
    public static let apiURL: URL, assetName = "Claude.Switcher.dmg", maxAssetBytes = 50_000_000
    public static func request(userAgentVersion: String) -> URLRequest
    public static func sessionConfiguration(resourceTimeout: TimeInterval = 60) -> URLSessionConfiguration
    public static func parse(_ data: Data) -> Result<ReleaseCandidate, FeedError>
    public static func outcome(status: Int, headers: [String: String], body: Data?, now: Date) -> CheckOutcome   // ≤ 24 h ahead
    public static func downloadURL(tag: String) -> URL
}
public enum RedirectPolicy { public static func allows(from: URL, to: URL, hop: Int) -> Bool }   // ≤ 3 hops

// SwitcherSignature.swift, SwitcherRunningCopy.swift — who signed what
public enum CodeSignature {
    public static let validationFlags: SecCSFlags   // all architectures, nested code, strict, restrict symlinks and sideband data
    public static let offlineFlags: SecCSFlags      // the same + kSecCSNoNetworkAccess: --dry-run and tests only
    public static func requirementForApp(team: String, identifier: String) throws -> String   // Developer ID, team, identifier, notarized
    public static func requirementForImage(team: String) throws -> String
    public static func verify(bundleAt path: String, requirement: String?, flags: SecCSFlags = validationFlags)
        -> Result<CodeIdentity, SignatureRefusal>
    public static func runningNotarization(trust: SwitcherTrust, flags: SecCSFlags = validationFlags) -> NotarizationVerdict
}
public struct RunningCopy { public static func current(bundle: Bundle = .main) -> RunningCopy }   // read once, at launch
public struct SwitcherTrust { teamID; identifier; runningVersion; public init?(_ copy: RunningCopy) }   // nil: no trust anchor
public enum Installability { case installable, checksOnly(ChecksOnlyReason) }

// SwitcherUpdatePolicy.swift, SwitcherIdle.swift — the rules, without effects
public enum SwitcherUpdatePolicy {
    public static func installability(of: RunningCopy, notarization: NotarizationVerdict, …) -> Installability
    public static func decision(state:outcome:runningVersion:trust:installability:settingOn:isLockHolder:configIsValid:manual:now:) -> Decision
    public static func isDue(state: SwitcherUpdateState, now: Date, settingOn: Bool) -> Bool
    public static func commitHold(snapshot:userAsked:installability:isLockHolder:settingOn:configIsValid:prepared:running:) -> CommitHold?
    public static func nextAttempt(after: Refusal, attempts: AttemptRecord?, now: Date) -> AttemptRecord?   // 1 h, 2 h, 4 h … 24 h
    public static func stagingIsOurs(path:temporaryItems:canonical:lstat:entries:bundleID:runningBundleID:) -> Bool   // the NSIRD rule
    public static func revertDecision(abortedStarts: Int, running: ReleaseVersion?, handoff: UpdateHandoff?, host: String) -> RevertDecision
}
public enum SwitcherShellGate { canQuit, automaticChecksRun, manualCheckRuns, considersInstall }   // the app's gates, tested
public enum SwitcherIdle { public static func blockers(_: SwitcherIdleSnapshot, userAsked: Bool = false) -> [Blocker] }   // 90 s quiet

// SwitcherUpdater.swift — every effect injected; no environment has a field that can reach Claude
public enum SwitcherUpdater {
    public struct CheckEnvironment, PrepareEnvironment, CommitEnvironment   // CommitEnvironment.live is in the app target
    public static func runCheck(manual:context:store:check:prepare:preparing:) async -> CheckRun   // check, decide, prepare, record
    public static func prepare(candidate:trust:installPath:updatesDirectory:env:) async -> Result<PreparedUpdate, Refusal>
    public static func commit(prepared:running:trust:claudeAppPath:userAsked:env:) async -> CommitOutcome   // C1 … C10
    public static func revert(plan:running:trust:previousPath:isLockHolder:claudeAppPath:env:) async -> CommitOutcome
    public static func finishHandoff(_: UpdateHandoff, running: ReleaseVersion?, host: String, now: Date) -> HandoffResult
    public static func reconcileAtLaunch(_: LaunchContext, store:prepare:commit:) async -> LaunchReport
}
public enum CommitOutcome { case launched(Int32), restartPending(String), rolledBack(Refusal), refusedBeforeSwap(Refusal),
                            abortedNotIdle([SwitcherIdle.Blocker]) }

// SwitcherUpdaterLive.swift — the real disk, tools and network
public struct RemovalScope { public func remove(_ path: String) -> Bool }   // the one recursive removal
public enum PrepareLock { public static func take(at path: String) -> SwitcherUpdater.LockRelease? }   // updates/prepare.lock
public enum SwitcherProcess { public static func run(_: String, _: [String], deadline: TimeInterval, observer: Observer? = nil) -> ProcessResult }

// SwitcherUpdateState.swift, SwitcherUpdateStore.swift, SwitcherRelaunch.swift — records and the hand-off
public struct SwitcherUpdateState, UpdateHandoff, StartMarker   // state.json, handoff.json, starting.json
public actor SwitcherUpdateStore {   // temporary file, F_FULLFSYNC, rename
    public func load(now: Date) -> SwitcherUpdateState
    public func update(now: Date, _ body: (inout SwitcherUpdateState) -> Void) throws -> SwitcherUpdateState
    public func writeHandoff(_: UpdateHandoff) throws
    public func recordStart(version:installPath:now:) throws -> Int   // earlier starts that never got going
    public func settleStart(version:isLockHolder:) throws             // a minute after the icon
    public func withdrawStart(version:) throws
}
public enum SwitcherRelaunch {
    public static let argument = "--after-update"
    public static func afterUpdatePID(in arguments: [String]) -> Int32?
    @MainActor public static func start(launchedAfterUpdate: Int32?, env: StartupEnvironment) async -> StartOutcome   // lock, then icon
}
```

</details>

<details>
<summary><b>Appendix B — hard constraints</b></summary>

Violating any of these is a critical defect:

1. **Never** read, write, copy or delete Keychain secrets. Existence checks only, via `security find-generic-password -s "<service>" -a "$USER"`, **never** with `-w`. On failure, degrade silently.
2. **Never** set `CLAUDE_CODE_OAUTH_TOKEN`.
3. **Never** set or modify `CLAUDE_CONFIG_DIR`, anywhere.
4. **Never** use `launchctl setenv`.
5. **Never** modify, copy or duplicate the `Claude.app` bundle. Before Claude Switcher replaces itself it proves the path it is about to swap is not the configured `Claude.app`, nothing inside it and nothing containing it, compared as written and with links resolved, ignoring case.
6. **Never** hardcode the bundle identifier — read `CFBundleIdentifier` from the configured app's `Info.plist`.
7. **Never** put `CLAUDE_*` variables into a launched app's `configuration.environment`; the Desktop account is selected purely by `--user-data-dir`.
8. **Never** shell out to `/usr/bin/open` to launch the app — `Claude.app`, or Claude Switcher's own new copy.
9. **Never** pass `CLAUDE_SECURESTORAGE_CONFIG_DIR` as an empty string; omit it entirely for the default account.
10. No third-party dependencies: Apple's frameworks only. The programs the app runs are tools that ship with macOS — `security` for the Keychain existence check; `hdiutil`, `spctl` and `gktool` for the self-updater — and, for **Diagnostics…**, the `claude` CLI's `--version`.
11. **Never** quit a Claude instance except from the explicit, confirmed **Quit All & Install Update…** action, and then only the pids in the snapshot the user confirmed. `NSRunningApplication.terminate()` only — **never** `forceTerminate()`, **never** a signal. `InstanceManager.terminate(pid:expecting:)` is the single call site.
12. **Never** write, move or delete anything under `~/Library/Caches/<bundle id>.ShipIt`, never edit its request file, and never start `ShipIt`. The update is installed by Claude's installer or not at all.
13. **Never** fetch usage from the network, and never read a token or cookie to do so. Recorded usage comes only from each account's own `plan-usage-history.json` and, for the account the terminal CLI is signed in to, the cached usage check and plan tier in `~/.claude.json`; activity only from Claude Code's transcripts in `~/.claude/projects`, its `~/.claude/sessions` registry and the accounts' session records. All of them are read and **never** written, moved or deleted. What is kept of them — numbers and ids only: never a title, prompt, message text or path, never a project folder's name in any form — goes into one file, `~/.config/claude-switcher/activity-index.json`, written whole under a temporary name and renamed into place, and the switcher removes the temporary file of a write that was interrupted; it is the only file the usage features write. Nothing estimated is shown as recorded: every estimate says `(est.)` or `(default)` — the lighter part of a bar in its tooltip and to VoiceOver — and a time without `(est.)` is one Claude Code recorded.
14. Anything the app does to Claude's processes **on its own initiative only ever starts Claude for an account**. It never quits one, and the code that runs it is handed effects with no way to quit. Rule 11 has no automatic exception. The automatic file work is copy recovery (rule 19) and the self-updater's, which touches only Claude Switcher's own files and bundle (rules 20–25).
15. **Never** write, move or delete `update-attempt`; never open `stealth-relaunch`. An Electron profile's `config.json` (it holds a token cache) is **never written**, and is read only to find its session records — for the session list, and to know whose activity is whose — which uses three of its keys — `lastKnownAccountUuid`, `windowSizeWasSignedIn`, `dxt:allowlistLastUpdated:<organisation>`; nothing else in it is used.
16. Besides a session copy's files (rule 18), the **only** files ever created inside Claude's data area are the two update-block policy files (`<user-data dir>-3p/configLibrary/_meta.json` and `<our id>.json`), and only on the user's toggle. A file is ours only if it is a regular, readable file that says exactly what this tool wrote; **"exists but is not ours" is never treated as "ours but damaged"**. **Never** overwrite, merge into or remove anything else; never follow a symbolic link there; never delete recursively (`unlink` our files, `rmdir` the library); never touch `/Library/Managed Preferences`.
17. Automatic behaviour runs in **one** switcher process (the holder of the lock in `~/.config/claude-switcher/`), and never when the config failed to load — Claude Switcher's own automatic checks, downloads and installs included. The one exception is keeping the activity index of rule 13: every running copy refreshes it, with the accounts it last read, because it only reads and writes nothing but that one file of its own.
18. A session copy is made **only** from the confirmed **Copy to …** action, one at a time, and only by the lock holder. It creates only `<Y>.jsonl` and `<Y>/subagents/agent-<id>.jsonl` in the original's project folder, `local_<Y>.json` in the target's store — each first under its `.claude-switcher-*` staging name — and its journal in `~/.config/claude-switcher/copies/`. It **never** writes to the source account's store or to the original's files, and **never** removes or replaces a Claude-named path (`<id>.jsonl`, `<id>/`, `local_*.json`, `deleted_*`). In Claude's folders it removes only its own staging names, each re-proven first (exact name, regular file, one link, the user's, the journalled inode; the record also by its SHA-256); never deletes recursively; renames only with `renameatx_np(RENAME_EXCL)`, **never** `rename()`; and reaches each of those folders by an `openat(O_DIRECTORY|O_NOFOLLOW)` walk from the home directory (or from a profile's own folder, when it is kept outside the home directory — and really is: a folder spelled outside the home directory that leads into it is refused), following **no** symbolic link on the way. The record carries only the keys in [§2.13](#213-copying-a-session-to-another-account), and never another session's id.
19. Copy recovery acts only on the entries of its own journal — it never looks for names — and only in the lock holder. After a copy's transcript is in place, it only moves forward, or removes its own staged record when another account has registered the transcript. Anything it cannot prove is left untouched, with its journal.
20. The self-updater **never touches Claude**. None of its environments has a field that can start, quit, signal or script Claude; the only application it can start is a new copy of Claude Switcher, by path, and the only process it can end is its own. The tools it runs are `hdiutil`, `spctl` and `gktool`, by absolute path, with an empty environment and input from `/dev/null`, and one that overruns its deadline is left to finish, never killed.
21. It only ever replaces **the bundle it runs from**: the running copy's own bundle path, proven at the moment of the swap to be a folder and not a link, with the running copy's bundle identifier, its executable where it was at launch, writable, and on the same volume as the replacement. The replacement is one `renamex_np(RENAME_SWAP)`, and the only swap back is when the copy now in place fails its check; `FileManager.replaceItemAt` is never used.
22. A release is installed only when it is signed with Developer ID by the **same team** and with the **same identifier** as the running copy — both read from the running copy's own signature, never from a literal — with the hardened runtime, notarized, accepted by Gatekeeper, and with a sealed version equal to its tag and strictly newer than the running one. The disk image is signed by the same team and notarized, and its SHA-256 is GitHub's digest.
23. A copy that is ad-hoc, has no team or no hardened runtime, is not notarized, is translocated, is on a read-only volume, or is not in `/Applications` or `~/Applications` **never replaces itself**; it checks only when asked.
24. **Deletion scope:** nothing is removed recursively except under `realpath(~/.config/claude-switcher)/updates/downloads/` and `…/updates/mounts/` — not when `updates` or those folders are links — and the unswapped staged copy the same process made. A copy of the app that was ever in place is **moved, never deleted** (to `updates/previous/` or the Trash). No path read from `state.json` or `handoff.json` is ever removed; a staging folder named there is touched only through the `NSIRD` rule, and only by moving its app and `rmdir`ing the folder.
25. **Never two icons:** a copy started after an update puts up its status item only once it holds the automation lock, and one that cannot take it within a minute exits without having shown one. The network requests are GitHub's alone — no token, no cookie, no cache — and none is automatic while **Keep Claude Switcher Up to Date** is off.

</details>
