import http from "node:http";
import https from "node:https";
import fs from "node:fs";
import { isIP } from "node:net";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { RelayStore } from "./store.mjs";

const { WebSocket, WebSocketServer } = createRequire(import.meta.url)("../vendor/ws/index.js");

class ClientError extends Error {
  constructor(message, status = 400) {
    super(message);
    this.status = status;
    this.expose = true;
  }
}

export const store = new RelayStore({ persistencePath: process.env.RELAY_STATE_PATH });
const sockets = { companion: new Map(), controller: new Map() };
const rateBuckets = new Map();

export const parseHostHeader = value => {
  if (!value) return "";
  if (value.startsWith("[")) {
    const end = value.indexOf("]");
    return end >= 0 ? value.slice(1, end).toLowerCase() : "";
  }
  return String(value).split(":")[0].toLowerCase();
};

const isPrivateOrLoopbackIPv4 = octets => {
  if (octets[0] === 127) return true;
  if (octets[0] === 10) return true;
  if (octets[0] === 192 && octets[1] === 168) return true;
  if (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) return true;
  if (octets[0] === 169 && octets[1] === 254) return true;
  return false;
};

export const isTrustedCleartextHost = host => {
  const hostname = parseHostHeader(host);
  if (!hostname) return false;
  if (hostname === "localhost" || hostname === "localhost.localdomain") return true;
  if (hostname.endsWith(".localhost") || hostname.endsWith(".local")) return true;
  const version = isIP(hostname);
  if (version === 4) return isPrivateOrLoopbackIPv4(hostname.split(".").map(Number));
  if (version === 6) {
    const mapped = hostname.startsWith("::ffff:") ? hostname.slice(7) : "";
    if (mapped && isIP(mapped) === 4) return isPrivateOrLoopbackIPv4(mapped.split(".").map(Number));
    if (hostname === "::1") return true;
    if (hostname.startsWith("fe80:")) return true;
    if (hostname.startsWith("fc") || hostname.startsWith("fd")) return true;
  }
  return false;
};

const loopbackBind = () => ["127.0.0.1", "::1", "localhost"].includes(process.env.HOST ?? "127.0.0.1");
const requestIsEncrypted = req => Boolean(req.socket?.encrypted)
  || (process.env.RELAY_BEHIND_PROXY === "1" && (req.headers["x-forwarded-proto"] ?? "").split(",")[0].trim() === "https");

const allowRate = (key, limit, windowMs) => {
  const now = Date.now();
  const hits = (rateBuckets.get(key) ?? []).filter(time => now - time < windowMs);
  if (hits.length >= limit) { rateBuckets.set(key, hits); return false; }
  hits.push(now);
  rateBuckets.set(key, hits);
  if (rateBuckets.size > 8_000) {
    for (const [entry, times] of rateBuckets) {
      const fresh = times.filter(time => now - time < windowMs);
      if (fresh.length) rateBuckets.set(entry, fresh);
      else rateBuckets.delete(entry);
    }
  }
  return true;
};

const clientKey = req => {
  if (process.env.RELAY_TRUST_PROXY === "1") {
    return req.headers["x-forwarded-for"]?.split(",")[0]?.trim() || req.socket.remoteAddress || "unknown";
  }
  return req.socket.remoteAddress || "unknown";
};

const originAllowed = req => {
  const expected = process.env.RELAY_ORIGIN;
  if (!expected) return true;
  const origin = req.headers.origin;
  return !origin || origin === expected;
};

const hostAllowed = req => {
  const expected = process.env.RELAY_ORIGIN;
  if (!expected) return true;
  try {
    return parseHostHeader(req.headers.host) === parseHostHeader(new URL(expected).host);
  } catch {
    return false;
  }
};

