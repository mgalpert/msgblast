import { test } from "node:test";
import assert from "node:assert/strict";
import { harness } from "./harness.mjs";
test("runtime-scoped JWKS cache authenticates repeated requests during outbound outage", async () => {
  let fetches = 0,
    outage = false;
  const h = await harness({
    bindings: {
      SERVICE_MODE: "live",
      IDENTITY_PROVIDER: "auth0",
      AUTH0_MANAGEMENT_ORIGIN: "https://fixture.invalid/",
      AUTH0_CLIENT_ID: "synthetic-client",
      AUTH0_CLIENT_SECRET: "synthetic-secret",
    },
    jwksOutbound: (_r, keys) => {
      fetches++;
      return outage
        ? new Response("unavailable", { status: 503 })
        : Response.json(keys);
    },
  });
  try {
    const a = await h.token();
    assert.equal(
      (await h.request("/api/v1/account", "GET", undefined, a)).status,
      200,
    );
    outage = true;
    assert.equal(
      (await h.request("/api/v1/account", "GET", undefined, a)).status,
      200,
    );
    assert.equal(fetches, 1);
  } finally {
    await h.close();
  }
  // Same issuer URL, different isolate/key: no cross-runtime resolver reuse.
  const second = await harness();
  try {
    assert.equal(
      (
        await second.request(
          "/api/v1/account",
          "GET",
          undefined,
          await second.token(),
        )
      ).status,
      200,
    );
  } finally {
    await second.close();
  }
});
