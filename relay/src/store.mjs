import { createHash, randomBytes, randomInt, randomUUID, timingSafeEqual } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const digest = value => createHash("sha256").update(value).digest();
const sameToken = (plain, storedDigest) => {
  if (!plain || !storedDigest) return false;
  const candidate = digest(plain);
  return candidate.length === storedDigest.length && timingSafeEqual(candidate, storedDigest);
};

const deviceView = device => device ? { id: device.id, name: device.name, platform: device.platform ?? undefined, osVersion: device.osVersion ?? undefined } : undefined;

export class RelayStore {
  constructor({ pairingTtlMs = 5 * 60_000, persistencePath } = {}) {
    this.pairingTtlMs = pairingTtlMs;
    this.persistencePath = persistencePath;
    this.pairingsByCode = new Map();
    this.pairingsById = new Map();
    this.devices = new Map();
    this.pendingCommands = new Map();
    this.transientEvents = new Map();
    this.nextEventSequence = new Map();
    this.#restore();
  }

  createPairing(phonePublicKey, phoneName, authHash) {
    this.cleanup();
    const authDigest = Buffer.from(authHash, "base64");
    if (authDigest.length !== 32) throw new Error("Invalid pairing credential");
    let code;
    do code = String(randomInt(0, 1_000_000)).padStart(6, "0");
    while (this.pairingsByCode.has(code));
    const session = {
      id: randomUUID(),
      code,
      phonePublicKey,
      authDigest,
      expiresAt: new Date(Date.now() + this.pairingTtlMs).toISOString(),
      state: "waiting"
    };
    this.pairingsByCode.set(code, session);
    this.pairingsById.set(session.id, session);
    return { id: session.id, code: session.code, expiresAt: session.expiresAt };
  }

  byCode(code) {
    this.cleanup();
    const session = this.pairingsByCode.get(code);
    if (!session || session.state !== "waiting") return null;
    return { id: session.id, state: session.state, expiresAt: session.expiresAt, phonePublicKey: session.phonePublicKey };
  }

  byId(id) {
    this.cleanup();
    return this.pairingsById.get(id) ?? null;
  }

  phoneAuthorized(session, pairingAuth) {
    return Boolean(session && pairingAuth && sameToken(pairingAuth, session.authDigest));
  }

  desktopAuthorized(session, desktopProof) {
    return Boolean(session && desktopProof && session.desktopProofDigest && sameToken(desktopProof, session.desktopProofDigest));
  }

  statusForPhone(session) {
    if (!session) return null;
    if (session.state === "claimed") {
      return {
        id: session.id,
        state: session.state,
        expiresAt: session.expiresAt,
        desktopPublicKey: session.desktopPublicKey,
        desktopProof: session.desktopProof,
        device: deviceView(session.device)
      };
    }
    if (session.state === "confirmed") {
      return { id: session.id, state: session.state, expiresAt: session.expiresAt, deviceToken: session.deviceToken };
    }
    return { id: session.id, state: session.state, expiresAt: session.expiresAt };
  }

  statusForDesktop(session) {
    if (!session) return null;
    if (session.state === "confirmed") {
      return {
        id: session.id,
        state: session.state,
        expiresAt: session.expiresAt,
        phoneProof: session.phoneProof,
        deviceToken: session.deviceToken
      };
    }
    return { id: session.id, state: session.state, expiresAt: session.expiresAt };
  }

  claim(code, claim) {
    const session = this.pairingsByCode.get(code);
    if (!session || Date.parse(session.expiresAt) <= Date.now()) return null;
    if (session.state !== "waiting") throw new Error("Pairing code already claimed");
    session.desktopPublicKey = claim.desktopPublicKey;
    session.desktopProof = claim.desktopProof;
    session.desktopProofDigest = digest(claim.desktopProof);
    session.device = {
      id: claim.device.id,
      name: claim.device.name,
      platform: claim.device.platform,
      osVersion: claim.device.osVersion
    };
    session.state = "claimed";
    this.pairingsByCode.delete(code);
    delete session.code;
    return { id: session.id, state: session.state, expiresAt: session.expiresAt };
  }

  confirm(id, phoneProof) {
    const session = this.pairingsById.get(id);
    if (!session || session.state !== "claimed") return null;
    const deviceToken = randomBytes(32).toString("base64url");
    session.phoneProof = phoneProof;
    session.state = "confirmed";
    session.confirmedAt = new Date().toISOString();
    session.deviceToken = deviceToken;
    delete session.desktopProof;
    this.devices.set(session.device.id, { tokenDigest: digest(deviceToken), snapshot: null, presence: { state: "offline", lastSeen: null } });
    this.#persist();
    return { id: session.id, state: session.state, expiresAt: session.expiresAt, deviceToken };
  }

  authorized(deviceId, token) {
    const device = this.devices.get(deviceId);
    return Boolean(device && token && sameToken(token, device.tokenDigest));
  }

  recoverDevice(deviceId, token) {
    if (this.devices.has(deviceId) || typeof token !== "string" || token.length < 20) return false;
    this.devices.set(deviceId, { tokenDigest: digest(token), snapshot: null, presence: { state: "offline", lastSeen: null } });
    this.#persist();
    return true;
  }

