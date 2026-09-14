# 4 · Launchers

**In one line:** the panel says which account has room; a launcher takes you there — `claude-<profile>` commands
for every Claude account Headroom knows, and "Open Terminal with this account" on the row.

**Status: built 11 September 2026.** `Store/Launchers.swift`: slugs (`claude-studio`, `claude-atlas`,
deduplicated with `-2`), shims with the absolute `claude` path and `CLAUDE_CONFIG_DIR` (none for the default profile),
`Preferences.installedLaunchers` for reconciliation (rename rewrites, removal deletes, only files carrying the
"Installed by Headroom" marker are ever removed). "Open Terminal with this account" hands Terminal or iTerm2 a
`.command` file under Application Support/launch — no Apple Events, so no automation entitlement — and copies the
command for Warp, Ghostty or the "copy instead" preference (Settings → General → "Open terminals in", listing only
installed apps). Surfaces: Settings → Accounts ⋯ menu (Open Terminal, Install/Remove command; Open ChatGPT/Cursor/
Antigravity for the others), an "Install all commands" footer button with a PATH hint, a hover ⋯ on every panel row
(Open Terminal, Copy Command, Open <app>, Hide), and `headroom launchers [install|remove] [account]`. Verified:
`claude-atlas auth status --json` reports the Atlas account. Decision from the open questions: no auto-install after
sign-in yet — the footer button is one click and says where the files went.

## Why

Claude Tracker installs per-profile launchers and can auto-switch the active login. Headroom already owns the hard
part — separate Claude Code profiles (`CLAUDE_CONFIG_DIR` directories under `~/.claude-personal*`) with in-app
sign-in — and stops one step short: after reading that Atlas has room, you still type the environment variable by
hand. Closing that gap is the natural end of the app's one question.

## In scope

- Shell shims `claude-<slug>` in `~/.local/bin`, one per Claude account, installed and removed from Settings.
- "Open Terminal with this account" on Claude rows (panel ⋯ menu and Settings → Accounts ⋯ menu), and "Copy
  command" beside it.
- A Terminal-app preference.
- For the other providers, the existing "open the vendor's app" action, now offered on the row as well as on error
  cards.

## Out of scope

- Auto-switching the *default* Claude login (rewriting Claude Code's keychain item). Too easy to surprise someone
  mid-session; the shims make switching explicit and reversible instead.
- Remembering project folders; the terminal opens in the home folder, as a new window does.

## Shims

- Slug: the account's label, lower-cased, non-alphanumerics to hyphens, deduplicated — `claude-atlas`,
  `claude-personal`, `claude-studio`. Renaming the account in Settings renames the shim.
- Content, for a profile account:

  ```sh
  #!/bin/sh
  # Installed by Headroom — Claude Code as Atlas
  export CLAUDE_CONFIG_DIR="$HOME/.claude-personal-3"
  exec "/opt/homebrew/bin/claude" "$@"
  ```

  The `claude` path is resolved at install time with `CLI.locate` and written absolutely, so the shim works in
  shells with a different PATH. For the default profile the export line is omitted (the shim is then just a named
  alias, `claude-studio`).
- Permissions 0755; the list of installed shims lives in `Preferences.installedLaunchers` so removal, rename and
  "Install all" can reconcile. Removing an account removes its shim.
- Settings → Accounts → ⋯ → **"Install `claude-atlas` command"** / **"Remove command"**; the Accounts footer gets
  **"Install all commands"** when any are missing. If `~/.local/bin` is not on PATH, the row says so with the line to
  add.

## Open Terminal

- Settings → General → **Terminal app**: Terminal (default), iTerm2, Warp, Ghostty, or "Copy the command instead".
  Only apps present in `/Applications` are listed.
- **Terminal / iTerm2**: an AppleScript `do script "claude-atlas"` in a new window — no typing simulation, no
  clipboard. **Warp / Ghostty**: launched with `open -a`, and the command is put on the clipboard with a toast
  "Copied `claude-atlas` — paste to start" (neither takes a script reliably).
- The shim is installed on first use if it is missing, with a one-line confirmation.
- Non-Claude rows: "Open ChatGPT" (Codex), "Open Cursor", "Open Antigravity" (Gemini), "Open Terminal with `grok`";
  Copilot has no app to open, so nothing.

## Row affordance

- Panel: the ⋯ that already exists on error cards becomes a hover control on every row; its menu holds "Open
  Terminal with this account", "Copy command", the sign-in actions the card already has, and "Hide".
- The tightest row does **not** get a special "Use this one" button in the first cut — the ordering already says
  it, and a button on one row implies a recommendation the app cannot actually make (the Atlas account with room may
  not have the project).

## Behaviour and edge cases

- Claude Code refuses to run when `CLAUDE_CONFIG_DIR` points at a profile that is signed out: the shim's session
  will show the login prompt, which is correct; Headroom's row will already say "Sign in again".
- Two accounts with the same label → slugs `claude-personal` and `claude-personal-2`, stable across renames of the
  other.
- Removing `~/.local/bin` shims is only ever done for files Headroom wrote (checked by the header comment).
- No shims for Gemini, Grok, Cursor or Copilot: their CLIs and apps hold one account each.

## Files

`Store/Launchers.swift` (new: slugs, shim writing, terminal opening), `Store/Preferences.swift`, `UI/AccountCard.swift`,
`UI/PanelView.swift`, `UI/SettingsView.swift`, `Store/SignIn.swift` (`ClaudeProfiles` exposes the path per account),
README.

## Verification

- Install the Atlas shim; `claude-atlas auth status --json` prints the Atlas account; `claude-studio auth status`
  prints the business account. Rename Atlas → "Atlas Co"; the shim becomes `claude-atlas-co` and the old one is gone.
- "Open Terminal with this account" opens a new Terminal window running `claude-atlas`; with iTerm2 selected, an
  iTerm window; with Warp selected, Warp comes forward and the clipboard holds the command.
- Remove the Atlas account; the shim is deleted; `Preferences.installedLaunchers` no longer lists it.

## Open questions

- Also offer `codex-<label>` once a second Codex account exists? Nothing to launch yet.
- Should "Install all commands" run automatically after every in-app sign-in? Probably yes, with a toast.
