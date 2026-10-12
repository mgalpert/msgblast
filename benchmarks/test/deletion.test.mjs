import { test } from "node:test";
import assert from "node:assert/strict";
import { harness, projection, publication } from "./harness.mjs";
test("every publication artifact checks current access; account tombstone blocks new writes and queue replays", async () => {
  const h = await harness();
  try {
    const a = await h.token(),
      b = await h.token("bob");
    const p = structuredClone(projection);
    p.artifacts = [
      {
        id: "text-1",
        name: "Synthetic note",
        type: "text/plain",
        base64: btoa("Fixture attachment"),
      },
    ];
    const created = await publication(h, a, p);
    assert.equal(created.status, 201);
    const link = await created.json();
    assert.equal(
      (await h.request(link.path + "/artifacts/text-1")).status,
      200,
    );
    assert.equal(
      (await h.request("/api/v1/account", "DELETE", undefined, b)).status,
      202,
    );
    assert.equal((await h.request(link.path)).status, 200);
    assert.equal(
      (await h.request("/api/v1/account", "DELETE", undefined, a)).status,
      202,
    );
    for (const path of [
      link.path,
      link.path + "/data",
      link.path + "/artifacts/text-1",
    ])
      assert.equal((await h.request(path)).status, 404);
    assert.equal((await publication(h, a, p)).status, 410);
    assert.equal(
      (await h.request("/api/v1/account", "GET", undefined, a)).status,
      410,
    );
    const jobs = await h.db
      .prepare('SELECT * FROM outbox WHERE kind="deleteAccount"')
      .all();
    assert.equal(jobs.results.length, 2);
    assert.ok(jobs.results.every((j) => !j.completed_at));
  } finally {
    await h.close();
  }
});
test("unknown scope, unapproved private exchanges, mismatched preview and executable artifacts are rejected", async () => {
  const h = await harness();
  try {
    const a = await h.token();
    for (const scope of ["unknown", "private"]) {
      const p = structuredClone(projection);
      p.turns[0].scope = scope;
      assert.equal((await publication(h, a, p)).status, 400);
    }
    const p = structuredClone(projection);
    p.artifacts = [
      {
        id: "bad",
        name: "script",
        type: "image/svg+xml",
        base64: btoa('<svg onload="evil()"/>'),
      },
    ];
    assert.equal((await publication(h, a, p)).status, 400);
    assert.equal(
      (
        await h.request(
          "/api/v1/publications",
          "POST",
          { consent: true, projection, previewHash: "0".repeat(64) },
          a,
        )
      ).status,
      400,
    );
    assert.equal(
      (await h.db.prepare("SELECT count(*) AS n FROM publications").first()).n,
      0,
    );
  } finally {
    await h.close();
  }
});
