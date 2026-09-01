import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash, randomBytes } from "node:crypto";
import { RelayStore } from "../src/store.mjs";
import http from "node:http";
import { createRequire } from "node:module";
import { configureWebSockets, handler } from "../src/server.mjs";

const { WebSocket } = createRequire(import.meta.url)("../vendor/ws/index.js");

const p256 = fill => Buffer.concat([Buffer.from([4]), Buffer.alloc(64, fill)]).toString("base64");
const envelope = (cipher = "cipher") => ({
  version: 1,
  nonce: Buffer.alloc(12, 7).toString("base64"),
  ciphertext: Buffer.from(cipher).toString("base64"),
  tag: Buffer.alloc(16, 9).toString("base64"),
  observedAt: new Date().toISOString()
});
const pairingSecret = () => {
  const auth = randomBytes(32).toString("hex");
  return { auth, authHash: createHash("sha256").update(auth).digest("base64") };
};
const request = async (origin, path, method = "GET", value, token, extraHeaders = {}) => {
  const response = await fetch(origin + path, {
    method,
    headers: {
      ...(value ? { "content-type": "application/json" } : {}),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...extraHeaders
    },
    body: value ? JSON.stringify(value) : undefined
  });
  const text = await response.text();
  return { status: response.status, headers: response.headers, body: text ? JSON.parse(text) : null };
};
const waitUntil = async (predicate, timeout = 2_000) => {
  const deadline = Date.now() + timeout;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error("Timed out waiting");
    await new Promise(resolve => setTimeout(resolve, 10));
  }
};
const startRelay = async () => {
  const server = configureWebSockets(http.createServer(handler));
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  return { server, origin, port: server.address().port };
};

test("six-digit pairing completes and protects encrypted snapshots", async () => {
  const { server, origin } = await startRelay();
  const secret = pairingSecret();
  try {
    const created = await request(origin, "/v1/pairings", "POST", { phonePublicKey: p256(1), phoneName: "My iPhone", authHash: secret.authHash });
    assert.match(created.body.code, /^\d{6}$/);
    assert.equal("deviceToken" in created.body, false);
    const lookedUp = await request(origin, `/v1/pairings/${created.body.code}`);
    assert.equal(lookedUp.status, 200);
    assert.equal("phoneName" in lookedUp.body, false, "code lookup must not return the iPhone name");
    assert.equal("deviceToken" in lookedUp.body, false);
    assert.equal("authHash" in lookedUp.body, false);
    const proof = "desktop-proof-placeholder-with-enough-length";
    const claimed = await request(origin, `/v1/pairings/${created.body.code}/claim`, "PUT", {
      desktopPublicKey: p256(2), desktopProof: proof, device: { id: "mac-1", name: "Mac", platform: "macOS" }
    });
    assert.equal(claimed.body.state, "claimed");
    assert.equal("deviceToken" in claimed.body, false);
    const reusedCode = await request(origin, `/v1/pairings/${created.body.code}`);
    assert.equal(reusedCode.status, 404, "six-digit code is destroyed immediately after claim");
    const unauthStatus = await request(origin, `/v1/pairings/${created.body.sessionId}/status`);
    assert.equal(unauthStatus.status, 401);
    assert.equal(unauthStatus.body.deviceToken, undefined);
    const uuidDump = await request(origin, `/v1/pairings/${created.body.sessionId}`);
    assert.equal(uuidDump.status, 404, "must not expose pairing secrets via UUID lookup");
    const phoneStatus = await request(origin, `/v1/pairings/${created.body.sessionId}/status`, "GET", undefined, undefined, { "x-pairing-auth": secret.auth });
    assert.equal(phoneStatus.status, 200);
    assert.equal(phoneStatus.body.state, "claimed");
    assert.equal("deviceToken" in phoneStatus.body, false);
    const confirmed = await request(origin, `/v1/pairings/${created.body.sessionId}/confirm`, "PUT", { phoneProof: "phone-proof-placeholder-with-enough-length" }, undefined, { "x-pairing-auth": secret.auth });
    assert.ok(confirmed.body.deviceToken);
    const stolenConfirm = await request(origin, `/v1/pairings/${created.body.sessionId}/confirm`, "PUT", { phoneProof: "phone-proof-placeholder-with-enough-length" });
    assert.equal(stolenConfirm.status, 401);
    const desktopStatus = await request(origin, `/v1/pairings/${created.body.sessionId}/status`, "GET", undefined, undefined, { "x-desktop-proof": proof });
    assert.equal(desktopStatus.status, 200);
    assert.equal(desktopStatus.body.deviceToken, confirmed.body.deviceToken);
    const unauthorized = await request(origin, "/v1/devices/mac-1/snapshot");
    assert.equal(unauthorized.status, 401);
    const snap = envelope();
    assert.equal((await request(origin, "/v1/devices/mac-1/snapshot", "PUT", snap, confirmed.body.deviceToken)).status, 204);
    assert.deepEqual((await request(origin, "/v1/devices/mac-1/snapshot", "GET", undefined, confirmed.body.deviceToken)).body, snap);
  } finally { server.close(); }
});