const securityHeaders = (req, extra = {}) => {
  const headers = {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store, no-cache, must-revalidate, private",
    pragma: "no-cache",
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY",
    "referrer-policy": "no-referrer",
    "content-security-policy": "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
    "x-permitted-cross-domain-policies": "none",
    "cross-origin-resource-policy": "same-origin",
    "permissions-policy": "camera=(), microphone=(), geolocation=()",
    ...extra
  };
  if (requestIsEncrypted(req) || process.env.RELAY_BEHIND_PROXY === "1") {
    headers["strict-transport-security"] = "max-age=63072000; includeSubDomains";
  }
  return headers;
};

const decodeBase64 = value => {
  try {
    const decoded = Buffer.from(value, "base64");
    return decoded.length && value.replace(/\s/g, "") ? decoded : null;
  } catch {
    return null;
  }
};

export const isP256PublicKey = value => {
  if (typeof value !== "string" || value.length > 120) return false;
  const decoded = decodeBase64(value);
  return Boolean(decoded && decoded.length === 65 && decoded[0] === 4);
};

export const isEnvelope = value => {
  if (!value || value.version !== 1) return false;
  if (typeof value.nonce !== "string" || typeof value.ciphertext !== "string" || typeof value.tag !== "string") return false;
  const nonce = decodeBase64(value.nonce);
  const tag = decodeBase64(value.tag);
  const ciphertext = decodeBase64(value.ciphertext);
  if (!nonce || nonce.length !== 12 || !tag || tag.length !== 16 || !ciphertext) return false;
  if (ciphertext.length > 900_000) return false;
  if (value.accounts != null || value.email != null || value.text != null || value.items != null) return false;
  return true;
};

const hasOnlyKeys = (value, allowed) => value && typeof value === "object" && !Array.isArray(value)
  && Object.keys(value).every(key => allowed.includes(key));

const boundedText = (value, min, max) => typeof value === "string" && value.length >= min && value.length <= max;

const json = (res, status, body) => {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, securityHeaders(res.req, { "content-length": String(data.length) }));
  res.end(data);
};

const body = (req, limit = 1_000_000) => new Promise((resolve, reject) => {
  const chunks = []; let size = 0;
  req.on("data", chunk => {
    size += chunk.length;
    if (size > limit) {
      req.destroy();
      reject(new ClientError("Request too large"));
    } else chunks.push(chunk);
  });
  req.on("end", () => {
    try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks)) : {}); }
    catch { reject(new ClientError("Invalid request format")); }
  });
  req.on("error", () => reject(new ClientError("Invalid request")));
});

const bearer = req => req.headers.authorization?.match(/^Bearer ([A-Za-z0-9_-]+)$/)?.[1];
const isLocalPeer = req => req.socket.remoteAddress === req.socket.localAddress;
const pairingAuth = req => req.headers["x-pairing-auth"];
const desktopProofHeader = req => req.headers["x-desktop-proof"];

const denyPublicCleartext = req => {
  if (requestIsEncrypted(req)) return false;
  const host = parseHostHeader(req.headers.host) || (req.socket.localAddress ?? "");
  return !isTrustedCleartextHost(host);
};

const socketSet = (role, deviceId) => {
  const values = sockets[role].get(deviceId) ?? new Set();
  sockets[role].set(deviceId, values);
  return values;
};
const push = (role, deviceId, value) => {
  const payload = JSON.stringify(value);
  for (const socket of socketSet(role, deviceId)) {
    if (socket.readyState === WebSocket.OPEN) socket.send(payload);
  }
};

