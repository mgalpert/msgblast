import { test } from "node:test";
import assert from "node:assert/strict";
import { harness } from "./harness.mjs";
test("verified bearer identity rejects missing, wrong audience, wrong issuer and cross-origin mutations", async () => {
  const h = await harness();
  try {
    assert.equal((await h.request("/api/v1/account")).status, 401);
    assert.equal(
      (await h.request("/api/v1/account", "GET", undefined, await h.token()))
        .status,
      200,
    );
    assert.equal(
      (
        await h.request(
          "/api/v1/account",
          "GET",
          undefined,
          await h.token("alice", { aud: "wrong" }),
        )
      ).status,
      401,
    );
    const auth = await h.token();
    const r = await h.mf.dispatchFetch("http://localhost/api/v1/sessions", {
      method: "POST",
      headers: {
        authorization: `Bearer ${auth}`,
        "content-type": "application/json",
        origin: "https://evil.invalid",
      },
      body: "{}",
    });
    assert.equal(r.status, 403);
  } finally {
    await h.close();
  }
});
test("wrong issuer, expired, missing scope and invalid signatures fail independently", async () => {
  const h = await harness();
  try {
    for (const overrides of [{ iss: "https://wrong.invalid/" }, { exp: 1 }])
      assert.equal(
        (
          await h.request(
            "/api/v1/account",
            "GET",
            undefined,
            await h.token("alice", overrides),
          )
        ).status,
        401,
      );
    assert.equal(
      (
        await h.request(
          "/api/v1/account",
          "GET",
          undefined,
          await h.token("alice", { scope: "openid" }),
        )
      ).status,
      403,
    );
    const jwt = await h.token();
    const parts = jwt.split(".");
    parts[2] = (parts[2][0] === "A" ? "B" : "A") + parts[2].slice(1);
    assert.equal(
      (await h.request("/api/v1/account", "GET", undefined, parts.join(".")))
        .status,
      401,
    );
    assert.equal(
      (await h.mf.dispatchFetch("https://public.invalid/api/v1/account"))
        .status,
      503,
    );
  } finally {
    await h.close();
  }
});