test("an observer with the six-digit code cannot obtain the device token", async () => {
  const { server, origin } = await startRelay();
  const secret = pairingSecret();
  try {
    const created = await request(origin, "/v1/pairings", "POST", { phonePublicKey: p256(1), phoneName: "iPhone", authHash: secret.authHash });
    const observer = await request(origin, `/v1/pairings/${created.body.code}`);
    const proof = "desktop-proof-placeholder-with-enough-length";
    await request(origin, `/v1/pairings/${created.body.code}/claim`, "PUT", {
      desktopPublicKey: p256(2), desktopProof: proof, device: { id: "mac-observer", name: "Mac" }
    });
    await request(origin, `/v1/pairings/${created.body.sessionId}/confirm`, "PUT", { phoneProof: "phone-proof-placeholder-with-enough-length" }, undefined, { "x-pairing-auth": secret.auth });
    const stolen = await request(origin, `/v1/pairings/${observer.body.id}/status`);
    assert.equal(stolen.status, 401);
    assert.equal(stolen.body?.deviceToken, undefined);
    const fakePhone = await request(origin, `/v1/pairings/${observer.body.id}/status`, "GET", undefined, undefined, { "x-pairing-auth": "0".repeat(64) });
    assert.equal(fakePhone.status, 401);
  } finally { server.close(); }
});

