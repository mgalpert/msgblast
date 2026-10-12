import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { harness, canonical, digest } from "./harness.mjs";
for (const stale of [false, true])
  test(`legacy feedback migration reconciles ${stale ? "stale" : "absent"} validation and pins contributions`, async () => {
    const c = JSON.parse(
      await readFile("test/fixtures/native-upload-v1.json", "utf8"),
    );
    c.events = c.events.filter((e) => e.kind !== "feedback");
    c.events.splice(4, 0, {
      ...c.events[3],
      id: "second-reply",
      messageID: "second-message",
      text: "Second distinct answer.",
    });
    let previous;
    for (let i = 0; i < c.events.length; i++) {
      const e = c.events[i];
      e.fixture = false;
      e.sequence = i + 1;
      if (previous) e.previousHash = previous;
      else delete e.previousHash;
      previous = digest(canonical(e));
    }
    c.sequenceEnd = c.events.length;
    const bytes = canonical(c),
      headHash = digest(bytes),
      owner = digest("https://fixture.invalid/\0alice"),
      sid = "legacy-feedback";
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
            "INSERT INTO sessions(id,owner,local_id,purpose,fixture,context,created_at) VALUES(?,?,?,'contribution',0,'fresh',?)",
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
            1,
            c.sequenceEnd,
            headHash,
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
        for (const [message, selection] of [
          [c.events[3].messageID, "favorite"],
          ["second-message", "negative"],
        ]) {
          for (const [revision, value] of [
            [1, "unmarked"],
            [2, selection],
          ])
            await db
              .prepare("INSERT INTO feedback_revisions VALUES(?,?,?,?,?,?,?)")
              .bind(
                sid,
                c.events[3].segmentID,
                c.events[3].agent.id,
                message,
                revision,
                value,
                new Date().toISOString(),
              )
              .run();
        }
        if (stale)
          await db
            .prepare("INSERT INTO validations VALUES(?, 'complete',1,'[]',?,?)")
            .bind(
              sid,
              JSON.stringify({ preferences: { favorite: 0, negative: 0 } }),
              new Date().toISOString(),
            )
            .run();
        await db
          .prepare(
            "INSERT INTO contribution_revisions(id,session,revision,requested_at) VALUES('legacy-contribution',?,1,?)",
          )
          .bind(sid, new Date().toISOString())
          .run();
        await db
          .prepare(
            "INSERT INTO outbox(id,kind,target,created_at) VALUES('legacy-validation','validate',?,?)",
          )
          .bind(sid, new Date().toISOString())
          .run();
      },
    });
    try {
      const a = await h.token(),
        env = await h.mf.getBindings("benchmarks-fixture"),
        { processJob } = await import("../dist/support/jobs.mjs");
      assert.equal(
        (
          await h.db
            .prepare("SELECT count(*) n FROM legacy_feedback_baselines")
            .first()
        ).n,
        2,
      );
      assert.equal(
        (
          await h.db
            .prepare("SELECT count(*) n FROM snapshot_validations")
            .first()
        ).n,
        0,
        "stale metrics must not count before recomputation",
      );
      assert.equal(
        (
          await h
            .request("/api/v1/statistics", "GET", undefined, a)
            .then((r) => r.json())
        ).sessions,
        0,
      );
      await processJob(env, "legacy-validation");
      const v1 = await h
        .request(`/api/v1/sessions/${sid}/validation`, "GET", undefined, a)
        .then((r) => r.json());
      assert.deepEqual(v1.metrics.preferences, {
        favorite: 1,
        negative: 1,
        unmarked: 0,
        rated: 2,
        replies: 2,
      });
      assert.equal(
        (
          await h.db
            .prepare("SELECT snapshot FROM contribution_revisions")
            .first()
        ).snapshot,
        sid + "-initial",
      );
      let stats = await h
        .request("/api/v1/statistics", "GET", undefined, a)
        .then((r) => r.json());
      assert.equal(stats.preferences.favorite, 1);
      assert.equal(stats.preferences.negative, 1);
      const open = await h
        .request(
          `/api/v1/sessions/${sid}/revisions`,
          "POST",
          {
            consent: true,
            requestID: "continue",
            parentHash: headHash,
            parentSequenceEnd: c.sequenceEnd,
          },
          a,
        )
        .then((r) => r.json());
      assert.equal(open.revision, 2);
      const event = {
        ...c.events[3],
        id: "later-feedback",
        kind: "feedback",
        selection: "unmarked",
        sequence: c.sequenceEnd + 1,
        previousHash: digest(canonical(c.events.at(-1))),
      };
      const chunk = {
        schemaVersion: 1,
        id: "later-chunk",
        sessionID: c.sessionID,
        sequenceStart: event.sequence,
        sequenceEnd: event.sequence,
        previousHash: headHash,
        events: [event],
        artifacts: [],
      };
      const newer = canonical(chunk);
      assert.equal(
        (
          await h.mf.dispatchFetch(
            `http://localhost/api/v1/sessions/${sid}/revisions/2/chunks`,
            {
              method: "POST",
              headers: {
                authorization: "Bearer " + a,
                "content-type": "application/json",
              },
              body: newer,
            },
          )
        ).status,
        201,
      );
      const second = await h
        .request(
          `/api/v1/sessions/${sid}/revisions/2/finalize`,
          "POST",
          { sequenceEnd: event.sequence, hash: digest(newer) },
          a,
        )
        .then((r) => r.json());
      const job = await h.db
        .prepare("SELECT id FROM outbox WHERE target=? AND kind='validate'")
        .bind(second.snapshotID)
        .first();
      await processJob(env, job.id);
      const v2 = await h
        .request(
          `/api/v1/sessions/${sid}/snapshots/${second.snapshotID}/validation`,
          "GET",
          undefined,
          a,
        )
        .then((r) => r.json());
      assert.deepEqual(v2.metrics.preferences, {
        favorite: 0,
        negative: 1,
        unmarked: 1,
        rated: 1,
        replies: 2,
      });
      stats = await h
        .request("/api/v1/statistics", "GET", undefined, a)
        .then((r) => r.json());
      assert.equal(
        stats.preferences.favorite,
        1,
        "private continuation cannot move contribution binding",
      );
      assert.equal(
        await (
          await (
            await h.mf.getR2Bucket("CONTENT")
          ).get("sessions/" + sid + "/old")
        ).text(),
        bytes,
        "native bytes must remain exact",
      );
      await h.request("/api/v1/account", "DELETE", undefined, a);
      const deletion = await h.db
        .prepare("SELECT id FROM outbox WHERE kind='deleteAccount'")
        .first();
      await processJob(env, deletion.id);
      for (const table of [
        "snapshot_validations",
        "snapshots",
        "session_revisions",
        "legacy_feedback_baselines",
      ])
        assert.equal(
          (await h.db.prepare(`SELECT count(*) n FROM ${table}`).first()).n,
          0,
          table + " retains private account data",
        );
    } finally {
      await h.close();
    }
  });
