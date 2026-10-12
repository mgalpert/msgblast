import { test } from "node:test";
import assert from "node:assert/strict";
import { harness, projection as baseProjection, canonical, digest } from "./harness.mjs";

const projection = structuredClone(baseProjection);
projection.artifacts = [{ id: "note", name: "Synthetic note", type: "text/plain", base64: btoa("Synthetic selected artifact") }];

async function register(h, token, localID) {
  const response = await h.request("/api/v1/sessions", "POST", {
    localID, consent: true, purpose: "sync", fixture: true, context: "fresh",
  }, token);
  assert.equal(response.status, 201);
  return response.json();
}
function publish(h, token, association) {
  return h.request("/api/v1/publications", "POST", {
    consent: true, projection, previewHash: digest(canonical(projection)), ...association,
  }, token);
}

test("comparison association revokes exact public projection in either publication/upload ordering", async () => {
  const h = await harness({ queueDelay: 30 });
  try {
    const a = await h.token(), b = await h.token("bob");
    for (const beforeUpload of [true, false]) {
      const localID = beforeUpload ? "publish-first" : "upload-first";
      let session = beforeUpload ? undefined : await register(h, a, localID);
      const countBefore = (await h.db.prepare("SELECT count(*) AS n FROM sessions").first()).n;
      const created = await publish(h, a, { localID, ...(session ? { sessionID: session.id } : {}) });
      assert.equal(created.status, 201, await created.clone().text());
      const link = await created.json();
      assert.equal(link.projectionHash, digest(canonical(projection)));
      assert.equal((await h.db.prepare("SELECT count(*) AS n FROM sessions").first()).n, countBefore);
      assert.deepEqual(await h.request(link.path + "/data").then(r => r.json()), projection);
      const row = await h.db.prepare("SELECT object_key,owner FROM publications WHERE id=?").bind(link.id).first();
      const bindings = await h.mf.getBindings("benchmarks-fixture");
      assert.equal(await bindings.CONTENT.get(row.object_key).then(o => o.text()), canonical(projection));
      if (!session) session = await register(h, a, localID);
      const otherSession = await register(h, b, localID);
      const otherResponse = await publish(h, b, { localID, sessionID: otherSession.id });
      assert.equal(otherResponse.status, 201);
      const otherLink = await otherResponse.json();
      assert.equal((await h.request(`/api/v1/sessions/${session.id}`, "DELETE", undefined, a)).status, 202);
      assert.equal((await h.request(link.path)).status, 404);
      assert.equal((await h.request(link.path + "/data")).status, 404);
      assert.equal((await h.request(link.path + "/artifacts/note")).status, 404);
      // Model the insertion boundary after a publication precheck/R2 write and concurrent deletion.
      // The same production D1 trigger must deny the insert even without a sessionID.
      await assert.rejects(h.db.prepare(
        "INSERT INTO publications(id,owner,token_hash,object_key,projection_hash,bytes,local_id,created_at) VALUES(?,?,?,?,?,?,?,?)",
      ).bind("racing-" + localID, row.owner, "race-" + localID, "unused-race-" + localID, link.projectionHash, 0, localID, new Date().toISOString()).run(), /publication_association_conflict/);
      assert.equal((await h.request(otherLink.path)).status, 200);
      assert.equal((await publish(h, a, { localID })).status, 410);
      const job = await h.db.prepare("SELECT id FROM outbox WHERE kind='deleteSession' AND target=?").bind(session.id).first();
      const { processJob } = await import("../dist/support/jobs.mjs");
      await processJob(bindings, job.id);
      assert.equal(await bindings.CONTENT.get(row.object_key), null);
      assert.equal((await h.db.prepare("SELECT bytes FROM publications WHERE id=?").bind(link.id).first()).bytes, 0);
      assert.equal((await h.request(otherLink.path)).status, 200);
    }
  } finally { await h.close(); }
});

test("association rejects cross-owner sessions and mismatched comparison IDs", async () => {
  const h = await harness();
  try {
    const a = await h.token(), b = await h.token("bob");
    const session = await register(h, a, "comparison-a");
    assert.equal((await publish(h, a, { localID: "comparison-b", sessionID: session.id })).status, 409);
    assert.equal((await publish(h, b, { localID: "comparison-a", sessionID: session.id })).status, 404);
    const legacy = await publish(h, a, { sessionID: session.id });
    assert.equal(legacy.status, 201);
    const link = await legacy.json();
    assert.equal((await h.db.prepare("SELECT local_id FROM publications WHERE id=?").bind(link.id).first()).local_id, "comparison-a");
  } finally { await h.close(); }
});

