# Quota Pool v0.2.0

Security hardening for the self-hosted relay and client URL policy. OpenAI credentials still stay on the host running the local Codex App Server. Snapshots, remote commands, and Remote Session bodies remain end-to-end encrypted with the pairing key.

## Security fixes

- The relay no longer treats a spoofed `Host: 127.0.0.1` (or other private-looking Host header) as proof that a public cleartext connection is local. Loopback binds still reject DNS-rebinding Host headers. LAN cleartext requires both the bound address and Host to be trusted. Reverse-proxy backends reject direct cleartext unless `X-Forwarded-Proto: https` is present.
- Pairing recovery (`/v1/devices/:id/recover`) is limited to the local loopback desktop. Forwarded headers, `RELAY_BEHIND_PROXY`, and `RELAY_TRUST_PROXY` disable it. Public deployments should persist ciphertext with `RELAY_STATE_PATH` instead of exposing recovery.
- IPv6 unique-local matching no longer treats every address whose text starts with `fc` or `fd` as private. Clients and the relay now use prefix `fc00::/7` (and mapped IPv4 where applicable).
- Device identifiers are restricted to a safe character set so they cannot smuggle extra path segments. Command list responses no longer include internal routing fields.
- Pending pairing sessions are capped, recovery is rate-limited, and rate-limit cleanup no longer evicts longer pairing windows early.
- The relay container runs as the non-root `node` user.

## Compatibility

- Pairing, snapshot sync, and Remote Session behavior are unchanged for a local `http://127.0.0.1` relay and for HTTPS public relays.
- A companion that relied on recovery after a public relay lost in-memory state should set `RELAY_STATE_PATH` or re-pair.

See `SECURITY.md` and `relay/.env.example` for deployment requirements.
