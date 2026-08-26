# ClaudeUsage

A lightweight macOS menu bar app that keeps an eye on your [Claude Code](https://claude.ai/code) usage limits — right in the menu bar, with no browser tab and no manual sign-in.

## Features

- **Menu bar display** of whichever limit is currently most pressing (5-hour or weekly window), shown as either a percentage or a pace (consumption rate relative to time elapsed in the window)
- **Popover** with a detailed view of both usage windows (5 hours / 7 days), including progress bars, reset time, and a pace marker
- **Color-coded warning levels** (green/yellow/orange/red) based on utilization or pace — see [How do the warning colors work?](#how-do-the-warning-colors-work)
- **Automatic refresh** every 2 minutes (less often when rate-limited)
- Toggleable: colored or monochrome menu bar icon, and percentage or pace display

## Requirements

- macOS
- A working [Claude Code](https://claude.ai/code) sign-in — either the standalone Claude Code CLI (`claude` in Terminal) **or** Claude's coding agent integration set up inside Xcode. Either one works, since both store their credentials the same way (see below).

## Installation

1. Open the project in Xcode (`ClaudeUsage.xcodeproj`)
2. Build & Run (⌘R)
3. The app appears as an icon in the menu bar — no Dock icon, no window

## How does the credential handoff work?

ClaudeUsage never asks you for an API key, and it doesn't store one itself. Instead, it borrows the credentials that Claude Code already places in the macOS Keychain when you sign in — whether that sign-in happened via the standalone CLI or via Claude's coding agent set up inside Xcode, since both use the same underlying Claude Code login flow and Keychain item.

1. **Claude Code stores its OAuth token in the Keychain.** Once you sign in — either by running `claude login` in Terminal, or by setting up Claude's coding agent in Xcode and authenticating through it — Claude Code creates a generic password item in your login Keychain whose service name starts with `Claude Code-credentials`. Its value is a JSON blob containing `accessToken`, `refreshToken`, and `expiresAt`.

2. **ClaudeUsage looks up that item on launch and on every refresh.** In [`KeychainCredentialReader.swift`](ClaudeUsage/ClaudeUsage/KeychainCredentialReader.swift), the app searches the Keychain for an entry with that service prefix, reads its data, and decodes the `accessToken` from it.

3. **The token is only ever used in memory.** In [`ClaudeUsageClient.swift`](ClaudeUsage/ClaudeUsage/ClaudeUsageClient.swift), it's sent as an `Authorization: Bearer <token>` header to `https://api.anthropic.com/api/oauth/usage` to fetch the current usage data. ClaudeUsage never persists the token itself — it's re-read from the Keychain fresh on every request.

4. **macOS asks for permission on first access.** Since the Keychain item was originally created by Claude Code (the CLI or the Xcode integration), macOS shows a system dialog the first time ClaudeUsage tries to read it ("ClaudeUsage wants to access data in your keychain"). You'll need to click **"Allow"** (or "Always Allow") once for the app to read the token.

If no matching Keychain item is found — for example, if you've never signed in to Claude Code — the app shows an error message in the popover asking you to sign in once, either via the CLI or via Claude's coding agent in Xcode.

## How do the warning colors work?

Both the menu bar icon/text and the popover derive their colors from the same thresholds, defined in [`UsageLevel.swift`](ClaudeUsage/ClaudeUsage/UsageLevel.swift):

| Level | Utilization (percentage mode) | Pace (pace mode) | Color |
| --- | --- | --- | --- |
| Normal | < 50% | < 1.0 | green |
| Elevated | 50–80% | 1.0–1.5 | yellow |
| High | 80–90% | 1.5–2.0 | orange |
| Critical | ≥ 90% | ≥ 2.0 | red |

A pace of `1.0` means usage is tracking exactly with the time elapsed in the window (it'll land at ~100% right at reset) — that's the "on schedule" baseline, not yet a concern, so the elevated/high/critical bands only start above it.

**25% floor for pace colors — menu bar only.** Pace is a ratio, so right after a window resets, tiny amounts of usage over a tiny amount of elapsed time can produce wild swings — e.g. using just 2% in the first minute of a 5-hour window already reads as "way over pace". Flashing a loud warning color in the menu bar for that would be more alarming than useful, so there the pace-based color only appears once utilization in that window reaches **25%**; below that, the icon/text stay neutral (no tint) no matter how extreme the pace ratio looks. The pace *number* itself is still shown — only its color is suppressed. The popover isn't as "in your face", so it always shows the real pace color, even below 25%.

The menu bar icon additionally treats "Normal"/green as neutral (no tint at all) rather than drawing it in green, so the icon only calls attention to itself once something is actually elevated, high, or critical. The popover shows the real green so you can see at a glance that a window is healthy.

## Privacy

- ClaudeUsage only talks to `api.anthropic.com`, and only to fetch your own usage data.
- The app doesn't store or transmit your credentials anywhere itself.
- All settings (icon color, displayed metric) are stored locally in `UserDefaults`.
