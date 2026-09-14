# 1 · Pace

**In one line:** for every pooled window, how fast it is being used, when it runs out at that rate, and whether that
is before or after the reset — on the row, in the ring's tooltip, and as a notification when it matters.

**Status: built 11 September 2026.** Decisions taken from the open questions: the rate lives in the tooltip and the
Usage tab, not on the row; "fast" means running out earlier than the reset by more than a tenth of the window's length
(floor 30 min). The marker is a muted tick on the track and a dark notch once the bar has passed it. `Pace.swift`,
`PaceTests.swift` (the package's first test target), demo fixtures include a fast session.

## Why

"How much is left" is the first question; "will it last" is the second, and it is the one that changes behaviour
(start the long task now, or wait for the reset). Claude Code Usage Monitor, TokenBar and Codex Limits all show some
form of rate; Claude Tracker draws pace markers in the statusline. Headroom has better data than any of them — one
sample per account per poll for seven days — and shows none of it as a rate. It is also the feature a brand called
Burn would be expected to have.

## In scope

- A rate (points per hour) per pooled window, from the recent samples of that window.
- A projected run-out time at that rate, compared with the window's reset.
- A pace marker: where the window "should" be if usage were spread evenly across it.
- Row UI, ring tooltip, one new notification, one new preference.

## Out of scope

- Token counts or dollar burn (that is the "what this would have cost" feature, later).
- Predictions beyond a linear rate. No smoothing beyond a plain fit; no "learning".
- Anything for windows without a reset time and without a known length.

## Data

Everything comes from `History` (`Sources/Headroom/Store/History.swift`): one `Sample` per account per poll, with
`session`, `weekly` and `pools[windowID] = usedPercent`, kept seven days, at most one per 55 s. The poll interval
defaults to 180 s, so an hour holds about twenty samples.

`Pace.compute(samples:windowID:now:)` (new, pure, in `Store/Pace.swift`):

1. Take the samples for the window from the last **60 min** (session, daily) or **6 h** (weekly, monthly — slower
   windows need a longer look).
2. Cut at the last reset: walking backwards, stop at any drop of 20 points or more between consecutive samples. Only
   samples after the drop count.
3. Need at least **3 samples spanning 15 min**; otherwise pace is `nil` ("no pace yet"). A gap over 20 min between
   samples (sleep) also resets the run.
4. Rate = least-squares slope of used % against time, in points per hour. Clamp small negatives (provider jitter) to 0.
5. Run-out = now + remaining % ÷ rate, when rate > 0.
6. Expected-now = 100 × (elapsed ÷ windowSeconds), when `resetsAt` and `windowSeconds` are known (start = reset −
   length). Marker delta = used − expected.

Result: `struct Pace { rate: Double; runOut: Date?; expectedNow: Double?; verdict: Verdict }` with
`Verdict = .early` (fewer than 3 samples), `.onPace` (run-out after reset, or no reset), `.fast` (run-out before
reset by more than 30 min), `.stalled` (rate 0).

Computed in `UsageStore` right after `history.record(snapshots)` on every successful refresh, stored as
`paces: [String: [String: Pace]]` (account id → window id) on the store — no persistence; it is recomputed from
history at launch. Demo mode (`headroom://demo`) gets fixture histories that produce one `.fast` window so the UI can
be reviewed.

## UI

- **Row bar** (`UI/AccountCard.swift`): a 1-pt tick on the bar at `expectedNow`, in the muted colour, only when known.
  The bar ahead of the tick is a fast window at a glance; no text needed for the common case.
- **Row text**: the existing "35 % · ⏱ 34m" stays. When the verdict is `.fast`, the reset time turns the warning
  colour and the tooltip reads "At this pace it runs out at 9:40 PM, 2 h 30 m before it resets". The rate itself
  ("2.6 %/h") lives in the tooltip, not the row — the row is already full.
- **Ring tooltip** (`App/StatusItemController.swift`): appends " · 2.6 %/h · on pace" / "fast — out by 9:40 PM".
- **Usage tab** (`UI/SettingsView.swift`): under each chart, the current rate and verdict as one muted line.

## Behaviour and edge cases

- A window that resets between polls: the drop cut in step 2 discards the old run; pace goes to `.early` for
  15 minutes. No notification for that.
- Rate limited / stale / problem snapshots are not recorded (already true in `History.record`), so they never
  distort the fit.
- Weekly windows at 0 % for hours: rate 0, verdict `.stalled`; no tick delta shown until usage starts.
- Copilot's monthly pools and Cursor's monthly spend have reset dates and lengths, so they get markers; Grok's
  weekly pool has a reset but no length — projection only, no marker.
- Changing the poll interval changes sample density, not the algorithm; at the 60 s minimum the 55 s collapse still
  yields one sample per minute.

## Notification

New alert in `Store/Alerts.swift`, evaluated with the others after each refresh: when a window's verdict becomes
`.fast` **and** used ≥ 50 % **and** run-out is more than 30 min before the reset, once per window per reset period
(same key scheme as the existing alerts):

> **Claude Team is burning through the week** — 2.6 %/h · out by 9:40 PM, before it resets at 6:10 PM.

Quiet hours and the master toggle apply. Preference: **"Warn when a window will run out before it resets"**
(`Preferences.notifyOnPace`, default on) in Settings → General → Notifications.

## Files

`Store/Pace.swift` (new), `Store/History.swift` (a `samples(for:window:last:)` helper), `Store/UsageStore.swift`,
`Store/Alerts.swift`, `Store/Preferences.swift`, `UI/AccountCard.swift`, `UI/SettingsView.swift`,
`App/StatusItemController.swift`, `Store/DemoData.swift`, README.

## Verification

- A `Tests/HeadroomTests/PaceTests.swift` target (the package has no tests yet; this is the first): synthetic samples
  for a steady 2 %/h window, a window that reset mid-run, a sleeping Mac (a 40-minute gap), and fewer than three
  samples — each asserting rate, run-out and verdict.
- `headroom://demo`: the fixture "Personal" account shows the tick ahead of the bar, the warning-coloured reset time,
  and the tooltip sentence; `headroom://alerts?test=1` gains the pace banner.
- Live: after an hour of normal use, the ring tooltip shows a plausible rate; the log gets one line per refresh with
  the verdicts (`pace: studio session 2.6/h on-pace · weekly 0.4/h on-pace`).

## Open questions

- Show the rate on the row for `.fast` windows only, or never (tooltip only)? Draft says tooltip only.
- Threshold for `.fast` (30 min before reset) — too twitchy for 5-hour sessions? Could scale with window length
  (10 % of the window).
