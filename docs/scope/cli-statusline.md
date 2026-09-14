# 2 · CLI + statusline

**In one line:** a `headroom` command that prints what the panel knows, and a segment for the Claude Code status
line, so the numbers are where the work is.

**Status: built 11 September 2026**, with one change from the plan below: no shared models library. Splitting the
models out would have meant `public` on every type; instead the app binary has a CLI mode (`Headroom cli …`, checked
first thing in `main.swift`, never starting the app) and `~/.local/bin/headroom` is a two-line wrapper that execs it —
the way `code` wraps VS Code. `App/HeadroomCLI.swift` (commands, formatting), `Store/CommandLineTool.swift` (the
wrapper and the status-line install), `paces.json` written by the store beside `snapshots.json`. `make install`
writes the wrapper; Settings → General → Command line does the same, and adds the status-line segment. Decisions from
the open questions: the segment uses the `◐` glyph and text, not bars; no cost column (it is in `json`). The
status-line install writes a wrapper script that runs the existing status line first and appends the segment, and
points `settings.json` at it after backing it up — the user's own script is never edited.

## Why

Claude Tracker and ccusage put usage in the Claude Code status line; CodexBar ships a CLI; OpenUsage exposes a local
HTTP API. Headroom already writes everything it knows to
`~/Library/Application Support/Headroom/snapshots.json` on every refresh — the CLI is mostly a reader. Tommy already
runs a status line (`~/.claude/statusline-command.sh`: directory, model, context, git branch), so Headroom adds a
segment to it rather than replacing it.

## In scope

- A `headroom` executable built by the same package, installed by `make install`.
- `headroom` (table), `headroom --json`, `headroom status [account]` (one line), `headroom statusline` (a segment
  for the Claude Code status line), `headroom refresh` / `headroom open` (through the URL scheme).
- A one-step install of the statusline segment into the existing script.

## Out of scope

- The CLI fetching anything itself. It reads the app's file; if the app is not running the numbers are as old as
  the file says, and the CLI says so.
- An HTTP API. The file is the API; a JSON command covers scripts.

## Package

`Package.swift` gains a library target `HeadroomModels` (`Sources/HeadroomModels/`: `Models.swift`, the
`Relative` time formatter, `PlanPricing`) that both the app and the new executable target `headroom`
(`Sources/HeadroomCLI/main.swift`) depend on. The app target keeps everything else. `scripts/bundle.sh` copies the
CLI binary to `Headroom.app/Contents/MacOS/headroom`; Settings → General gets **"Install command-line tool"** which
symlinks it to `~/.local/bin/headroom` (already on PATH here) — the same gesture VS Code uses.

## Commands

```
headroom                      # one row per visible account: label · tightest window · used % · resets · stale?
headroom --json               # the snapshots file, plus "paces" and "age" fields
headroom status [label|id]    # "Studio · session 35 % · resets 34m · weekly 12 %"
headroom statusline           # the Claude Code segment (see below); reads Claude Code's JSON on stdin
headroom refresh              # open headroom://refresh
headroom open                 # open headroom://show
headroom statusline --install # add the segment to ~/.claude/statusline-command.sh (backs it up first)
```

Exit codes: 0; 2 when the file is missing (app never ran); 3 when the account is not found. `--no-color` and
`NO_COLOR` respected; ANSI colour by state otherwise (green / amber / red, the app's thresholds).

## The statusline segment

Claude Code runs the status-line command with a JSON object on stdin (`model`, `workspace`, `context_window`,
`session_id`, …) and shows the printed line. Headroom's segment:

```
◐ 35 % · 34m │ wk 12 %
```

- Which account: the Claude profile matching `CLAUDE_CONFIG_DIR` in the environment (the status-line command
  inherits Claude Code's environment), else the default profile. Not found → print nothing, exit 0, so the line
  never shows an error.
- Freshness: if `fetchedAt` is older than twice the poll interval the segment is dimmed and gains "· 12m old". The
  statusline must never trigger a refresh (it runs every few seconds); `headroom refresh` is for that.
- Colour: the used % takes the state colour; the ring glyph is text (`◐`).
- `--install` appends one line to the existing script — `hr=$(headroom statusline 2>/dev/null)` and adds `$hr` to the
  echo — after writing `statusline-command.sh.bak`. If no script exists it writes a minimal one and sets
  `statusLine` in `~/.claude/settings.json` (merge, not overwrite).

## Behaviour and edge cases

- The file is written atomically by the app, so the CLI never reads a half file; a decode failure prints "Headroom's
  data could not be read — is the app up to date?" and exits 2.
- Hidden and removed accounts (`Preferences`) are respected: the CLI reads the same defaults domain
  (`com.tommymassaro.headroom`) read-only.
- Demo mode: the file is not written while demo fixtures are showing (already the case), so the CLI keeps the last
  live numbers.

## Files

`Package.swift`, `Sources/HeadroomModels/*` (moved), `Sources/HeadroomCLI/main.swift` (new), `scripts/bundle.sh`,
`UI/SettingsView.swift` (install button), README.

## Verification

- `swift build` produces both binaries; `make install` places the CLI in the bundle; the Settings button creates the
  symlink and `headroom` runs from a fresh shell.
- `headroom` prints the same accounts as the panel; `headroom --json | jq .accounts[0].label` works.
- `echo '{"model":{"display_name":"Opus"}}' | CLAUDE_CONFIG_DIR=$HOME/.claude-personal-3 headroom statusline` prints
  the Atlas account's segment; without the variable, the default profile's.
- After `--install`, a new Claude Code session shows the segment; the backup file exists.

## Open questions

- Ship the segment with the ring glyph or a plain bar (`▮▮▮▯▯`)? Bars read better in monospace.
- Should `headroom` also print the plan cost column? Cheap, since `PlanPricing` moves to the library.
