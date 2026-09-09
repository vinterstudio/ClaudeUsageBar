# ClaudeUsageBar

A native macOS menu bar app that shows your **Claude Code session usage percentage** — with zero model tokens consumed while running.

![Menu bar showing S 19% · W 25% · 02:00](https://img.shields.io/badge/menu%20bar-S%2019%25%20%C2%B7%20W%2025%25%20%C2%B7%2002%3A00-blue)

## What it does

- Shows a compact summary in the menu bar: **`S 19% · W 25% · 02:00`**
  - `S 19%` — current **s**ession (5h) used
  - `W 25%` — **w**eekly (7d) used
  - `02:00` — session reset time (24-hour clock)
- Dropdown spells out both windows with reset times and countdowns
- Polls every 5 minutes — no dock icon, runs silently in the background
- Backs off automatically if the endpoint rate-limits (HTTP 429)

**Token cost: zero.** The app reads the OAuth usage metadata endpoint — it never sends a prompt to a model.

## Requirements

- macOS 13 (Ventura) or later
- A [Claude](https://claude.ai) account with Claude Code installed and signed in
- Xcode Command Line Tools: `xcode-select --install`

## Install

```bash
git clone https://github.com/vinterstudio/ClaudeUsageBar.git
cd ClaudeUsageBar

# (Recommended) Create a stable signing identity so "Always Allow" persists
./make-signing-identity.sh

# Build the .app bundle into dist/
./build-app.sh

# Launch it
open dist/ClaudeUsageBar.app
```

**Launch at login:** System Settings → General → Login Items → + → pick `ClaudeUsageBar.app`

## How it works

Claude Code stores your OAuth credentials in the macOS login Keychain under the item `Claude Code-credentials`. ClaudeUsageBar reads that same item (using the Security framework — no shell calls) and adopts whatever valid token Claude Code has stored. It never refreshes or writes the item — Claude Code is the sole owner, so the Keychain access list never gets reset (which is what caused repeated "security wants to access" prompts). With a valid token it calls:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <token>
anthropic-beta: oauth-2025-04-20
```

This endpoint returns your plan's utilization windows. It is a **metadata call only** — no model is invoked, no tokens are consumed, and it does not count against your usage limit.

### Keychain access prompt

The first time the app runs it will ask for Keychain access with a macOS prompt. Click **Always Allow** — this grants permanent, per-app trust and you will not be prompted again. The app is signed with a stable local identity (`ClaudeUsageBar Self-Signed`) so the grant survives rebuilds.

## Token refresh

When the access token expires (~every 8 hours), the app refreshes it via the same OAuth flow Claude Code uses and writes the rotated credentials back to the same Keychain item. Both apps stay in sync — Claude Code continues working without re-login.

The refresh is handled at most once every 8 hours. The Keychain is not touched on every poll — credentials are cached in memory between refreshes.

## Menu

| Item | Description |
|------|-------------|
| `Session: 19% used   Weekly: 25% used` | Both windows, spelled out |
| `Session resets 02:00 (in 4h 15m)   ·   Weekly resets Sat 09:00 (in 5d)` | Reset times (24h clock) + countdowns |
| `Updated 14:28:01` | Last successful poll |
| Refresh Now | Poll immediately (bypasses any active backoff) |
| Reveal Raw Response | Opens `~/Library/Logs/ClaudeUsageBar/last-usage-response.json` in Finder |
| Quit | Exit |

## Polling & rate limits

The app polls every 5 minutes. Usage changes slowly, so this keeps the menu bar fresh without hammering the endpoint. If the endpoint returns **HTTP 429 (rate limited)**, the app backs off exponentially (5 → 10 → 20 min, capped at 30) and keeps showing the last good numbers, with the status line noting when it will retry. **Refresh Now** forces an immediate poll regardless of backoff.

## Security

- **No secrets in code.** The app reads credentials from your Keychain at runtime.
- **Swift Security framework only.** No `security` CLI invocations from the app itself.
- **`SecItemUpdate` preserves ACLs.** When the app writes a refreshed token back, it uses `SecItemUpdate` which leaves the access-control list intact.
- **Stable signed identity.** The app is signed with a local self-signed certificate so macOS can enforce per-app Keychain trust.

## Rebuilding

```bash
./build-app.sh   # rebuilds dist/ClaudeUsageBar.app
```

If you skip `make-signing-identity.sh` the app is signed ad-hoc. It still works, but you may be prompted for Keychain access again after each rebuild (click Always Allow each time).

## License

MIT — see [LICENSE](LICENSE)

---

Built by [Andreas Vesterlund](https://vinterstudio.com)

## 30-day token history

The dropdown and the notch panel show a rolling 30-day view of token usage,
reconstructed from Claude Code's own transcripts in `~/.claude/projects/**/*.jsonl`.
No API key, no network call, no third-party service — it reads files Claude Code
has already written.

- **Fresh tokens** (input + output + cache writes) drive the daily bars.
  Cache reads are reported separately, and deliberately excluded from the bars:
  on a real corpus they are ~98% of the raw count (3.3B of 3.35B over 30 days),
  so including them turns the chart into a picture of cache-read volume.
- **By project** splits the window by working directory.
- Turns are deduplicated on `requestId`, so retries and resumed sessions are
  counted once.

Scanning is incremental: each file's parsed byte offset is remembered, so a
refresh only decodes bytes appended since the last pass. The first, full scan of
a ~900MB corpus takes about 8 seconds on an M2 and runs off the main thread.

## Overlay mode

The overlay shows the same data outside the menu bar, and works on **every**
display — the presentation adapts:

- **Notch mode**, where the notch is addressable: two "wings" flank the cut-out,
  matched to the display's own `safeAreaInsets.top` height, drawn with no
  background so they sit in the translucent menu bar rather than on top of it.
  The left wing carries both quota figures (`S 41% · W 68%`, each colour-coded
  independently); the right wing carries live activity.
- **Pill mode**, where it isn't: a rounded pill hanging just below the menu bar.

Hovering expands either into the same panel — both quota bars, the 30-day chart
and the project split. The mode flips automatically on a resolution change; the
menu names which presentation the current display will get, and says which
resolution would expose the real notch.

### Live activity (optional)

Notch mode can react to what Claude Code is doing. This needs a hook script
registered with Claude Code:

```bash
./hooks/install-hooks.sh          # merges into ~/.claude/settings.json (backs it up first)
./hooks/install-hooks.sh --uninstall
```

The hook forwards exactly three fields to a local Unix socket — event name,
session id and tool name. **No prompt text, file contents or tool arguments
leave the machine, and nothing is sent anywhere off it.** The socket lives in the
app's Application Support directory at mode 0600. The hook exits 0 on every path
(including when the app is not running) so it can never fail one of your turns.

Unlike notchi, there is no sentiment analysis and no API key: nothing here spends
model tokens.

### Rendering the notch without a display

```bash
swift build -c release
./.build/release/ClaudeUsageBar --render-notch /tmp
```

Writes `notch-collapsed.png` and `notch-expanded.png` using your real history
data — how the notch UI is verified in a build step rather than by eye.

## Where the numbers come from

**Primary: `~/Library/Application Support/Claude/plan-usage-history.json`.** The Claude
desktop app records its own quota every ~15 minutes and keeps a rolling 30-day series
(`fh` = five-hour %, `sd` = seven-day %). Reading it needs no credentials, makes no
network call, and cannot raise a keychain prompt.

**Fallback: the OAuth usage endpoint**, used only when that file is absent.

The switch happened on 2026-09-09 because the OAuth path had stopped working: the
keychain item `Claude Code-credentials` now contains **empty** token strings with
`expiresAt: 0`, its refresh token having expired. Claude Code moved its credentials into
the Electron `Claude Safe Storage` key. Running `claude` rewrites the old item but does
not repopulate it, so that path cannot be revived — this was not a token lapse.

The file carries no reset timestamps. The **session** reset is therefore derived: the
five-hour window runs from your first message, which appears in the series as the most
recent transition from `fh == 0` to `fh > 0`. Measured across 41 windows in a real 30-day
series, the interval from that transition to the next drop clusters at 4.9–5.1h; the
outliers are sampling gaps (machine asleep), not a different window length.

It is accurate to about the sampling interval, so it is always rendered with a `≈` and the
dropdown states the tolerance. It is suppressed entirely when there is no active window,
when no transition is retained, or when the derived time is already past — a missed
boundary is better shown as nothing than as a stale time. The **weekly** reset is not
derivable this way and is not shown.

## Diagnosing

```bash
./.build/release/ClaudeUsageBar --doctor
```

Reports credential state (never any token material), whether the notch is
usable, the history totals and the activity socket. Two failure modes it exists
to name, because neither is obvious from the UI:

- **Repeated "wants to access key Claude Code-credentials" prompts.** Two causes,
  both fixed. With an expired token the credential cache was never populated, so
  every 5-minute poll performed a fresh secret read; and every rebuild changes the
  code identity, invalidating any "Always Allow". `Auth` now compares the item's
  modification date first — an attributes-only query that never prompts — and reads
  the secret only when something actually changed. On a machine with the plan-usage
  file, the keychain is not touched at all.
- **Notch mode is unavailable on a MacBook that has a notch.** A notched panel
  offers, for some widths, both a taller mode extending beside the notch and a
  shorter one below it. A mode with no taller sibling (e.g. 1920x1200 on an
  M2 Air) runs the menu bar below the notch, and `safeAreaInsets.top` reads 0.
  The menu item names the resolution to switch to rather than claiming there is
  no notch.