export const configureWebSockets = server => {
  const wss = new WebSocketServer({ noServer: true, maxPayload: 1_000_000 });
  server.on("upgrade", (req, socket, head) => {
    try {
      if (denyPublicCleartext(req) || !originAllowed(req) || !hostAllowed(req)) {
        socket.write("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      if (!allowRate(`ws:${clientKey(req)}`, 30, 60_000)) {
        socket.write("HTTP/1.1 429 Too Many Requests\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      const url = new URL(req.url, "http://relay.local");
      const match = url.pathname.match(/^\/v1\/devices\/([^/]+)\/stream$/);
      const role = url.searchParams.get("role");
      const deviceId = match?.[1];
      if (!deviceId || !["companion", "controller"].includes(role) || !store.authorized(deviceId, bearer(req))) {
        socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      wss.handleUpgrade(req, socket, head, ws => attachSocket(ws, role, deviceId));
    } catch { socket.destroy(); }
  });
  server.once("close", () => {
    for (const role of Object.keys(sockets)) {
      for (const values of sockets[role].values()) for (const socket of values) socket.terminate();
      sockets[role].clear();
    }
    wss.close();
  });
  return server;
};

const attachSocket = (ws, role, deviceId) => {
  socketSet(role, deviceId).add(ws);
  if (role === "companion") store.connectPresence(deviceId);
  ws.send(JSON.stringify({ type: "connected", role, deviceId, presence: store.presence(deviceId) }));
  if (role === "companion") for (const command of store.commands(deviceId)) ws.send(JSON.stringify({ type: "command", command }));
  ws.on("message", raw => {
    try {
      if (typeof raw !== "string" && !Buffer.isBuffer(raw)) return;
      const text = String(raw);
      if (text.length > 4_096) {
        if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: "error", message: "Message too large" }));
        return;
      }
      const message = JSON.parse(text);
      if (role === "companion" && message.type === "heartbeat" && message.text == null && message.items == null && message.approval == null) {
        const presence = store.heartbeat(deviceId);
        ws.send(JSON.stringify({ type: "heartbeatAck", presence }));
        push("controller", deviceId, { type: "presence", presence });
      }
    } catch {
      if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: "error", message: "Invalid message format" }));
    }
  });
  let didDisconnect = false;
  const disconnected = () => {
    if (didDisconnect) return;
    didDisconnect = true;
    socketSet(role, deviceId).delete(ws);
    if (role === "companion" && socketSet(role, deviceId).size === 0) {
      const presence = store.disconnectPresence(deviceId);
      push("controller", deviceId, { type: "presence", presence });
    }
  };
  ws.once("close", disconnected);
  ws.once("error", disconnected);
};

const deviceRate = (req, deviceId) => allowRate(`device:${deviceId}:${clientKey(req)}`, 240, 60_000);

