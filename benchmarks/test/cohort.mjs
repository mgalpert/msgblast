import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { canonical, digest } from "./harness.mjs";
const original = JSON.parse(
  await readFile("test/fixtures/native-upload-v1.json", "utf8"),
);
export async function cohort(
  h,
  a,
  {
    fixture = false,
    gap = false,
    failed = false,
    unsupported = false,
    provider,
    transform,
    driveJobs = false,
  } = {},
) {
  const c = structuredClone(original);
  c.sessionID = crypto.randomUUID();
  c.id = crypto.randomUUID();
  for (const e of c.events) {
    e.comparisonID = c.sessionID;
    e.fixture = fixture;
    if (provider && e.agent) e.agent.provider = provider;
  }
  if (gap) {
    c.events[5].kind = "gap";
    c.events[5].reason = "sleep";
    delete c.events[5].selection;
  }
  if (failed) {
    c.events.splice(3, 3, {
      ...c.events[4],
      kind: "outcome",
      reason: "failed",
    });
  }
  if (unsupported) {
    c.events[3].stamp.clockID = "different-clock";
  }
  if (transform) transform(c);
  let previous;
  for (let i = 0; i < c.events.length; i++) {
    const e = c.events[i];
    e.sequence = i + 1;
    if (previous) e.previousHash = previous;
    else delete e.previousHash;
    previous = digest(canonical(e));
  }
  c.sequenceEnd = c.events.length;
  const r = await h.request(
    "/api/v1/sessions",
    "POST",
    {
      localID: c.sessionID,
      purpose: "contribution",
      consent: true,
      fixture,
      context: "fresh",
    },
    a,
  );
  assert.equal(r.status, 201);
  const s = await r.json();
  const bytes = canonical(c),
    d = digest(bytes);
  const upload = await h.mf.dispatchFetch(
    `http://localhost/api/v1/sessions/${s.id}/chunks`,
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${a}`,
        "content-type": "application/json",
      },
      body: bytes,
    },
  );
  assert.equal(upload.status, 201, await upload.clone().text());
  assert.equal(
    (
      await h.request(
        `/api/v1/sessions/${s.id}/finalize`,
        "POST",
        { sequenceEnd: c.sequenceEnd, hash: d },
        a,
      )
    ).status,
    202,
  );
  if (driveJobs) {
    const { processJob } = await import("../dist/support/jobs.mjs");
    const j = await h.db
      .prepare('SELECT id FROM outbox WHERE kind="validate" AND target=?')
      .bind(s.id)
      .first();
    await processJob(await h.mf.getBindings("benchmarks-fixture"), j.id);
  }
  // Wait for actual local Queue delivery; no direct invocation or fabricated validation rows.
  for (let i = 0; i < 100; i++) {
    const r = await h.request(
      `/api/v1/sessions/${s.id}/validation`,
      "GET",
      undefined,
      a,
    );
    const v = await r.json();
    if (v.completeness) return { s, v };
    await new Promise((r) => setTimeout(r, 50));
  }
  throw Error("Local queue did not validate");
}
