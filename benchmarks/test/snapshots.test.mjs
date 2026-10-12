import { test } from "node:test";
import assert from "node:assert/strict";
import { harness, canonical, digest, publication } from "./harness.mjs";
import { cohort } from "./cohort.mjs";
async function waitValidation(h, a, sid, head) {
  for (let i = 0; i < 100; i++) {
    const v = await h
      .request(
        `/api/v1/sessions/${sid}/snapshots/${head}/validation`,
        "GET",
        undefined,
        a,
      )
      .then((r) => r.json());
    if (v.completeness) return v;
    await new Promise((r) => setTimeout(r, 30));
  }
  throw Error("Snapshot queue validation absent");
}
test("explicit continuation retains native chains, freezes contribution and public bytes, and survives request retries", async () => {
  const h = await harness();
  try {
    const a = await h.token(),
      x = await cohort(h, a);
    const path = `/api/v1/sessions/${x.s.id}`;
    const heads = await h
      .request(path + "/snapshots", "GET", undefined, a)
      .then((r) => r.json());
    const first = heads[0];
    const pub = await publication(h, a, undefined, x.s.id).then((r) =>
      r.json(),
    );
    const publicBytes = await h
      .request(pub.path + "/data")
      .then((r) => r.text());
    assert.equal(
      (
        await h.request(
          path + "/contribution",
          "POST",
          { consent: true, revision: 1, snapshotID: first.snapshotID },
          a,
        )
      ).status,
      202,
    );
    const next = {
      consent: true,
      requestID: "resume-fixture-1",
      parentHash: first.hash,
      parentSequenceEnd: first.sequenceEnd,
    };
    assert.equal(
      (
        await h.request(
          path + "/revisions",
          "POST",
          { ...next, parentHash: "0".repeat(64) },
          a,
        )
      ).status,
      409,
    );
    const opened = await h
      .request(path + "/revisions", "POST", next, a)
      .then((r) => r.json());
    assert.equal(opened.revision, 2);
    const duringContinuation = await h
      .request(path + "/validation", "GET", undefined, a)
      .then((r) => r.json());
    assert.equal(duringContinuation.snapshot, first.snapshotID);
    assert.equal(duringContinuation.metrics.preferences.favorite, 1);
    assert.deepEqual(
      await h
        .request(path + "/revisions", "POST", next, a)
        .then((r) => r.json()),
      opened,
    );
    const receipt = await h.db
      .prepare(
        "SELECT * FROM chunks WHERE session=? ORDER BY end_sequence DESC LIMIT 1",
      )
      .bind(x.s.id)
      .first();
    const old = await (
      await (await h.mf.getR2Bucket("CONTENT")).get(receipt.object_key)
    ).json();
    const last = old.events.at(-1);
    const reply = old.events.find((e) => e.kind === "replyObserved");
    const event = {
      ...reply,
      id: crypto.randomUUID(),
      kind: "feedback",
      sequence: first.sequenceEnd + 1,
      previousHash: digest(canonical(last)),
      selection: "negative",
    };
    const chunk = {
      schemaVersion: 1,
      id: crypto.randomUUID(),
      sessionID: old.sessionID,
      sequenceStart: event.sequence,
      sequenceEnd: event.sequence,
      previousHash: first.hash,
      events: [event],
      artifacts: [],
    };
    const bytes = canonical(chunk);
    const upload = () =>
      h.mf.dispatchFetch("http://localhost" + path + "/revisions/2/chunks", {
        method: "POST",
        headers: {
          authorization: "Bearer " + a,
          "content-type": "application/json",
        },
        body: bytes,
      });
    assert.equal((await upload()).status, 201);
    assert.equal((await upload()).status, 200);
    assert.equal(
      (
        await h.request(
          path + "/revisions/1/finalize",
          "POST",
          { sequenceEnd: first.sequenceEnd, hash: first.hash },
          a,
        )
      ).status,
      202,
    );
    const second = await h
      .request(
        path + "/revisions/2/finalize",
        "POST",
        { sequenceEnd: event.sequence, hash: digest(bytes) },
        a,
      )
      .then((r) => r.json());
    assert.ok(second.snapshotID);
    const v2 = await waitValidation(h, a, x.s.id, second.snapshotID);
    assert.equal(v2.metrics.preferences.negative, 1);
    assert.equal(
      (await waitValidation(h, a, x.s.id, first.snapshotID)).metrics.preferences
        .favorite,
      1,
    );
    let stats = await h
      .request("/api/v1/statistics", "GET", undefined, a)
      .then((r) => r.json());
    assert.equal(stats.sessions, 1);
    assert.equal(stats.preferences.favorite, 1);
    assert.equal(stats.preferences.negative, 0);
    assert.equal(
      await h.request(pub.path + "/data").then((r) => r.text()),
      publicBytes,
    );
    assert.equal(
      (
        await h.request(
          path + "/contribution",
          "POST",
          { consent: true, revision: 1, snapshotID: second.snapshotID },
          a,
        )
      ).status,
      409,
    );
    assert.equal(
      (
        await h.request(
          path + "/contribution",
          "POST",
          { consent: true, revision: 2 },
          a,
        )
      ).status,
      409,
    );
    assert.equal(
      (
        await h.request(
          path + "/contribution",
          "POST",
          { consent: true, revision: 2, snapshotID: second.snapshotID },
          a,
        )
      ).status,
      202,
    );
    stats = await h
      .request("/api/v1/statistics", "GET", undefined, a)
      .then((r) => r.json());
    assert.equal(stats.sessions, 1);
    assert.equal(stats.preferences.negative, 1);
    assert.equal(stats.preferences.favorite, 0);
    assert.equal((await upload()).status, 200);
    await h.request(path, "DELETE", undefined, a);
    assert.equal(
      (await h.request(path + "/revisions", "POST", next, a)).status,
      404,
    );
    assert.equal((await h.request(pub.path)).status, 404);
    const { processJob } = await import("../dist/support/jobs.mjs");
    const deletion = await h.db
      .prepare("SELECT id FROM outbox WHERE kind='deleteSession' AND target=?")
      .bind(x.s.id)
      .first();
    await processJob(await h.mf.getBindings("benchmarks-fixture"), deletion.id);
    for (const table of [
      "snapshot_validations",
      "snapshots",
      "session_revisions",
      "legacy_feedback_baselines",
    ]) {
      const row = await h.db
        .prepare(`SELECT count(*) AS n FROM ${table}`)
        .first();
      assert.equal(row.n, 0, table + " retains private session data");
    }
  } finally {
    await h.close();
  }
});