export const handler = async (req, res) => {
  try {
    if (req.method === "TRACE" || req.method === "TRACK") return json(res, 405, { error: "Method not allowed" });
    if (!originAllowed(req) || !hostAllowed(req)) return json(res, 403, { error: "Origin not allowed" });
    const url = new URL(req.url, "http://relay.local");
    if (url.pathname.length > 512) return json(res, 414, { error: "Path too long" });
    if (denyPublicCleartext(req) && url.pathname !== "/healthz") return json(res, 400, { error: "Public relays must use HTTPS" });
    const parts = url.pathname.split("/").filter(Boolean);

    if (req.method === "GET" && url.pathname === "/healthz") return json(res, 200, { ok: true });

    if (req.method === "POST" && url.pathname === "/v1/pairings") {
      if (!allowRate(`pair:${clientKey(req)}`, 10, 10 * 60_000)) return json(res, 429, { error: "Pairing request rate limited" });
      const value = await body(req, 16_384);
      if (!hasOnlyKeys(value, ["phonePublicKey", "phoneName", "authHash"])) return json(res, 400, { error: "Missing pairing data" });
      if (!isP256PublicKey(value.phonePublicKey) || typeof value.phoneName !== "string" || !boundedText(value.phoneName.trim(), 1, 128)) return json(res, 400, { error: "Missing pairing data" });
      const authDigest = decodeBase64(value.authHash);
      if (!authDigest || authDigest.length !== 32) return json(res, 400, { error: "Missing pairing data" });
      const p = store.createPairing(value.phonePublicKey, value.phoneName.trim(), value.authHash);
      return json(res, 201, { sessionId: p.id, code: p.code, expiresAt: p.expiresAt });
    }

    if (req.method === "GET" && parts[0] === "v1" && parts[1] === "pairings" && parts.length === 3) {
      if (!/^\d{6}$/.test(parts[2])) return json(res, 404, { error: "Pairing not found or expired" });
      if (!allowRate(`lookup:${clientKey(req)}`, 20, 10 * 60_000)) return json(res, 429, { error: "Pairing lookup rate limited" });
      const p = store.byCode(parts[2]);
      return p ? json(res, 200, p) : json(res, 404, { error: "Pairing not found or expired" });
    }

    if (req.method === "PUT" && parts[0] === "v1" && parts[1] === "pairings" && parts[3] === "claim") {
      if (!allowRate(`claim:${clientKey(req)}`, 10, 10 * 60_000)) return json(res, 429, { error: "Pairing claim rate limited" });
      const value = await body(req, 16_384);
      if (!/^\d{6}$/.test(parts[2]) || !hasOnlyKeys(value, ["desktopPublicKey", "desktopProof", "device"])) {
        return json(res, 400, { error: "Invalid desktop pairing data" });
      }
      if (!isP256PublicKey(value.desktopPublicKey) || !boundedText(value.desktopProof, 32, 128)) return json(res, 400, { error: "Invalid desktop pairing data" });
      const device = value.device;
      if (!hasOnlyKeys(device, ["id", "name", "platform", "osVersion", "codexVersion", "onlineState", "lastSeenAt"])
        || !boundedText(device.id, 1, 128) || !boundedText(device.name, 1, 128)) {
        return json(res, 400, { error: "Invalid desktop pairing data" });
      }
      try {
        const p = store.claim(parts[2], { desktopPublicKey: value.desktopPublicKey, desktopProof: value.desktopProof, device: value.device });
        return p ? json(res, 200, p) : json(res, 404, { error: "Pairing not found or expired" });
      } catch (error) {
        if (error.message === "Pairing code already claimed") return json(res, 409, { error: "Pairing code already claimed" });
        throw error;
      }
    }

    if (req.method === "GET" && parts[0] === "v1" && parts[1] === "pairings" && parts[3] === "status") {
      if (!allowRate(`status:${clientKey(req)}`, 180, 10 * 60_000)) return json(res, 429, { error: "Pairing lookup rate limited" });
      const session = store.byId(parts[2]);
      if (!session) return json(res, 404, { error: "Pairing not found or expired" });
      if (store.phoneAuthorized(session, pairingAuth(req))) return json(res, 200, store.statusForPhone(session));
      if (store.desktopAuthorized(session, desktopProofHeader(req))) return json(res, 200, store.statusForDesktop(session));
      return json(res, 401, { error: "Unauthorized" });
    }

    if (req.method === "PUT" && parts[0] === "v1" && parts[1] === "pairings" && parts[3] === "confirm") {
      if (!allowRate(`confirm:${clientKey(req)}`, 20, 10 * 60_000)) return json(res, 429, { error: "Pairing confirm rate limited" });
      const session = store.byId(parts[2]);
      if (!session) return json(res, 404, { error: "Pairing not found or expired" });
      if (!store.phoneAuthorized(session, pairingAuth(req))) return json(res, 401, { error: "Unauthorized" });
      const value = await body(req, 16_384);
      if (!hasOnlyKeys(value, ["phoneProof"]) || !boundedText(value.phoneProof, 32, 128)) return json(res, 400, { error: "Invalid iPhone pairing proof" });
      const p = store.confirm(parts[2], value.phoneProof);
      return p ? json(res, 200, p) : json(res, 409, { error: "Invalid pairing state" });
    }

    if (req.method === "PUT" && parts[0] === "v1" && parts[1] === "devices" && parts[3] === "recover") {
      if (!loopbackBind() || !isLocalPeer(req)) return json(res, 403, { error: "Pairing recovery is allowed only from this desktop" });
      const value = await body(req, 4_096);
      if (!hasOnlyKeys(value, ["token"]) || !boundedText(value.token, 20, 256)) return json(res, 400, { error: "Invalid recovery data" });
      return store.recoverDevice(parts[2], value.token) ? json(res, 201, { ok: true }) : json(res, 409, { error: "Device already exists or recovery data is invalid" });
    }

    if (parts[0] === "v1" && parts[1] === "devices" && parts[3] === "snapshot") {
      const deviceId = parts[2];
      if (!store.authorized(deviceId, bearer(req))) return json(res, 401, { error: "Unauthorized" });
      if (!deviceRate(req, deviceId)) return json(res, 429, { error: "Too many requests" });
      if (req.method === "PUT") {
        const value = await body(req);
        if (!hasOnlyKeys(value, ["version", "nonce", "ciphertext", "tag", "observedAt"]) || !isEnvelope(value) || typeof value.observedAt !== "string") {
          return json(res, 400, { error: "Invalid snapshot envelope" });
        }
        store.saveSnapshot(deviceId, { version: value.version, nonce: value.nonce, ciphertext: value.ciphertext, tag: value.tag, observedAt: value.observedAt });
        return json(res, 204, {});
      }
      if (req.method === "GET") { const value = store.snapshot(deviceId); return value ? json(res, 200, value) : json(res, 404, { error: "No snapshot" }); }
    }

    if (req.method === "GET" && parts[0] === "v1" && parts[1] === "devices" && parts[3] === "presence") {
      const deviceId = parts[2];
      if (!store.authorized(deviceId, bearer(req))) return json(res, 401, { error: "Unauthorized" });
      if (!deviceRate(req, deviceId)) return json(res, 429, { error: "Too many requests" });
      return json(res, 200, store.presence(deviceId));
    }

    if (parts[0] === "v1" && parts[1] === "devices" && parts[3] === "commands") {
      const deviceId = parts[2];
      if (!store.authorized(deviceId, bearer(req))) return json(res, 401, { error: "Unauthorized" });
      if (!deviceRate(req, deviceId)) return json(res, 429, { error: "Too many requests" });
      if (req.method === "POST" && parts.length === 4) {
        const value = await body(req);
        if (value.text != null || value.items != null || value.approval != null || value.sessionKey != null) {
          return json(res, 400, { error: "Remote commands must be end-to-end encrypted" });
        }
        if (!hasOnlyKeys(value, ["id", "kind", "expiresAt", "envelope"])
          || !boundedText(value.id, 1, 128) || !boundedText(value.kind, 1, 64)
          || typeof value.expiresAt !== "string" || !isEnvelope(value.envelope)) {
          return json(res, 400, { error: "Invalid remote command envelope" });
        }
        const command = { id: value.id, kind: value.kind, expiresAt: value.expiresAt, envelope: value.envelope };
        try {
          if (store.enqueueCommand(deviceId, command)) push("companion", deviceId, { type: "command", command });
        } catch (error) {
          if (error.message === "Remote command expired" || error.message === "Invalid remote command") return json(res, 400, { error: error.message });
          throw error;
        }
        return json(res, 202, {});
      }
      if (req.method === "GET" && parts.length === 4) return json(res, 200, { commands: store.commands(deviceId) });
      if (req.method === "POST" && parts[4] && parts[5] === "ack") return store.acknowledgeCommand(deviceId, parts[4]) ? json(res, 204, {}) : json(res, 404, { error: "Command not found" });
    }

    if (parts[0] === "v1" && parts[1] === "devices" && parts[3] === "events") {
      const deviceId = parts[2];
      if (!store.authorized(deviceId, bearer(req))) return json(res, 401, { error: "Unauthorized" });
      if (!deviceRate(req, deviceId)) return json(res, 429, { error: "Too many requests" });
      if (req.method === "POST") {
        const value = await body(req);
        if (value.items != null || value.approval != null || value.capabilities != null || value.text != null) {
          return json(res, 400, { error: "Remote events must be end-to-end encrypted" });
        }
        if (!hasOnlyKeys(value, ["accountFingerprint", "threadId", "envelope"])
          || !boundedText(value.accountFingerprint, 1, 128) || !boundedText(value.threadId, 1, 128)
          || !isEnvelope(value.envelope)) {
          return json(res, 400, { error: "Invalid event envelope" });
        }
        const event = { accountFingerprint: value.accountFingerprint, threadId: value.threadId, envelope: value.envelope };
        const sequence = store.publishEvent(deviceId, event);
        push("controller", deviceId, { type: "event", event: { ...event, sequence, receivedAt: new Date().toISOString() } });
        return json(res, 204, {});
      }
      if (req.method === "GET") {
        const accountFingerprint = url.searchParams.get("accountFingerprint"), threadId = url.searchParams.get("threadId");
        if (!accountFingerprint || !threadId) return json(res, 400, { error: "Missing session identity" });
        if (accountFingerprint.length > 128 || threadId.length > 128) return json(res, 400, { error: "Missing session identity" });
        const afterText = url.searchParams.get("after") ?? "0";
        const after = Number(afterText);
        if (!Number.isSafeInteger(after) || after < 0) return json(res, 400, { error: "Invalid event cursor" });
        const events = store.events(deviceId, accountFingerprint, threadId)
          .filter(event => event.sequence > after)
          .map(event => ({
            sequence: event.sequence,
            accountFingerprint: event.accountFingerprint,
            threadId: event.threadId,
            envelope: event.envelope
          }));
        return json(res, 200, { events, cursor: events.at(-1)?.sequence ?? after });
      }
    }
    return json(res, 404, { error: "Not found" });
  } catch (error) {
    if (error?.expose) return json(res, error.status ?? 400, { error: error.message });
    return json(res, 400, { error: "Invalid request" });
  }
};

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) {
  const port = Number(process.env.PORT ?? 8787);
  const host = process.env.HOST ?? "127.0.0.1";
  const certPath = process.env.TLS_CERT_PATH;
  const keyPath = process.env.TLS_KEY_PATH;
  const tls = Boolean(certPath && keyPath);
  if (!loopbackBind() && !tls && process.env.RELAY_BEHIND_PROXY !== "1" && process.env.RELAY_ALLOW_CLEARTEXT !== "1") {
    process.stderr.write("Quota Pool relay: refusing public HTTP bind without TLS. Set TLS_CERT_PATH/TLS_KEY_PATH, RELAY_BEHIND_PROXY=1, or RELAY_ALLOW_CLEARTEXT=1 for trusted LAN.\n");
    process.exit(1);
  }
  if (!loopbackBind() && !tls && !process.env.RELAY_ORIGIN && process.env.RELAY_ALLOW_CLEARTEXT !== "1") {
    process.stderr.write("Quota Pool relay: set RELAY_ORIGIN for non-loopback deployments.\n");
    process.exit(1);
  }
  const server = tls
    ? https.createServer({ cert: fs.readFileSync(certPath), key: fs.readFileSync(keyPath), minVersion: "TLSv1.2" }, handler)
    : http.createServer(handler);
  server.requestTimeout = 30_000;
  server.headersTimeout = 10_000;
  server.maxHeadersCount = 50;
  configureWebSockets(server);
  server.listen(port, host, () => {
    const scheme = server instanceof https.Server ? "https" : "http";
    process.stdout.write(`Quota Pool relay listening on ${scheme}://${host}:${port}\n`);
    if (!tls && !loopbackBind()) process.stderr.write("Warning: cleartext bind is only for a trusted reverse proxy.\n");
  });
}
