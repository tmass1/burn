# 3 · Vendor status

**In one line:** when Anthropic, OpenAI, Cursor or GitHub are having an incident, say so — a small chip on the rows
it affects, and error cards that blame the vendor instead of the sign-in.

**Status: built 11 September 2026.** `Store/VendorStatus.swift` (observable, polls the four Statuspage summaries every
5 min, 15-min grace after a failed poll, `parse` is pure and tested with eight cases including today's real shape —
Anthropic's "minor outage" is Claude Cowork only, so Claude reads *fine*), `VendorCondition` and `statusPage` per
`ProviderID` in Models, chip on every row of the affected provider (`VendorChip`, click opens the page), one muted
header line per vendor in trouble, error cards rewritten to "Anthropic is having an incident — … Backing off" with a
Status page button (`AccountProblem.Action.openLink`), backoff of at least five minutes for a failing provider whose
vendor is degraded, Settings → General → "Show vendor status", demo fixture on the Claude rows. OpenAI's component
names checked today: `Codex Web`, `Codex in ChatGPT Desktop`, `Codex API`, `Login` — matched by the `Codex`/`Login`
prefixes.

## Why

CodexBar polls provider status pages and overlays incident badges. Headroom shows "Rate limited — backing off" and
"Error" cards that are sometimes the vendor's outage, not the account's; today, 11 September, status.claude.com
reports a minor outage while the Personal card says "Rate limited". The status pages have public JSON, so the cost is
small and the explanation is the whole value.

## Sources

All four use Atlassian Statuspage's v2 API — `GET <page>/api/v2/summary.json` — checked today:

| Provider(s) | Page | Components that matter |
|---|---|---|
| Claude (all accounts) | `status.claude.com` (`status.anthropic.com` redirects there) | `claude.ai`, `Claude API (api.anthropic.com)`, `Claude Code` |
| ChatGPT / Codex | `status.openai.com` | verify names on first run; likely `Login`, `API`, `ChatGPT`, `Codex` |
| Cursor | `status.cursor.com` | `IDE`, `CLI`, `cursor.com` |
| Copilot | `www.githubstatus.com` | `Copilot` |

Gemini/Antigravity (`status.cloud.google.com/incidents.json`, a different shape) and Grok (`status.x.ai` answers 403
to plain requests) are out of the first cut; the adapter is one enum case each when they are worth it.

Summary payload used: `status.indicator` (`none` / `minor` / `major` / `critical`), `components[].{name,status}`
(`operational` / `degraded_performance` / `partial_outage` / `major_outage`), `incidents[].{name,status,shortlink}`.

## In scope

- `VendorStatus` (`Store/VendorStatus.swift`, an actor): polls each page every **5 min** while the app runs (and on
  demand from a refresh), keeps the last result per provider with a fetched-at, and publishes
  `[ProviderID: Condition]` to `UsageStore`.
- `Condition = .fine | .degraded(name) | .outage(name) | .unknown` — derived only from the components in the table
  (an incident on "Claude for Government" is not our incident). The incident name comes from the first open
  incident touching those components, else the component's own status text.
- Row chip, error-card wording, header note, one preference.

## Out of scope

- Historical uptime, incident timelines, links in notifications.
- Turning status into notifications of its own. The panel is where you look when something is off; a "Claude is
  degraded" banner every time a page flickers would be noise.

## UI

- **Row chip** (`UI/AccountCard.swift`): next to the stale badge's spot — "Degraded" in the warning tint,
  "Outage" in the critical tint, tooltip with the incident name; clicking opens the status page. Shown on every
  account of the affected provider. Nothing when `.fine` or `.unknown`.
- **Error cards**: when a provider fetch fails (HTTP 5xx, timeout, rate limited) **and** the condition is not
  `.fine`, the problem card says "Anthropic is having an incident — *<incident name>*. Backing off." with a
  "Status page" button, instead of the generic error. The card's sign-in action is hidden in that case, so a
  vendor outage never sends anyone to re-authenticate.
- **Header** (`UI/PanelView.swift`): nothing unless something is up; then one muted line under the title,
  "Anthropic: minor outage", so the panel explains itself before the rows do.

## Behaviour and edge cases

- Backoff: a failing provider whose vendor is degraded waits the longer of its normal backoff and 5 min; the
  condition is re-checked before the next attempt.
- The status poll itself failing (offline, page down) leaves the last condition for 15 min, then `.unknown`. No
  chips for `.unknown`.
- Statuspage "minor" with all relevant components operational → `.fine` (they often flag unrelated components).
- The four pages are fetched in parallel with a 10 s timeout; total cost is four small requests every five minutes.
- Demo mode: a fixture condition (`.degraded("Elevated errors on claude.ai")`) on the Claude rows so the chip and
  card wording can be reviewed; `headroom://demo` only.

## Settings

Settings → General: **"Show vendor status"** (`Preferences.showVendorStatus`, default on). Off stops the polling
entirely.

## Files

`Store/VendorStatus.swift` (new), `Store/UsageStore.swift`, `Providers/Models.swift` (`Condition`, a
`statusPage` per `ProviderID`), `UI/AccountCard.swift`, `UI/PanelView.swift`, `UI/SettingsView.swift`,
`Store/Preferences.swift`, `Store/DemoData.swift`, README.

## Verification

- Parser test with saved `summary.json` fixtures (today's real payloads: Anthropic minor outage, OpenAI partial
  degradation, Cursor and GitHub operational) asserting the derived `Condition` per provider.
- `headroom://demo` shows the chip, the header line and the reworded card.
- Live: with status.claude.com reporting minor outage today, the Claude rows show "Degraded" and the log has
  `vendor status: anthropic degraded — <incident>`; when the incident clears, the chip goes within one poll.

## Open questions

- Component names for OpenAI's page need confirming against a real incident before the mapping is trusted.
- Chip on every account of the provider (three Claude rows) or once, in the header? Draft says both; the header line
  might be enough.
