# Acceptable use and service compatibility guidance

This file describes safe and compatible ways to operate Quota Pool with third-party services. It does **not** add to, modify, or terminate the copyright rights granted by [LICENSE](LICENSE). The project license is governed by `LICENSE`; external services remain subject to their own terms and policies.

## License scope

The source code is provided under PolyForm Noncommercial 1.0.0. Commercial use requires separate written permission from the copyright holder; see [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md).

## OpenAI / Codex accounts

Quota Pool is designed to talk to a Codex App Server that the user installed and signed in locally. When using OpenAI services:

- use only accounts and subscriptions you are authorized to use;
- do not share, lend, resell, or pool other people's subscriptions;
- do not turn this software into a subscription-to-API proxy, quota-sharing service, or rate-limit bypass;
- do not automatically switch accounts or otherwise configure multiple accounts to evade official usage limits;
- do not read, upload, or forward `~/.codex/auth.json`, OAuth tokens, passwords, refresh tokens, or session cookies;
- follow OpenAI's then-current Terms of Use, Service Terms, Usage Policies, and usage limits.

Quota Pool monitors independently configured local environments. It does not combine their quotas. The iPhone client can display saved rate-limit reset information but does not redeem those resets.

## Remote Session

Remote Session is not a read-only feature. For a paired device it can read/resume a Codex thread, start a turn, steer or interrupt a turn owned by Quota Pool, and respond to approval requests. Use these controls only on systems, projects, and accounts you are authorized to operate.

## Relay

- Host the relay yourself, or use a deployment you trust.
- Do not persist plaintext conversation bodies, source files, diffs, terminal output, credentials, or decrypted remote-session payloads on the relay.
- Public deployments must use HTTPS/WSS and should enforce origin checks, pairing throttles, and request rate limits.
- Do not put real credentials or unnecessary personal data in issues, screenshots, logs, fixtures, or demo content.

## Trademarks

Do not imply that Quota Pool is an official OpenAI product. Do not use OpenAI, ChatGPT, GPT, or Codex logos or brand assets except as permitted by the rights holder. Product names may be referenced only as needed to describe compatibility.