  saveSnapshot(deviceId, envelope) {
    const device = this.devices.get(deviceId);
    device.snapshot = structuredClone(envelope);
    device.presence = { state: "online", lastSeen: new Date().toISOString() };
    this.#persist();
  }
  snapshot(deviceId) { return structuredClone(this.devices.get(deviceId)?.snapshot ?? null); }

  connectPresence(deviceId) {
    const device = this.devices.get(deviceId);
    if (!device) return null;
    device.presence = { state: "online", lastSeen: new Date().toISOString() };
    this.#persist();
    return structuredClone(device.presence);
  }

  heartbeat(deviceId) { return this.connectPresence(deviceId); }

  disconnectPresence(deviceId) {
    const device = this.devices.get(deviceId);
    if (!device) return null;
    device.presence = { state: "offline", lastSeen: new Date().toISOString() };
    this.#persist();
    return structuredClone(device.presence);
  }

  presence(deviceId) {
    const value = this.devices.get(deviceId)?.presence ?? { state: "offline", lastSeen: null };
    if (value.state === "online" && value.lastSeen) {
      const age = Date.now() - Date.parse(value.lastSeen);
      if (age > 120_000) return { ...structuredClone(value), state: "offline" };
      if (age > 45_000) return { ...structuredClone(value), state: "stale" };
    }
    return structuredClone(value);
  }

  enqueueCommand(deviceId, command) {
    this.cleanup();
    if (!this.devices.has(deviceId) || !command?.id || !command?.kind || !command?.expiresAt) throw new Error("Invalid remote command");
    const expires = Date.parse(command.expiresAt);
    if (!Number.isFinite(expires) || expires <= Date.now()) throw new Error("Remote command expired");
    if (this.pendingCommands.has(command.id)) return false;
    this.pendingCommands.set(command.id, { ...structuredClone(command), targetDeviceId: deviceId, status: "pending" });
    return true;
  }

  commands(deviceId) {
    this.cleanup();
    return [...this.pendingCommands.values()].filter(value => value.targetDeviceId === deviceId && value.status === "pending").map(value => structuredClone(value));
  }

  acknowledgeCommand(deviceId, commandId) {
    const value = this.pendingCommands.get(commandId);
    if (!value || value.targetDeviceId !== deviceId) return false;
    value.status = "delivered";
    value.deliveredAt = new Date().toISOString();
    return true;
  }

  publishEvent(deviceId, event) {
    this.cleanup();
    const key = `${deviceId}:${event.accountFingerprint}:${event.threadId}`;
    const values = this.transientEvents.get(key) ?? [];
    const sequence = this.nextEventSequence.get(key) ?? 1;
    this.nextEventSequence.set(key, sequence + 1);
    values.push({ ...structuredClone(event), sequence, receivedAt: new Date().toISOString() });
    this.transientEvents.set(key, values.slice(-500));
    return sequence;
  }

  events(deviceId, accountFingerprint, threadId, after = 0) {
    this.cleanup();
    const key = `${deviceId}:${accountFingerprint}:${threadId}`;
    return structuredClone((this.transientEvents.get(key) ?? []).filter(event => event.sequence > after));
  }

  cleanup() {
    const now = Date.now();
    for (const [id, command] of this.pendingCommands) {
      if (Date.parse(command.expiresAt) <= now || (command.deliveredAt && Date.parse(command.deliveredAt) + 60_000 <= now)) this.pendingCommands.delete(id);
    }
    for (const [key, events] of this.transientEvents) {
      const fresh = events.filter(event => Date.parse(event.receivedAt) + 5 * 60_000 > now);
      if (fresh.length) this.transientEvents.set(key, fresh);
      else {
        this.transientEvents.delete(key);
        this.nextEventSequence.delete(key);
      }
    }
    for (const session of this.pairingsById.values()) {
      const confirmedExpired = session.confirmedAt && Date.parse(session.confirmedAt) + 10 * 60_000 <= now;
      if ((Date.parse(session.expiresAt) <= now && session.state !== "confirmed") || confirmedExpired) {
        this.pairingsById.delete(session.id);
        if (session.code) this.pairingsByCode.delete(session.code);
      }
    }
  }

  #restore() {
    if (!this.persistencePath) return;
    try {
      const value = JSON.parse(fs.readFileSync(this.persistencePath, "utf8"));
      for (const [id, device] of Object.entries(value.devices ?? {})) {
        this.devices.set(id, { tokenDigest: Buffer.from(device.tokenDigest, "base64"), snapshot: device.snapshot ?? null, presence: device.presence ?? { state: "offline", lastSeen: null } });
      }
    } catch (error) {
      if (error.code !== "ENOENT") process.stderr.write(`Ignoring unreadable relay state: ${error.message}\n`);
    }
  }

  #persist() {
    if (!this.persistencePath) return;
    const devices = Object.fromEntries([...this.devices].map(([id, device]) => [id, {
      tokenDigest: device.tokenDigest.toString("base64"), snapshot: device.snapshot, presence: device.presence
    }]));
    fs.mkdirSync(path.dirname(this.persistencePath), { recursive: true });
    const temporary = `${this.persistencePath}.tmp`;
    fs.writeFileSync(temporary, JSON.stringify({ version: 1, devices }), { mode: 0o600 });
    fs.renameSync(temporary, this.persistencePath);
  }
}
