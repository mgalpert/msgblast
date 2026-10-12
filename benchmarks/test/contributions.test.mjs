import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { harness } from "./harness.mjs";
import { cohort } from "./cohort.mjs";
test("real queue validates fixtures, deduplicates credit, retains failures and removes withdrawn influence", async () => {
  const h = await harness();
  try {
    const a = await h.token();
    const good = await cohort(h, a),
      fixture = await cohort(h, a, { fixture: true }),
      partial = await cohort(h, a, { gap: true }),
      failed = await cohort(h, a, { failed: true });
    assert.equal(good.v.completeness, "complete");
    assert.equal(good.v.eligible, 1);
    assert.equal(good.v.metrics.samples[0].firstReplyMS, 250);
    assert.equal(fixture.v.eligible, 0);
    assert.ok(fixture.v.reasons.includes("fixture-excluded"));
    assert.equal(partial.v.completeness, "partial");
    assert.equal(partial.v.eligible, 0);
    assert.equal(failed.v.eligible, 1);
    assert.equal(failed.v.metrics.samples[0].outcome, "failed");
    assert.equal(failed.v.metrics.samples[0].firstReplyMS, null);
    assert.equal(
      (
        await h
          .request("/api/v1/statistics", "GET", undefined, a)
          .then((r) => r.json())
      ).sessions,
      0,
    );
    for (const entry of [good, fixture, partial, failed]) {
      const path = `/api/v1/sessions/${entry.s.id}/contribution`;
      for (let i = 0; i < 2; i++)
        assert.equal(
          (await h.request(path, "POST", { consent: true, revision: 1 }, a))
            .status,
          202,
        );
    }
    const history = await h
      .request("/api/v1/contributions", "GET", undefined, a)
      .then((r) => r.json());
    assert.equal(history.history.length, 4);
    assert.equal(history.acceptedDistinctSessions, 2);
    let stats = await h
      .request("/api/v1/statistics", "GET", undefined, a)
      .then((r) => r.json());
    assert.equal(stats.sessions, 2);
    assert.equal(
      stats.collectionGroups.reduce((n, g) => n + g.attempts, 0),
      2,
    );
    assert.equal(stats.collectionGroups[0].firstReplyCount, 1);
    assert.equal(stats.collectionGroups[0].firstReplyMedianMS, 250);
    assert.equal(
      stats.collectionGroups.reduce((n, g) => n + (g.outcomes.failed ?? 0), 0),
      1,
    );
    assert.match(stats.selection, /not representative/);
    assert.equal(
      (
        await h.request(
          `/api/v1/sessions/${good.s.id}/contribution`,
          "DELETE",
          undefined,
          a,
        )
      ).status,
      200,
    );
    stats = await h
      .request("/api/v1/statistics", "GET", undefined, a)
      .then((r) => r.json());
    assert.equal(stats.sessions, 1);
    assert.equal(stats.collectionGroups[0].firstReplyCount, 0);
  } finally {
    await h.close();
  }
});
test("complete records with unsupported timing retain outcome denominator but no timing sample", async () => {
  const h = await harness();
  try {
    const a = await h.token(),
      x = await cohort(h, a, { unsupported: true });
    assert.equal(x.v.completeness, "complete");
    assert.equal(x.v.eligible, 1);
    assert.equal(x.v.metrics.samples[0].firstReplyMS, null);
    assert.ok(x.v.reasons.includes("first-reply-timing-unavailable"));
  } finally {
    await h.close();
  }
});

test("frozen snapshots reject mutable feedback overlays and retain selected preference", async () => {
  const h = await harness();
  try {
    const a = await h.token(),
      x = await cohort(h, a);
    await h.request(
      `/api/v1/sessions/${x.s.id}/contribution`,
      "POST",
      { consent: true, revision: 1 },
      a,
    );
    assert.equal(
      (
        await h.request(
          `/api/v1/sessions/${x.s.id}/feedback`,
          "POST",
          { consent: true, selection: "negative" },
          a,
        )
      ).status,
      409,
    );
    const stats = await h
      .request("/api/v1/statistics", "GET", undefined, a)
      .then((r) => r.json());
    assert.equal(stats.preferences.favorite, 1);
    assert.equal(stats.preferences.negative, 0);
  } finally {
    await h.close();
  }
});

test("known providers with unknown models never collapse into one website agent benchmark", async () => {
  const h = await harness();
  try {
    const a = await h.token(),
      one = await cohort(h, a, { provider: "chatgpt" }),
      two = await cohort(h, a, { provider: "claude" }),
      unknown = await cohort(h, a);
    for (const x of [one, two, unknown])
      await h.request(
        `/api/v1/sessions/${x.s.id}/contribution`,
        "POST",
        { consent: true, revision: 1 },
        a,
      );
    const stats = await h
      .request("/api/v1/statistics", "GET", undefined, a)
      .then((r) => r.json());
    assert.equal(stats.collectionGroups.length, 3);
    assert.deepEqual(
      new Set(stats.collectionGroups.map((g) => g.provider)),
      new Set(["chatgpt", "claude", null]),
    );
    assert.ok(
      stats.collectionGroups.every((g) => g.model === null && g.attempts === 1),
    );
    assert.match(stats.unknownProviderLabel, /not an agent benchmark/);
  } finally {
    await h.close();
  }
});