test("device authorization and snapshots survive relay restart", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "quota-pool-relay-"));
  const persistencePath = path.join(directory, "state.json");
  try {
    const first = new RelayStore({ persistencePath });
    const secret = pairingSecret();
    const pairing = first.createPairing(p256(1), "iPhone", secret.authHash);
    first.claim(pairing.code, { desktopPublicKey: p256(2), desktopProof: "proof-proof-proof-proof-proof-proof-12", device: { id: "mac-1", name: "Mac" } });
    const confirmed = first.confirm(pairing.id, "phone-proof-placeholder-with-enough-length");
    const snap = envelope();
    first.saveSnapshot("mac-1", snap);

    const restored = new RelayStore({ persistencePath });
    assert.equal(restored.authorized("mac-1", confirmed.deviceToken), true);
    assert.deepEqual(restored.snapshot("mac-1"), snap);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("desktop host can recover an existing pairing after relay state loss", async () => {
  const { server, origin } = await startRelay();
  try {
    const token = "existing-device-token-that-stays-in-keychain";
    assert.equal((await request(origin, "/v1/devices/mac-recover/recover", "PUT", { token })).status, 201);
    const snap = envelope();
    assert.equal((await request(origin, "/v1/devices/mac-recover/snapshot", "PUT", snap, token)).status, 204);
  } finally { server.close(); }
});

test("remote commands and session events stay in short-lived memory, not durable state", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "quota-pool-transient-"));
  const persistencePath = path.join(directory, "state.json");
  try {
    const first = new RelayStore({ persistencePath });
    const secret = pairingSecret();
    const pairing = first.createPairing(p256(1), "iPhone", secret.authHash);
    first.claim(pairing.code, { desktopPublicKey: p256(2), desktopProof: "proof-proof-proof-proof-proof-proof-12", device: { id: "mac-1", name: "Mac" } });
    first.confirm(pairing.id, "phone-proof-placeholder-with-enough-length");
    first.enqueueCommand("mac-1", { id: "cmd-1", kind: "read", expiresAt: new Date(Date.now() + 30_000).toISOString(), envelope: envelope() });
    first.publishEvent("mac-1", { accountFingerprint: "account-1", threadId: "thread-1", envelope: envelope() });
    assert.equal(first.commands("mac-1").length, 1);
    assert.equal(first.events("mac-1", "account-1", "thread-1").length, 1);
    const persisted = JSON.parse(fs.readFileSync(persistencePath, "utf8"));
    assert.equal("pendingCommands" in persisted, false);
    assert.equal("transientEvents" in persisted, false);
    const restored = new RelayStore({ persistencePath });
    assert.equal(restored.commands("mac-1").length, 0);
    assert.equal(restored.events("mac-1", "account-1", "thread-1").length, 0);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

test("session event cursor returns incremental envelopes only", () => {
  const relay = new RelayStore();
  relay.devices.set("mac-1", { tokenDigest: Buffer.alloc(32), snapshot: null });
  assert.equal(relay.publishEvent("mac-1", {
    accountFingerprint: "account-1", threadId: "thread-1",
    envelope: envelope("n1")
  }), 1);
  assert.equal(relay.publishEvent("mac-1", {
    accountFingerprint: "account-1", threadId: "thread-1",
    envelope: envelope("n2")
  }), 2);
  assert.deepEqual(relay.events("mac-1", "account-1", "thread-1", 1).map(event => event.sequence), [2]);
  assert.equal("items" in relay.events("mac-1", "account-1", "thread-1")[0], false);
});

test("presence maps heartbeat age to online/stale/offline", () => {
  const relay = new RelayStore();
  relay.devices.set("mac", { tokenDigest: Buffer.alloc(32), snapshot: null, presence: { state: "offline", lastSeen: null } });
  assert.equal(relay.connectPresence("mac").state, "online");
  relay.devices.get("mac").presence.lastSeen = new Date(Date.now() - 60_000).toISOString();
  assert.equal(relay.presence("mac").state, "stale");
  relay.devices.get("mac").presence.lastSeen = new Date(Date.now() - 121_000).toISOString();
  assert.equal(relay.presence("mac").state, "offline");
});

test("duplicate message ids are not queued again", () => {
  const relay = new RelayStore();
  relay.devices.set("mac", { tokenDigest: Buffer.alloc(32), snapshot: null, presence: { state: "offline", lastSeen: null } });
  const command = { id: "same", kind: "interrupt", expiresAt: new Date(Date.now() + 30_000).toISOString(), envelope: envelope() };
  assert.equal(relay.enqueueCommand("mac", command), true);
  assert.equal(relay.enqueueCommand("mac", command), false);
  assert.equal(relay.commands("mac").length, 1);
});

test("authenticated outbound WebSocket pushes commands and drives presence", async () => {
  const { server, origin, port } = await startRelay();
  const deviceId = `mac-wss-${Date.now()}`;
  const token = "websocket-device-token-that-stays-on-device";
  const received = [];
  let socket;
  try {
    assert.equal((await request(origin, `/v1/devices/${deviceId}/recover`, "PUT", { token })).status, 201);
    socket = new WebSocket(`ws://127.0.0.1:${port}/v1/devices/${deviceId}/stream?role=companion`, {
      headers: { Authorization: `Bearer ${token}` }
    });
    socket.on("message", data => received.push(String(data)));
    await waitUntil(() => received.some(item => item.includes("\"type\":\"connected\"")));
    assert.equal((await request(origin, `/v1/devices/${deviceId}/presence`, "GET", undefined, token)).body.state, "online");
    const command = { id: "wss-command", kind: "open", expiresAt: new Date(Date.now() + 30_000).toISOString(), envelope: envelope() };
    assert.equal((await request(origin, `/v1/devices/${deviceId}/commands`, "POST", command, token)).status, 202);
    await waitUntil(() => received.some(item => item.includes("wss-command")));
    assert.equal(received.join("").includes("\"text\""), false);
  } finally {
    socket?.terminate();
    await new Promise(resolve => server.close(resolve));
  }
});

test("reject plaintext remote commands, events, and snapshot smuggling", async () => {
  const { server, origin } = await startRelay();
  const token = "plaintext-rejection-token-value";
  try {
    assert.equal((await request(origin, "/v1/devices/mac-plain/recover", "PUT", { token })).status, 201);
    const command = await request(origin, "/v1/devices/mac-plain/commands", "POST", {
      id: "cmd", kind: "start", expiresAt: new Date(Date.now() + 30_000).toISOString(), text: "secret prompt", envelope: envelope()
    }, token);
    assert.equal(command.status, 400);
    const event = await request(origin, "/v1/devices/mac-plain/events", "POST", {
      accountFingerprint: "acc", threadId: "thread", items: [{ id: "i", text: "secret" }], envelope: envelope()
    }, token);
    assert.equal(event.status, 400);
    const snapshot = await request(origin, "/v1/devices/mac-plain/snapshot", "PUT", {
      ...envelope(), email: "user@example.com"
    }, token);
    assert.equal(snapshot.status, 400);
  } finally { server.close(); }
});

test("responses include no-store security headers and reject public cleartext Host", async () => {
  const { server, origin } = await startRelay();
  try {
    const health = await request(origin, "/healthz");
    assert.equal(health.status, 200);
    assert.equal(health.headers.get("x-content-type-options"), "nosniff");
    assert.equal(health.headers.get("x-frame-options"), "DENY");
    assert.match(health.headers.get("cache-control") ?? "", /no-store/);
    assert.equal(health.headers.get("referrer-policy"), "no-referrer");
    const denied = await new Promise((resolve, reject) => {
      const req = http.request({
        hostname: "127.0.0.1",
        port: new URL(origin).port,
        path: "/v1/pairings",
        method: "POST",
        headers: { host: "example.com", "content-type": "application/json" }
      }, res => {
        res.resume();
        res.on("end", () => resolve(res.statusCode));
      });
      req.on("error", reject);
      req.end(JSON.stringify({ phonePublicKey: p256(1), phoneName: "iPhone", authHash: pairingSecret().authHash }));
    });
    assert.equal(denied, 400);
  } finally { server.close(); }
});
