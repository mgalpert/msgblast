import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { harness, digest, canonical, publication } from "./harness.mjs";
const raw = await readFile("test/fixtures/native-upload-v1.json", "utf8");
const fixture = JSON.parse(raw);
const fixtureHash = (
  await readFile("test/fixtures/native-upload-v1.sha256", "utf8")
).trim();
async function register(h, a, localID = fixture.sessionID) {
  const r = await h.request(
    "/api/v1/sessions",
    "POST",
    {
      localID,
      purpose: "sync",
      consent: true,
      fixture: true,
      context: "unknown",
    },
    a,
  );
  assert.equal(r.status, 201, await r.clone().text());
  return r.json();
}
async function upload(h, a, sid, bytes = raw) {
  return h.mf.dispatchFetch(`http://localhost/api/v1/sessions/${sid}/chunks`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${a}`,
      "content-type": "application/json",
    },
    body: bytes,
  });
}
test("native-produced canonical bytes and pinned hash persist unchanged; retries and ownership are enforced", async () => {
  assert.equal(digest(raw), fixtureHash);
  assert.equal(canonical(fixture), raw);
  const h = await harness();
  try {
    const a = await h.token(),
      b = await h.token("bob"),
      s = await register(h, a);
    const first = await upload(h, a, s.id);
    assert.equal(first.status, 201, await first.clone().text());
    const receipt = await first.json();
    assert.equal(receipt.hash, fixtureHash);
    const retry = await upload(h, a, s.id);
    assert.equal(retry.status, 200);
    assert.deepEqual(await retry.json(), receipt);
    assert.equal((await upload(h, b, s.id)).status, 404);
    const changed = structuredClone(fixture);
    changed.events[1].text = "different";
    assert.equal((await upload(h, a, s.id, canonical(changed))).status, 409);
    assert.equal(
      (
        await h.request(
          `/api/v1/sessions/${s.id}/finalize`,
          "POST",
          { sequenceEnd: 6, hash: fixtureHash },
          a,
        )
      ).status,
      409,
    );
    assert.equal(
      (
        await h.request(
          `/api/v1/sessions/${s.id}/finalize`,
          "POST",
          { sequenceEnd: 7, hash: fixtureHash },
          a,
        )
      ).status,
      202,
    );
    assert.equal(
      (await h.request(`/api/v1/sessions/${s.id}`, "DELETE", undefined, a))
        .status,
      202,
    );
    assert.equal((await upload(h, a, s.id)).status, 404);
  } finally {
    await h.close();
  }
});
test("out-of-order, invalid event chain, oversized and compressed chunks never commit", async () => {
  const h = await harness();
  try {
    const a = await h.token(),
      s = await register(h, a);
    const wrong = structuredClone(fixture);
    wrong.sequenceStart = 2;
    assert.equal((await upload(h, a, s.id, canonical(wrong))).status, 409);
    wrong.sequenceStart = 1;
    wrong.events[2].previousHash = "0".repeat(64);
    assert.equal((await upload(h, a, s.id, canonical(wrong))).status, 400);
    assert.equal(
      (await upload(h, a, s.id, " ".repeat(1024 * 1024 + 1))).status,
      413,
    );
    const compressed = await h.mf.dispatchFetch(
      `http://localhost/api/v1/sessions/${s.id}/chunks`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${a}`,
          "content-type": "application/json",
          "content-encoding": "gzip",
        },
        body: "bad",
      },
    );
    assert.equal(compressed.status, 415);
    assert.equal(
      (await h.db.prepare("SELECT count(*) AS n FROM chunks").first()).n,
      0,
    );
  } finally {
    await h.close();
  }
});
test("R2 write followed by D1 rejection is reconciled by retry without a duplicate receipt", async () => {
  const h = await harness();
  try {
    const a = await h.token(),
      s = await register(h, a);
    const bucket = await h.mf.getR2Bucket("CONTENT");
    // Fault injection at the actual D1 boundary, with real local R2. No fake receipt or in-memory storage.
    await h.db
      .prepare(
        "CREATE TRIGGER injected_failure BEFORE INSERT ON chunks BEGIN SELECT RAISE(ABORT,'fixture_d1_failure'); END",
      )
      .run();
    assert.equal((await upload(h, a, s.id)).status, 503);
    assert.equal((await bucket.list()).objects.length, 1);
    assert.equal(
      (
        await h.request(
          `/api/v1/sessions/${s.id}/chunks/${fixture.id}`,
          "GET",
          undefined,
          a,
        )
      ).status,
      404,
    );
    await h.db.prepare("DROP TRIGGER injected_failure").run();
    assert.equal((await upload(h, a, s.id)).status, 201);
    assert.equal((await bucket.list()).objects.length, 1);
    assert.equal(
      (await h.db.prepare("SELECT count(*) AS n FROM chunks").first()).n,
      1,
    );
  } finally {
    await h.close();
  }
});
test("actual Swift recorder observationState bytes are accepted unchanged and durably receipted", async () => {
  const bytes = await readFile(
    "test/fixtures/native-observation-v1.json",
    "utf8",
  );
  const sha = (
    await readFile("test/fixtures/native-observation-v1.sha256", "utf8")
  ).trim();
  assert.equal(digest(bytes), sha);
  const c = JSON.parse(bytes);
  assert.ok(c.events.some((e) => e.kind === "observationState"));
  assert.ok(c.events.some((e) => e.reason === "generating"));
  assert.ok(c.events.some((e) => e.reason === "idle"));
  const h = await harness();
  try {
    const a = await h.token(),
      r = await h.request(
        "/api/v1/sessions",
        "POST",
        {
          localID: c.sessionID,
          purpose: "sync",
          consent: true,
          fixture: true,
          context: "unknown",
        },
        a,
      );
    assert.equal(r.status, 201);
    const s = await r.json();
    const sent = await upload(h, a, s.id, bytes);
    assert.equal(sent.status, 201, await sent.clone().text());
    assert.equal((await sent.json()).hash, sha);
  } finally {
    await h.close();
  }
});

test("business display snapshots survive exact private upload without accepting action targets", async () => {
  const h = await harness();
  try {
    const auth = await h.token(), session = await register(h, auth);
    const chunk = structuredClone(fixture);
    const reply = chunk.events.find(e => e.kind === "replyObserved");
    reply.businessChoices = {kind: "quickReply", title: "Choose", options: [{title: "Find Plumbers", selected: true}]};
    function bytes() {
      for (let i = 1; i < chunk.events.length; i++) chunk.events[i].previousHash = digest(canonical(chunk.events[i-1]));
      return canonical(chunk);
    }
    reply.businessChoices.actionURL = "https://example.com";
    assert.equal((await upload(h, auth, session.id, bytes())).status, 400);
    delete reply.businessChoices.actionURL;
    const card = reply.businessChoices;
    delete reply.businessChoices;
    const start = chunk.events.find(e => e.kind === "turnStarted");
    start.businessChoices = card;
    assert.equal((await upload(h, auth, session.id, bytes())).status, 400);
    delete start.businessChoices;
    reply.businessChoices = card;
    const raw = bytes(), accepted = await upload(h, auth, session.id, raw);
    assert.equal(accepted.status, 201, await accepted.clone().text());
    assert.equal((await accepted.json()).hash, digest(raw));
    assert.equal((await upload(h, auth, session.id, raw)).status, 200);
  } finally { await h.close(); }
});
