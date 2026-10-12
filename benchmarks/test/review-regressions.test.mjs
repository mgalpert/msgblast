import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { harness, canonical, digest, publication } from "./harness.mjs";
import { cohort } from "./cohort.mjs";
import { processJob } from "../dist/support/jobs.mjs";
async function waitFor(check) {
  for (let i = 0; i < 100; i++) {
    const value = await check();
    if (value) return value;
    await new Promise((r) => setTimeout(r, 50));
  }
  throw Error("Local job did not reach expected state");
}
async function native(h, a, name) {
  const bytes = await readFile(`test/fixtures/${name}.json`, "utf8"),
    c = JSON.parse(bytes);
  const r = await h.request(
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
  const sent = await h.mf.dispatchFetch(
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
  assert.equal(sent.status, 201, await sent.clone().text());
  assert.equal((await sent.json()).hash, digest(bytes));
  await h.request(
    `/api/v1/sessions/${s.id}/finalize`,
    "POST",
    { sequenceEnd: c.sequenceEnd, hash: digest(bytes) },
    a,
  );
  return {
    s,
    v: await waitFor(async () => {
      const v = await h
        .request(`/api/v1/sessions/${s.id}/validation`, "GET", undefined, a)
        .then((r) => r.json());
      return v.completeness ? v : null;
    }),
  };
}
test("native reply-feedback-reply bytes preserve favorite; provider bytes retain three instance samples", async () => {
  const h = await harness();
  try {
    const a = await h.token(),
      pref = await native(h, a, "native-preference-v1");
    assert.equal(pref.v.metrics.preferences.favorite, 1);
    assert.equal(pref.v.metrics.preferences.rated, 1);
    const p = await native(h, a, "native-providers-v1");
    assert.equal(p.v.metrics.samples.length, 3);
    assert.equal(new Set(p.v.metrics.samples.map((s) => s.agent)).size, 3);
    assert.deepEqual(
      new Set(p.v.metrics.samples.map((s) => s.provider)),
      new Set(["chatgpt", "claude"]),
    );
    assert.ok(p.v.metrics.samples.every((s) => s.model === null));
    const all = await native(h, a, "native-all-events-v1");
    assert.equal(all.v.completeness, "partial");
    assert.ok(all.v.reasons.includes("recording-gap"));
  } finally {
    await h.close();
  }
});
test("old validation completing last cannot overwrite newer actual Queue result", async () => {
  const h = await harness();
  let release;
  try {
    const a = await h.token(),
      x = await cohort(h, a);
    const job = await h.db
      .prepare(
        'SELECT id,generation FROM outbox WHERE kind="validate" AND target IN(SELECT id FROM snapshots WHERE session=?)',
      )
      .bind(x.s.id)
      .first();
    await h.db
      .prepare("UPDATE outbox SET completed_at=NULL WHERE id=?")
      .bind(job.id)
      .run();
    let arrived;
    const entered = new Promise((r) => (arrived = r)),
      barrier = new Promise((r) => (release = r));
    const bindings = await h.mf.getBindings("benchmarks-fixture");
    const wrap = (stmt) =>
      new Proxy(stmt, {
        get(target, key) {
          if (key === "bind") return (...args) => wrap(target.bind(...args));
          if (key === "run")
            return async () => {
              arrived();
              await barrier;
              return target.run();
            };
          const value = Reflect.get(target, key);
          return typeof value === "function" ? value.bind(target) : value;
        },
      });
    const pausedDB = new Proxy(h.db, {
      get(target, key) {
        if (key === "prepare")
          return (sql) => {
            const stmt = target.prepare(sql);
            return sql.startsWith("INSERT OR IGNORE INTO snapshot_validations")
              ? wrap(stmt)
              : stmt;
          };
        const value = Reflect.get(target, key);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
    const old = processJob({ ...bindings, DB: pausedDB }, job.id);
    await entered;
    await h.db
      .prepare("UPDATE outbox SET generation=generation+1 WHERE id=?")
      .bind(job.id)
      .run();
    await processJob(bindings, job.id);
    release();
    await old;
    const v = await h
      .request(`/api/v1/sessions/${x.s.id}/validation`, "GET", undefined, a)
      .then((r) => r.json());
    assert.equal(v.metrics.preferences.negative, 0);
    assert.equal(v.metrics.preferences.favorite, 1);
  } finally {
    release?.();
    await h.close();
  }
});
test("elapsed intervals inspect each pair and preserve null across an intervening gap", async () => {
  const h = await harness();
  try {
    const a = await h.token();
    const after = await cohort(h, a, {
      transform(c) {
        const r = {
          ...structuredClone(c.events[3]),
          id: "extra-reply",
          messageID: "reply-2",
        };
        r.stamp.monotonicMS = 2500;
        c.events.splice(
          5,
          0,
          {
            ...structuredClone(c.events[0]),
            id: "gap-after",
            kind: "gap",
            reason: "sleep",
            stamp: { ...c.events[0].stamp, monotonicMS: 2100 },
          },
          r,
        );
      },
    });
    assert.deepEqual(after.v.metrics.samples[0].additionalReplyMS, [null]);
    const before = await cohort(h, a, {
      transform(c) {
        const r = {
          ...structuredClone(c.events[3]),
          id: "extra-reply",
          messageID: "reply-2",
        };
        r.stamp.monotonicMS = 1850;
        c.events.splice(4, 0, r);
        c.events.splice(3, 0, {
          ...structuredClone(c.events[0]),
          id: "gap-before",
          kind: "gap",
          reason: "sleep",
          stamp: { ...c.events[0].stamp, monotonicMS: 1600 },
        });
      },
    });
    assert.equal(before.v.metrics.samples[0].firstReplyMS, null);
    assert.deepEqual(before.v.metrics.samples[0].additionalReplyMS, [100]);
  } finally {
    await h.close();
  }
});
test("same-provider failures retain denominator and distinct account counts do not count sessions as people", async () => {
  const h = await harness();
  try {
    const a = await h.token(),
      b = await h.token("bob");
    for (const [token, options] of [
      [a, {}],
      [a, { failed: true }],
      [b, {}],
    ]) {
      const x = await cohort(h, token, { provider: "chatgpt", ...options });
      for (let i = 0; i < 2; i++)
        await h.request(
          `/api/v1/sessions/${x.s.id}/contribution`,
          "POST",
          { consent: true, revision: 1 },
          token,
        );
    }
    const stats = await h
      .request("/api/v1/statistics", "GET", undefined, a)
      .then((r) => r.json());
    assert.equal(stats.sessions, 3);
    assert.equal(stats.distinctContributingAccounts, 2);
    assert.equal(stats.collectionGroups.length, 1);
    const g = stats.collectionGroups[0];
    assert.equal(g.attempts, 3);
    assert.equal(g.outcomes.failed, 1);
    assert.equal(g.firstReplyCount, 2);
    assert.equal(g.missingFirstReplyCount, 1);
    assert.equal(g.distinctContributingAccounts, 2);
    const ownerA = await h
      .request("/api/v1/account", "GET", undefined, a)
      .then((r) => r.json());
    const ownerB = await h
      .request("/api/v1/account", "GET", undefined, b)
      .then((r) => r.json());
    assert.equal(JSON.stringify(stats).includes(ownerA.accountID), false);
    assert.equal(JSON.stringify(stats).includes(ownerB.accountID), false);
    assert.match(
      stats.contributorDefinition,
      /not independently verified unique humans/,
    );
  } finally {
    await h.close();
  }
});
test("withdrawn revision retry and cross-purpose registration retry return their actual conflict", async () => {
  const h = await harness();
  try {
    const a = await h.token(),
      x = await cohort(h, a);
    const path = `/api/v1/sessions/${x.s.id}/contribution`;
    await h.request(path, "POST", { consent: true, revision: 1 }, a);
    await h.request(path, "DELETE", undefined, a);
    assert.equal(
      (await h.request(path, "POST", { consent: true, revision: 1 }, a)).status,
      409,
    );
    assert.equal(
      (await h.request(path, "POST", { consent: true, revision: 2 }, a)).status,
      202,
    );
    const row = await h.db
      .prepare("SELECT local_id FROM sessions WHERE id=?")
      .bind(x.s.id)
      .first();
    assert.equal(
      (
        await h.request(
          "/api/v1/sessions",
          "POST",
          {
            localID: row.local_id,
            purpose: "sync",
            consent: true,
            fixture: false,
            context: "fresh",
          },
          a,
        )
      ).status,
      409,
    );
  } finally {
    await h.close();
  }
});
test("manifest finalization rejects an append or deletion that wins after its read", async () => {
  const { finalizeManifest } = await import("../dist/support/sessions.mjs");
  const h = await harness();
  try {
    const a = await h.token();
    const raw = await readFile("test/fixtures/native-upload-v1.json", "utf8"),
      original = JSON.parse(raw);
    async function open(local) {
      const c = structuredClone(original);
      c.sessionID = local;
      let prior;
      for (const e of c.events) {
        e.comparisonID = local;
        if (prior) e.previousHash = prior;
        else delete e.previousHash;
        prior = digest(canonical(e));
      }
      const bytes = canonical(c),
        registered = await h
          .request(
            "/api/v1/sessions",
            "POST",
            {
              localID: local,
              purpose: "sync",
              consent: true,
              fixture: true,
              context: "unknown",
            },
            a,
          )
          .then((r) => r.json());
      const r = await h.mf.dispatchFetch(
        `http://localhost/api/v1/sessions/${registered.id}/chunks`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${a}`,
            "content-type": "application/json",
          },
          body: bytes,
        },
      );
      assert.equal(r.status, 201);
      return {
        c,
        s: await h.db
          .prepare("SELECT * FROM sessions WHERE id=?")
          .bind(registered.id)
          .first(),
      };
    }
    for (const action of ["append", "delete"]) {
      const { c, s } = await open(crypto.randomUUID());
      let entered, release;
      const ready = new Promise((r) => (entered = r)),
        gate = new Promise((r) => (release = r));
      const pausedDB = new Proxy(h.db, {
        get(target, key) {
          if (key === "batch")
            return async (statements) => {
              entered();
              await gate;
              return target.batch(statements);
            };
          const value = Reflect.get(target, key);
          return typeof value === "function" ? value.bind(target) : value;
        },
      });
      const pending = finalizeManifest({ DB: pausedDB }, s.owner, s, {
        sequenceEnd: s.next_sequence,
        hash: s.last_hash,
      });
      await ready;
      if (action === "delete") {
        assert.equal(
          (await h.request(`/api/v1/sessions/${s.id}`, "DELETE", undefined, a))
            .status,
          202,
        );
      } else {
        const event = {
          ...c.events.at(-1),
          id: "next-segment",
          kind: "segmentStarted",
          segmentID: "next-segment",
          sequence: 8,
          previousHash: digest(canonical(c.events.at(-1))),
          reason: "resumed-partial",
        };
        const next = {
          schemaVersion: 1,
          id: "continuing-chunk",
          sessionID: c.sessionID,
          sequenceStart: 8,
          sequenceEnd: 8,
          previousHash: s.last_hash,
          events: [event],
          artifacts: [],
        };
        const r = await h.mf.dispatchFetch(
          `http://localhost/api/v1/sessions/${s.id}/chunks`,
          {
            method: "POST",
            headers: {
              authorization: `Bearer ${a}`,
              "content-type": "application/json",
            },
            body: canonical(next),
          },
        );
        assert.equal(r.status, 201);
      }
      release();
      await assert.rejects(pending, (error) => error.status === 409);
      assert.equal(
        (
          await h.db
            .prepare(
              'SELECT count(*) AS n FROM outbox WHERE target=? AND kind="validate"',
            )
            .bind(s.id)
            .first()
        ).n,
        0,
      );
    }
  } finally {
    await h.close();
  }
});
test("repeated real R2 writes under failed D1 commits remain within the pending account bound", async () => {
  const h = await harness();
  try {
    const a = await h.token(),
      source = JSON.parse(
        await readFile("test/fixtures/native-upload-v1.json", "utf8"),
      );
    const r = await h.request(
      "/api/v1/sessions",
      "POST",
      {
        localID: source.sessionID,
        purpose: "sync",
        consent: true,
        fixture: true,
        context: "unknown",
      },
      a,
    );
    assert.equal(r.status, 201);
    const s = await r.json();
    source.events = [];
    let prior;
    for (let i = 0; i < 10; i++) {
      const event = {
        schemaVersion: 1,
        id: `large-event-${i}`,
        sequence: i + 1,
        comparisonID: source.sessionID,
        segmentID: "large-segment",
        kind: "replyObserved",
        fixture: true,
        stamp: {
          clockID: "fixture-clock",
          wallMS: 1791760000000,
          monotonicMS: 1000 + i,
        },
        text: "x".repeat(95000),
        ...(prior ? { previousHash: prior } : {}),
      };
      source.events.push(event);
      prior = digest(canonical(event));
    }
    source.sequenceEnd = 10;
    await h.db
      .prepare(
        "CREATE TRIGGER injected_failure BEFORE INSERT ON chunks BEGIN SELECT RAISE(ABORT,'fixture_d1_failure'); END",
      )
      .run();
    let stored = 0,
      lastBytes;
    for (let i = 0; i < 100; i++) {
      source.id = `failed-commit-${i}`;
      const bytes = canonical(source);
      const response = await h.mf.dispatchFetch(
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
      if (response.status === 429) break;
      assert.equal(response.status, 503);
      stored++;
      lastBytes = bytes;
    }
    assert.ok(stored > 1 && stored < 100);
    const bucket = await h.mf.getR2Bucket("CONTENT"),
      objects = (await bucket.list({ limit: 1000 })).objects;
    assert.equal(objects.length, stored);
    assert.ok(objects.reduce((n, o) => n + o.size, 0) <= 67108864);
    assert.equal(
      (await h.db.prepare("SELECT count(*) AS n FROM chunks").first()).n,
      0,
    );
    const pending = await h.db
      .prepare("SELECT sum(bytes) AS n FROM object_intents")
      .first();
    assert.ok(pending.n <= 67108864);
    const retry = await h.mf.dispatchFetch(
      `http://localhost/api/v1/sessions/${s.id}/chunks`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${a}`,
          "content-type": "application/json",
        },
        body: lastBytes,
      },
    );
    assert.equal(retry.status, 503);
    assert.equal((await bucket.list({ limit: 1000 })).objects.length, stored);
  } finally {
    await h.close();
  }
});
test("R2 cleanup failure keeps tombstoned content inaccessible; replay removes bytes and D1 content", async () => {
  const h = await harness({ queueDelay: 30 });
  try {
    const a = await h.token(),
      x = await cohort(h, a, { driveJobs: true }),
      bindings = await h.mf.getBindings("benchmarks-fixture");
    await h.request(
      `/api/v1/sessions/${x.s.id}/contribution`,
      "POST",
      { consent: true, revision: 1 },
      a,
    );
    await h.request(
      `/api/v1/sessions/${x.s.id}/feedback`,
      "POST",
      {
        consent: true,
        segmentID: "synthetic-segment",
        agentID: "synthetic-chatgpt-copy-1",
        messageID: "document-1:reply-1",
        revision: 1,
        selection: "negative",
      },
      a,
    );
    const p = await publication(h, a, undefined, x.s.id).then((r) => r.json());
    assert.equal(
      (await h.request(`/api/v1/sessions/${x.s.id}`, "DELETE", undefined, a))
        .status,
      202,
    );
    const j = await h.db
      .prepare('SELECT id FROM outbox WHERE kind="deleteSession" AND target=?')
      .bind(x.s.id)
      .first();
    let fail = true;
    const bucket = new Proxy(bindings.CONTENT, {
      get(target, key) {
        if (key === "delete")
          return async (keys) => {
            if (fail) {
              fail = false;
              throw Error("Synthetic one-time local R2 failure");
            }
            return target.delete(keys);
          };
        const value = Reflect.get(target, key);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
    await assert.rejects(processJob({ ...bindings, CONTENT: bucket }, j.id));
    assert.equal((await h.request(p.path)).status, 404);
    assert.equal(
      (
        await h.db
          .prepare("SELECT completed_at FROM outbox WHERE id=?")
          .bind(j.id)
          .first()
      ).completed_at,
      null,
    );
    assert.ok((await bindings.CONTENT.list()).objects.length > 0);
    await processJob(bindings, j.id);
    await processJob(bindings, j.id);
    assert.equal((await bindings.CONTENT.list()).objects.length, 0);
    for (const table of [
      "chunks",
      "validations",
      "contribution_revisions",
      "feedback_revisions",
    ])
      assert.equal(
        (
          await h.db
            .prepare(`SELECT count(*) AS n FROM ${table} WHERE session=?`)
            .bind(x.s.id)
            .first()
        ).n,
        0,
      );
    const standalone = await publication(h, a).then((r) => r.json());
    await h.request(
      `/api/v1/publications/${standalone.id}`,
      "DELETE",
      undefined,
      a,
    );
    const pj = await h.db
      .prepare(
        'SELECT id FROM outbox WHERE kind="deletePublication" AND target=?',
      )
      .bind(standalone.id)
      .first();
    await processJob(bindings, pj.id);
    assert.equal((await bindings.CONTENT.list()).objects.length, 0);
    const accountPage = await publication(h, a).then((r) => r.json());
    await h.request("/api/v1/account", "DELETE", undefined, a);
    const aj = await h.db
      .prepare('SELECT id FROM outbox WHERE kind="deleteAccount"')
      .first();
    await processJob(bindings, aj.id);
    const state = await h
      .request("/api/v1/account/deletion", "GET", undefined, a)
      .then((r) => r.json());
    assert.ok(state.deletion.content_cleaned_at);
    assert.equal(
      state.deletion.blocked_reason,
      "identity_management_unprovisioned",
    );
    assert.equal((await h.request(accountPage.path)).status, 404);
    assert.equal((await bindings.CONTENT.list()).objects.length, 0);
  } finally {
    await h.close();
  }
});
test("Alpha navigation gap does not invalidate continuous Beta timing; global gap does", async () => {
  const h = await harness();
  try {
    const a = await h.token();
    for (const global of [false, true]) {
      const x = await cohort(h, a, {
        transform(c) {
          const beta = structuredClone(c.events.slice(1, 5));
          for (const e of beta) {
            e.id = "beta-" + e.id;
            e.agent.id = "beta-agent";
            e.turnID = "beta-turn";
          }
          const gap = {
            ...structuredClone(c.events[0]),
            id: "alpha-gap",
            kind: "gap",
            reason: "navigation",
            stamp: { ...c.events[0].stamp, monotonicMS: 1600 },
          };
          if (!global) gap.agent = structuredClone(c.events[1].agent);
          c.events = [
            c.events[0],
            ...c.events.slice(1, 3),
            ...beta.slice(0, 2),
            gap,
            c.events[3],
            beta[2],
            c.events[4],
            beta[3],
            c.events[5],
            c.events[6],
          ];
        },
      });
      const b = x.v.metrics.samples.find((s) => s.agent === "beta-agent");
      assert.equal(x.v.completeness, "partial");
      assert.equal(b.firstReplyMS, global ? null : 250);
    }
  } finally {
    await h.close();
  }
});
test("a put completing after account cleanup is erased or reopens tracked deletion on failure", async () => {
  const { immutableWrite } = await import("../dist/support/objects.mjs");
  for (const failure of [false, true]) {
    const h = await harness({ queueDelay: 30 });
    let release;
    try {
      const a = await h.token(),
        registered = await h
          .request(
            "/api/v1/sessions",
            "POST",
            {
              localID: "late-put",
              purpose: "sync",
              consent: true,
              fixture: true,
              context: "unknown",
            },
            a,
          )
          .then((r) => r.json());
      const bindings = await h.mf.getBindings("benchmarks-fixture");
      let arrived;
      const ready = new Promise((r) => (arrived = r)),
        gate = new Promise((r) => (release = r));
      let fail = failure;
      const bucket = new Proxy(bindings.CONTENT, {
        get(target, key) {
          if (key === "put")
            return async (...args) => {
              arrived();
              await gate;
              return target.put(...args);
            };
          if (key === "delete")
            return async (...args) => {
              if (fail) {
                fail = false;
                throw Error("Synthetic post-tombstone R2 delete failure");
              }
              return target.delete(...args);
            };
          const v = Reflect.get(target, key);
          return typeof v === "function" ? v.bind(target) : v;
        },
      });
      const pending = immutableWrite(
        { ...bindings, CONTENT: bucket },
        registered.owner,
        `sessions/${registered.id}/late-object/hash`,
        "Synthetic uncommitted content",
        registered.id,
      );
      const checked = assert.rejects(pending, (error) => error.status === 410);
      await ready;
      assert.equal(
        (await h.request("/api/v1/account", "DELETE", undefined, a)).status,
        202,
      );
      const job = await h.db
        .prepare('SELECT id FROM outbox WHERE kind="deleteAccount"')
        .first();
      await processJob(bindings, job.id);
      release();
      await checked;
      if (failure) {
        const state = await h.db
          .prepare(
            "SELECT content_cleaned_at,blocked_reason FROM outbox WHERE id=?",
          )
          .bind(job.id)
          .first();
        assert.equal(state.content_cleaned_at, null);
        assert.equal(state.blocked_reason, null);
        assert.equal((await bindings.CONTENT.list()).objects.length, 1);
        await processJob(bindings, job.id);
      }
      assert.equal((await bindings.CONTENT.list()).objects.length, 0);
      assert.equal(
        (await h.db.prepare("SELECT count(*) AS n FROM object_intents").first())
          .n,
        0,
      );
    } finally {
      release?.();
      await h.close();
    }
  }
});
