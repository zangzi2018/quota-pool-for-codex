# Quota Pool

A personal, self-hosted console for monitoring Codex account state and controlling remote Codex sessions across paired Mac and Windows hosts.

**License: PolyForm Noncommercial 1.0.0 (no commercial use).** This is a source-available release, not an OSI-approved open-source license. Do not use this project or a modified version of it in a commercial product, commercial service, paid distribution, or commercial internal operations without a written license. See [LICENSE](LICENSE), [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md), and [ACCEPTABLE_USE.md](ACCEPTABLE_USE.md).

> This is an independent project. It is not affiliated with, endorsed by, sponsored by, or approved by OpenAI. OpenAI, ChatGPT, GPT, Codex, and related marks belong to their respective owners and are referenced only to describe compatibility.
> Using Codex through this software remains subject to OpenAI's then-current terms, service terms, usage policies, and usage limits.
> Quota Pool monitors multiple locally configured Codex environments. It does **not** combine quotas, automatically switch accounts to evade usage limits, share or resell subscriptions, turn subscriptions into an API, or redeem saved rate-limit resets from the iPhone client.

- `ios/`: iOS 26 SwiftUI client
- `companions/macos/`: macOS 26 SwiftUI desktop companion
- `companions/windows/`: Windows 11 .NET 8 WPF desktop companion
- `relay/`: pairing and encrypted-snapshot relay

## What it can do

Quota and account-management surfaces are read-only. On a paired device, Remote Session can read and resume an existing Codex thread, start a turn, steer or interrupt a turn that Quota Pool owns, and respond to approval requests. These controls operate through the locally installed Codex App Server; Quota Pool does not read or copy `~/.codex/auth.json`.

## Quick start

1. On a Mac, install Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2. `cd ios && xcodegen generate`, then open the generated `CodexAccounts.xcodeproj`.
3. `cd companions/macos && xcodegen generate`, then open the generated `CodexAccountsCompanion.xcodeproj`.
4. On Windows, use Visual Studio 2026 or `dotnet build companions/windows/CodexAccounts.Companion.sln`.
5. Local relay: `cd relay && npm test && npm start`. Public deployments must use HTTPS/WSS (`TLS_CERT_PATH` / `TLS_KEY_PATH`, or TLS terminated by a reverse proxy) and set `RELAY_ORIGIN`. Binding `0.0.0.0` without TLS requires `RELAY_BEHIND_PROXY=1` or `RELAY_ALLOW_CLEARTEXT=1`. Clients reject public `http://` relay URLs. See `relay/.env.example`.

Before signing on an Apple device, choose your own Apple Developer team in Xcode and replace the placeholder Bundle IDs (`com.example.*`) if needed.

First launch is empty: there are no bundled accounts, sessions, transcripts, relay addresses, or maintainer-specific state. Open Settings → Privacy & Sync, enter your relay URL, then generate a 6-digit pairing code from Devices → Connect Device.

## Data boundary

OpenAI credentials stay with the host Codex App Server. The iPhone and desktop apps may store account email addresses, device information, quota/activity data, aliases, usage history, and session metadata locally. Pairing keys and device tokens use the platform secure store.

Snapshots, remote commands, and Remote Session content are encrypted with the pairing key before they reach the relay. Remote Session content can include conversation text, command text, approval details, and status updates; the relay receives ciphertext and routing metadata rather than that content in plaintext. See [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md).

For security reports, follow [SECURITY.md](SECURITY.md). Never put secrets, tokens, private keys, conversation contents, or personal data in a public issue.
