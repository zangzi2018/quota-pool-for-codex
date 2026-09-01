# Privacy

Quota Pool is a personal, self-hosted console for Codex account state and paired Remote Session control. It is not an official OpenAI product.

## Local data

- The iPhone app may cache device snapshots, account email/display data, quotas, activity, aliases, relay settings, usage history, and session metadata.
- The macOS and Windows companions store local profile configuration, the latest snapshot, usage history, device identifiers, and pairing state.
- Login credentials remain under the locally installed Codex App Server. Quota Pool does not read or upload `~/.codex/auth.json`.
- Pairing tokens and private pairing keys use platform secure storage (Keychain on Apple platforms; DPAPI/ProtectedData on Windows).

A fresh installation contains no bundled accounts, sessions, transcripts, relay addresses, or maintainer-specific state. Pair a desktop companion to load your own live state.

## Relay data

The relay may persist pairing/device metadata, public keys, hashed device tokens, encrypted snapshots, and presence information. Pending encrypted command envelopes may also be retained until delivered or expired. The relay must not persist OAuth tokens, passwords, `auth.json`, private pairing keys, source files, diffs, terminal transcripts, or plaintext conversation bodies.

Account fingerprints are SHA-256 hashes of email addresses. Decrypted snapshots can still contain the account email because the client displays it; that plaintext is available on the paired endpoints after decryption.

## Remote Session content

Remote Session can transmit conversation text, command text, approval details, plan/status updates, and related session events between a paired iPhone and desktop companion. The companion encrypts these payloads with the pairing key before sending them to the relay, and the paired endpoint decrypts them locally. The relay receives ciphertext plus the routing metadata required to deliver it.

Reference-relay remote-event ciphertext is kept in memory and removed after about five minutes. Operators should still account for reverse-proxy, operating-system, infrastructure, and access logs in their own deployment. Public deployments must use HTTPS/WSS and appropriate rate limits and pairing throttles.

## Network and telemetry

The application connects to relay addresses configured by the user and to the locally installed Codex App Server. The current source tree does not include advertising or analytics telemetry. A self-hosted relay or reverse proxy may have its own logging configuration, which is the operator's responsibility.

For security reports, follow [SECURITY.md](SECURITY.md). Do not paste real credentials, conversation contents, or unnecessary personal data into public issues.
