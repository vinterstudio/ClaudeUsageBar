# ClaudeUsageBar

A native macOS menu bar app that shows your **Claude Code session usage percentage** — with zero model tokens consumed while running.

![Menu bar showing CC 7%](https://img.shields.io/badge/menu%20bar-CC%207%25-blue)

## What it does

- Displays your 5-hour session usage (e.g. `CC 42%`) in the menu bar
- Shows all usage windows (5h / 7d) with reset times in 24-hour clock
- Polls every 60 seconds — no dock icon, runs silently in the background

**Token cost: zero.** The app reads the OAuth usage metadata endpoint — it never sends a prompt to a model.

## Requirements

- macOS 13 (Ventura) or later
- A [Claude](https://claude.ai) account with Claude Code installed and signed in
- Xcode Command Line Tools: `xcode-select --install`

## Install

```bash
git clone https://github.com/andreasvesterlund/ClaudeUsageBar.git
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

Claude Code stores your OAuth credentials in the macOS login Keychain under the item `Claude Code-credentials`. ClaudeUsageBar reads that same item (using the Security framework — no shell calls), refreshes the token when expired, and calls:

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
| `Session (5h): 42% used` | Primary window utilization |
| `5h 42%  ·  7d 12%   (resets 14:30, in 1h 12m)` | All windows + 24h reset time |
| `Updated 14:28:01` | Last successful poll |
| Refresh Now | Poll immediately |
| Reveal Raw Response | Opens `~/Library/Logs/ClaudeUsageBar/last-usage-response.json` in Finder |
| Quit | Exit |

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
