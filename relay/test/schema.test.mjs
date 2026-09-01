import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

test("shared snapshot schema keeps dynamic quotas and authoritative reset counts", () => {
  const schema = JSON.parse(fs.readFileSync(new URL("../../shared/snapshot.schema.json", import.meta.url)));
  assert.equal(schema.properties.schemaVersion.const, 1);
  assert.ok(schema.$defs.rateLimitWindow.properties.durationMins);
  assert.ok(schema.$defs.resetCreditSummary.required.includes("availableCount"));
  assert.equal(schema.$defs.resetCreditSummary.properties.credits.type.includes("null"), true);
  assert.ok(schema.properties.sessionSummaries);
  assert.ok(schema.properties.deviceUsageDays);
  assert.ok(schema.$defs.sessionKey.required.includes("accountFingerprint"));
  assert.ok(schema.$defs.tokenBreakdown.properties.reasoningTokens);
});
