# Security

## Reporting

Use GitHub private vulnerability reporting for this repository when it is available. If that channel is unavailable, contact the repository owner through a private channel associated with their GitHub account. Do not disclose an unpatched vulnerability in a public issue.

A useful report includes:

- affected component (iOS / macOS Companion / Windows Companion / relay);
- a minimal reproduction that does not expose real credentials or personal data;
- impact (credential exposure, plaintext session data, pairing takeover, etc.).

Never attach `auth.json`, passwords, OAuth/session tokens, pairing tokens, private keys, or real conversation contents to a public report.

## Hard requirements

The following must never appear in Relay durable storage or in this repository:

- ChatGPT passwords;
- OAuth access or refresh tokens;
- `~/.codex/auth.json`;
- session cookies;
- private pairing keys;
- plaintext source files, diffs, terminal transcripts, or conversation bodies captured from Remote Session.

Snapshots, remote commands, and remote-session events that leave a host must be encrypted with the pairing key before they reach the relay. The relay may store ciphertext, public keys, hashed device tokens, presence, and bounded routing metadata only.

## Deployment checklist

- Bind the reference relay to loopback unless TLS is terminated in front.
- Set `RELAY_ORIGIN` on non-local deployments.
- When `RELAY_BEHIND_PROXY=1`, do not publish the relay port. Only the TLS proxy should be able to reach the process. Direct cleartext access to a proxy backend is rejected.
- `/v1/devices/:id/recover` is loopback-only, ignores forwarded headers, and is disabled behind a proxy. Public relays should persist state with `RELAY_STATE_PATH` instead of exposing recovery.
- Rotate pairing after a suspected pairing-code or device-token leak; six-digit codes are short-lived locators, not passwords.
- Clients refuse public `http://` relay URLs. LAN HTTP is allowed only for loopback, RFC1918, unique-local IPv6, link-local, and `.local` hosts. A spoofed `Host: 127.0.0.1` header does not make a public bind trusted.
- Pairing status and confirm require `X-Pairing-Auth` or `X-Desktop-Proof`. The six-digit lookup must not return `deviceToken`.
- Keep Codex, the operating system, dependencies, and this project updated.
- Keep the automated secret-scanning workflow enabled on public branches and pull requests.

## Known residual risks

- Six-digit pairing is brute-forceable without rate limits. The reference relay rate-limits lookups and claims and burns a code when it is claimed; operators must not disable equivalent protections.
- Account email addresses and session metadata exist in plaintext on paired endpoints after decryption because the UI needs to display them.
- Public deployments still require transport encryption. Use `TLS_CERT_PATH` / `TLS_KEY_PATH` or terminate HTTPS/WSS at a trusted reverse proxy.
- LAN HTTP remains available for trusted local networks. A local network attacker may observe transport metadata or device tokens if the LAN itself is hostile; snapshot and Remote Session bodies remain end-to-end encrypted.
- `RELAY_BEHIND_PROXY=1` trusts `X-Forwarded-Proto` from the immediate peer. If the backend port is reachable from the internet, an attacker can spoof that header. Bind the relay to loopback or firewall it so only the proxy can connect.