test("unknown publication scope and streamed revisions require exact preview opt-in and stay escaped", async () => {
  const h = await harness();
  try {
    const a = await h.token();
    const { projection } = await import("./harness.mjs");
    const p = structuredClone(projection);
    p.turns[0].scope = "unknown";
    p.turns[0].kind = "unknown";
    assert.equal((await publication(h, a, p)).status, 400);
    p.includesUnknown = true;
    p.turns[0].replies[0].messages[0].revisions = [
      {
        text: "<script>attack()</script>\n  indentation",
        timingLabel: "Earlier locally observed text; completion unknown",
      },
    ];
    const created = await publication(h, a, p);
    assert.equal(created.status, 201);
    const link = await created.json();
    const html = await h.request(link.path).then((r) => r.text());
    assert.match(html, /earlier observed streaming revisions/);
    assert.match(html, /&lt;script&gt;attack/);
    assert.ok(!html.includes("<script>attack"));
    p.turns[0].kind = "initial";
    assert.equal((await publication(h, a, p)).status, 400);
    p.turns[0].kind = "unknown";
    p.turns[0].replies[0].messages[0].revisions = Array(201).fill({
      text: "x",
      timingLabel: "unknown",
    });
    assert.equal((await publication(h, a, p)).status, 400);
  } finally {
    await h.close();
  }
});

test("authoritative cancellation observation is accepted in the native hash chain", async () => {
  const h = await harness();
  try {
    const a = await h.token();
    const x = await cohort(h, a, {
      transform: (c) =>
        c.events.splice(-1, 0, {
          ...c.events[3],
          id: crypto.randomUUID(),
          kind: "observationState",
          reason: "cancellation-requested",
        }),
    });
    assert.equal(x.v.metrics.samples.length, 1);
  } finally {
    await h.close();
  }
});