test("migration backfills session-linked publication association without guessing standalone links", async () => {
  const h = await harness({ beforeMigration: async (file, db) => {
    if (file !== "0003_publication_association.sql") return;
    await db.prepare("INSERT INTO accounts(id,issuer,subject) VALUES('legacy-owner','https://fixture.invalid/','legacy')").run();
    await db.prepare("INSERT INTO sessions(id,owner,local_id,purpose,fixture,context,created_at) VALUES('legacy-session','legacy-owner','legacy-comparison','sync',1,'fresh','2026-10-12')").run();
    await db.prepare("INSERT INTO object_intents(object_key,owner,session,bytes,state,updated_at) VALUES('legacy-pending','legacy-owner','legacy-session',30,'uploading','2026-10-12')").run();
    for (const [pid, session] of [["linked", "legacy-session"], ["standalone", null]]) {
      await db.prepare("INSERT INTO publications(id,owner,token_hash,object_key,projection_hash,bytes,session,created_at) VALUES(?,'legacy-owner',?,?,?,0,?,'2026-10-12')")
        .bind(pid, pid + "-token", pid + "-object", digest(canonical(projection)), session).run();
    }
  } });
  try {
    assert.equal((await h.db.prepare("SELECT local_id FROM publications WHERE id='linked'").first()).local_id, "legacy-comparison");
    assert.equal((await h.db.prepare("SELECT local_id FROM publications WHERE id='standalone'").first()).local_id, null);
    const { immutableWrite } = await import("../dist/support/objects.mjs");
    const bindings = await h.mf.getBindings("benchmarks-fixture");
    await immutableWrite(bindings,"legacy-owner","legacy-pending","Synthetic legacy pending bytes","legacy-session");
    assert.equal(await bindings.CONTENT.get("legacy-pending").then(o=>o.text()),"Synthetic legacy pending bytes");
  } finally { await h.close(); }
});

test("held publication put crossing comparison deletion is erased or reopens cleanup on delete failure", async () => {
  const { publish: productionPublish } = await import("../dist/support/publications.mjs");
  const { processJob } = await import("../dist/support/jobs.mjs");
  for (const beforeUpload of [false, true]) for (const failure of [false, true]) {
    const h = await harness({ queueDelay: 30 });
    let release, pending;
    try {
      const token = await h.token(), localID = "held-publication";
      const identity = await h.request("/api/v1/account", "GET", undefined, token).then(r => r.json());
      const bindings = await h.mf.getBindings("benchmarks-fixture");
      let session = beforeUpload ? undefined : await register(h, token, localID);
      let arrived, fail = false;
      const ready = new Promise(r => arrived = r), gate = new Promise(r => release = r);
      const bucket = new Proxy(bindings.CONTENT, { get(target, key) {
        if (key === "put") return async (...args) => { arrived(); await gate; return target.put(...args); };
        if (key === "delete") return async (...args) => { if (fail) { fail = false; throw Error("Synthetic late-publication delete failure"); } return target.delete(...args); };
        const value = Reflect.get(target, key); return typeof value === "function" ? value.bind(target) : value;
      }});
      pending = productionPublish(new Request("http://localhost/api/v1/publications", {method:"POST", headers:{"content-type":"application/json"}, body:JSON.stringify({consent:true, projection, previewHash:digest(canonical(projection)), localID})}), {...bindings, CONTENT:bucket}, identity.accountID);
      const outcome = pending.then(() => ({ok:true}), error => ({error}));
      await ready;
      if (!session) session = await register(h, token, localID);
      assert.equal((await h.request(`/api/v1/sessions/${session.id}`, "DELETE", undefined, token)).status,202);
      const job = await h.db.prepare("SELECT id FROM outbox WHERE kind='deleteSession' AND target=?").bind(session.id).first();
      await processJob(bindings, job.id);
      assert.equal((await h.db.prepare("SELECT count(*) AS n FROM object_intents").first()).n,0,"session cleanup must find private comparison intent even without sessionID");
      fail = failure; release(); const result = await outcome; assert.equal(result.error?.status,410);
      if (failure) {
        assert.equal((await h.db.prepare("SELECT completed_at FROM outbox WHERE id=?").bind(job.id).first()).completed_at,null,"late deletion failure must reopen session cleanup");
        assert.equal((await bindings.CONTENT.list()).objects.length,1);
        await processJob(bindings,job.id);
      }
      assert.equal((await bindings.CONTENT.list()).objects.length,0);
      assert.equal((await h.db.prepare("SELECT count(*) AS n FROM object_intents").first()).n,0);
      assert.equal((await h.db.prepare("SELECT count(*) AS n FROM publications").first()).n,0);
    } finally { release?.(); await pending?.catch(()=>{}); await h.close(); }
  }
});
