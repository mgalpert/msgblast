import { test } from "node:test";
import assert from "node:assert/strict";
import { harness, projection, publication } from "./harness.mjs";
test("publish only stores exact redacted preview; revoke gates page and artifact on next request", async () => {
  const h = await harness();
  try {
    const a = await h.token(),
      b = await h.token("bob");
    const created = await publication(h, a);
    assert.equal(created.status, 201);
    const p = await created.json();
    assert.equal(
      (await h.db.prepare("SELECT count(*) AS n FROM sessions").first()).n,
      0,
    );
    const page = await h.request(p.path);
    assert.equal(page.status, 200);
    assert.match(page.headers.get("cache-control"), /no-store/);
    assert.match(page.headers.get("x-robots-tag"), /noindex/);
    assert.match(await page.text(), /&lt;script&gt;/);
    assert.equal(
      (await h.request(`/api/v1/publications/${p.id}`, "DELETE", undefined, b))
        .status,
      404,
    );
    assert.equal(
      (await h.request(`/api/v1/publications/${p.id}`, "DELETE", undefined, a))
        .status,
      200,
    );
    assert.equal((await h.request(p.path)).status, 404);
    assert.equal((await h.request(p.path + "/data")).status, 404);
  } finally {
    await h.close();
  }
});
test("one user turn preserves acknowledgment, answer and extra message identities and intervals", async () => {
  const h = await harness();
  try {
    const a = await h.token(),
      r = await publication(h, a);
    assert.equal(r.status, 201);
    const p = await r.json();
    const data = await h.request(p.path + "/data").then((r) => r.json());
    assert.deepEqual(
      data.turns[0].replies[0].messages.map((m) => m.messageID),
      ["ack-1", "answer-1", "extra-1"],
    );
    assert.equal(data.turns[0].replies[0].messages[1].feedback, "favorite");
    const html = await h.request(p.path).then((r) => r.text());
    assert.match(html, /Reply 1/);
    assert.match(html, /Reply 2/);
    assert.match(html, /Reply 3/);
    assert.match(html, /Additional reply interval: 800 ms/);
    assert.match(html, /Additional reply interval: 400 ms/);
    assert.match(html, /Turn outcome: No reply observed before timeout/);
    assert.match(html, /No reply captured/);
  } finally {
    await h.close();
  }
});
test("reader retains received multiline text and code indentation in escaped output", async () => {
  const h = await harness();
  try {
    const a = await h.token(),
      p = structuredClone(projection);
    p.turns[0].replies[0].messages[2].text =
      'First line\n  if (rainbow) {\n    color = "violet"\n  }';
    const r = await publication(h, a, p);
    assert.equal(r.status, 201);
    const link = await r.json();
    const data = await h.request(link.path + "/data").then((r) => r.json());
    assert.equal(
      data.turns[0].replies[0].messages[2].text,
      p.turns[0].replies[0].messages[2].text,
    );
    const html = await h.request(link.path).then((r) => r.text());
    assert.match(
      html,
      /First line\n  if \(rainbow\) \{\n    color = &quot;violet&quot;/,
    );
  } finally {
    await h.close();
  }
});
test("non-targeted agents are distinct from targeted missing replies", async () => {
  const h = await harness();
  try {
    const a = await h.token(),
      p = structuredClone(projection);
    p.includesPrivate = true;
    p.turns[0].scope = "private";
    p.turns[0].targetedAgentIDs = ["agent-b"];
    p.turns[0].replies = [p.turns[0].replies[1]];
    const r = await publication(h, a, p);
    assert.equal(r.status, 201);
    const link = await r.json(),
      html = await h.request(link.path).then((r) => r.text());
    assert.match(html, /Not asked in this turn/);
    assert.match(html, /No reply observed before timeout/);
    assert.match(html, /No reply captured/);
  } finally {
    await h.close();
  }
});
test("legacy missing target declarations and unaligned turns do not imply an agent was asked", async () => {
  const h = await harness();
  try {
    const a = await h.token(),
      p = structuredClone(projection);
    delete p.turns[0].targetedAgentIDs;
    p.turns[0].replies = [p.turns[0].replies[0]];
    p.turns[0].kind = "unknown";
    p.turns[0].alignmentLabel =
      "Per-agent recorded turn; shared action alignment unavailable.";
    const r = await publication(h, a, p);
    assert.equal(r.status, 201);
    const link = await r.json(),
      html = await h.request(link.path).then((r) => r.text());
    assert.match(html, /Turn membership was not declared/);
    assert.match(html, /Recorded request \(position unknown\)/);
    assert.match(html, /shared action alignment unavailable/);
  } finally {
    await h.close();
  }
});