test("migration pins existing finalized head and resumes its pending validation job", async () => {
  const { readFile } = await import("node:fs/promises");
  const c = JSON.parse(
    await readFile("test/fixtures/native-upload-v1.json", "utf8"),
  );
  const bytes = canonical(c),
    hash = digest(bytes),
    owner = digest("https://fixture.invalid/\0alice");
  const sid = "migrated-session";
  const h = await harness({
    queueDelay: 30,
    beforeMigration: async (file, db, mf) => {
      if (file !== "0002_snapshots.sql") return;
      await db
        .prepare("INSERT INTO accounts(id,issuer,subject) VALUES(?,?,?)")
        .bind(owner, "https://fixture.invalid/", "alice")
        .run();
      await db
        .prepare(
          "INSERT INTO sessions(id,owner,local_id,purpose,fixture,context,created_at) VALUES(?,?,?,'sync',1,'fresh',?)",
        )
        .bind(sid, owner, c.sessionID, new Date().toISOString())
        .run();
      await (
        await mf.getR2Bucket("CONTENT")
      ).put("sessions/" + sid + "/old", bytes);
      await db
        .prepare(
          "INSERT INTO chunks(session,id,start_sequence,end_sequence,hash,previous_hash,object_key,bytes,received_at) VALUES(?,?,?,?,?,?,?,?,?)",
        )
        .bind(
          sid,
          c.id,
          c.sequenceStart,
          c.sequenceEnd,
          hash,
          "",
          "sessions/" + sid + "/old",
          bytes.length,
          new Date().toISOString(),
        )
        .run();
      await db
        .prepare("UPDATE sessions SET status='finalized' WHERE id=?")
        .bind(sid)
        .run();
      await db
        .prepare(
          "INSERT INTO outbox(id,kind,target,created_at) VALUES('migration-job','validate',?,?)",
        )
        .bind(sid, new Date().toISOString())
        .run();
    },
  });
  try {
    const a = await h.token();
    const job = await h.db
      .prepare("SELECT target FROM outbox WHERE id='migration-job'")
      .first();
    assert.equal(job.target, sid + "-initial");
    const { processJob } = await import("../dist/support/jobs.mjs");
    await processJob(
      await h.mf.getBindings("benchmarks-fixture"),
      "migration-job",
    );
    const v = await waitValidation(h, a, sid, sid + "-initial");
    assert.equal(v.completeness, "complete");
    assert.equal(
      (
        await h.request(
          `/api/v1/sessions/${sid}/contribution`,
          "POST",
          { consent: true, revision: 1 },
          a,
        )
      ).status,
      202,
    );
    const history = await h
      .request("/api/v1/contributions", "GET", undefined, a)
      .then((r) => r.json());
    assert.equal(history.history[0].snapshotID, sid + "-initial");
  } finally {
    await h.close();
  }
});

test("derived storage budget blocks new validation truthfully and resumes after capacity is restored", async () => {
  const h = await harness({ queueDelay: 30 });
  try {
    const a = await h.token(),
      x = await cohort(h, a, { driveJobs: true });
    const first = await h.db
      .prepare("SELECT id FROM snapshots WHERE session=?")
      .bind(x.s.id)
      .first();
    // Synthetic quota occupation in actual local D1, not a fabricated validation result for the new session.
    await h.db
      .prepare("UPDATE snapshot_validations SET metrics=? WHERE snapshot=?")
      .bind(JSON.stringify({ padding: "x".repeat(1572864) }), first.id)
      .run();
    for (let i = 2; i <= 11; i++) {
      const id = "quota-fixture-" + i;
      await h.db
        .prepare(
          "INSERT INTO snapshots(id,session,revision,sequence_end,hash,created_at) SELECT ?,session,?,sequence_end,hash,created_at FROM snapshots WHERE id=?",
        )
        .bind(id, i, first.id)
        .run();
      await h.db
        .prepare(
          "INSERT INTO snapshot_validations SELECT ?,completeness,eligible,reasons,'{}',validated_at FROM snapshot_validations WHERE snapshot=?",
        )
        .bind(id, first.id)
        .run();
      await h.db
        .prepare("UPDATE snapshot_validations SET metrics=? WHERE snapshot=?")
        .bind(JSON.stringify({ padding: "x".repeat(1572864) }), id)
        .run();
    }
    const next = await cohort(h, a, {
      driveJobs: true,
      expectValidationBlocked: true,
    });
    assert.equal(next.v.status, "blocked");
    assert.equal(next.v.blocked_reason, "validation_storage_quota");
    const head = await h.db
      .prepare("SELECT id FROM snapshots WHERE session=?")
      .bind(next.s.id)
      .first();
    const blocked = await h
      .request(
        `/api/v1/sessions/${next.s.id}/snapshots/${head.id}/validation`,
        "GET",
        undefined,
        a,
      )
      .then((r) => r.json());
    assert.equal(blocked.status, "blocked");
    await h.request(
      `/api/v1/sessions/${next.s.id}/contribution`,
      "POST",
      { consent: true, revision: 1, snapshotID: head.id },
      a,
    );
    const history = await h
      .request("/api/v1/contributions", "GET", undefined, a)
      .then((r) => r.json());
    assert.equal(history.history[0].status, "blocked");
    assert.equal(history.acceptedDistinctSessions, 0);
    await h.db
      .prepare("UPDATE snapshot_validations SET metrics=? WHERE snapshot=?")
      .bind(JSON.stringify(x.v.metrics), first.id)
      .run();
    const { reconcile, processJob } = await import("../dist/support/jobs.mjs");
    const env = await h.mf.getBindings("benchmarks-fixture");
    await h.db
      .prepare(
        "DELETE FROM snapshot_validations WHERE snapshot LIKE 'quota-fixture-%'",
      )
      .run();
    await reconcile(env);
    const job = await h.db
      .prepare(
        "SELECT id,blocked_reason FROM outbox WHERE kind='validate' AND target=?",
      )
      .bind(head.id)
      .first();
    assert.equal(job.blocked_reason, null);
    await processJob(env, job.id);
    assert.equal((await waitValidation(h, a, next.s.id, head.id)).eligible, 1);
  } finally {
    await h.close();
  }
});
