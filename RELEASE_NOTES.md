# Quota Pool v0.1.0

The first tagged GitHub release of Quota Pool, a personal, self-hosted console for Codex workflows across paired Mac, Windows, and iPhone environments.

## Highlights

- Unified monitoring for Codex account state, 5-hour and weekly quota windows, reset timing, token usage, and recent activity.
- Cross-device session visibility with macOS and Windows companion apps plus an iOS client.
- Remote Session support for reading and resuming existing Codex threads, starting turns, steering or interrupting Quota Pool-owned turns, and responding to approval requests.
- Encrypted device pairing and relay transport designed to keep OpenAI credentials on the host running the local Codex App Server.
- Self-hostable relay with HTTPS/WSS requirements for public deployments.
- Security-focused repository setup including Gitleaks and TruffleHog full-history scanning.
- Explicit capability boundaries: Quota Pool does not combine quotas, automatically rotate accounts to evade usage limits, resell subscriptions, or expose subscriptions as an API.

## Licensing

Starting with v0.1.0, Quota Pool is open-source software licensed under the GNU Affero General Public License v3.0 (`AGPL-3.0-only`). Commercial use is permitted under the AGPL when its terms are followed. Separate commercial licensing is available for organizations that need proprietary terms incompatible with the AGPL.

See `README.md`, `LICENSE`, `COMMERCIAL-LICENSE.md`, `PRIVACY.md`, and `SECURITY.md` for details.
