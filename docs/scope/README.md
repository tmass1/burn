# Scope — the next four features

Written 11 September 2026 from the competitive read on the brand board. Four features Headroom lacks that the
category has, chosen for value now, effort, and what nobody else does well. Each has its own document: data, UI,
behaviour and edge cases, settings, files, verification, open questions. All four are built (11 September 2026); each document carries a status line saying what was decided.

| # | Feature | One line | Effort | Depends on |
|---|---------|----------|--------|------------|
| 1 | [Pace](pace.md) | How fast each window is going, when it runs out at this rate, and whether that is before the reset | S–M | nothing — the 7-day history already holds the samples |
| 2 | [CLI + statusline](cli-statusline.md) | `headroom` on the command line, and a segment for the Claude Code status line | S | a shared models library (the app and the CLI decode the same `snapshots.json`) |
| 3 | [Vendor status](vendor-status.md) | A "degraded" chip when Anthropic, OpenAI, Cursor or GitHub are having an incident, and error cards that say so | S–M | nothing |
| 4 | [Launchers](launchers.md) | `claude-<profile>` commands and "Open Terminal with this account", so the answer leads straight to the action | S–M | nothing; pairs with the CLI's install step |

Suggested order: 1, 2, 3, 4. Pace is the feature the Burn brand would promise and it needs no new data; the CLI is
an evening and unlocks the statusline; vendor status is small and explains the errors we already show; launchers
close the loop from "which account has room" to "use it".

S = an evening · M = a couple of days · L = a week or more.

What Headroom already has that the field does not, so parity never eats the roadmap: several accounts per provider
with in-app sign-in, plan cost per account, quiet hours and reset alerts, and a designed panel.
