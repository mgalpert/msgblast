import { test } from "node:test";
import assert from "node:assert/strict";
import { harness } from "./harness.mjs";
import { processJob } from "../dist/support/jobs.mjs";
import {
  deleteManagedIdentity,
  identityConfigured,
} from "../dist/support/identity.mjs";
const configuration = {
  SERVICE_MODE: "live",
  IDENTITY_PROVIDER: "auth0",
  OIDC_ISSUER: "https://fixture.invalid/",
  OIDC_AUDIENCE: "msgblast-benchmarks",
  AUTH0_MANAGEMENT_ORIGIN: "https://fixture.invalid/",
  AUTH0_CLIENT_ID: "synthetic-management-app",
  AUTH0_CLIENT_SECRET: "synthetic-secret-never-live",
};
test("configured Auth0 deletion uses verified realm and encoded subject, retries failures, accepts absent identity", async () => {
  assert.equal(identityConfigured(configuration), true);
  assert.equal(
    identityConfigured({
      ...configuration,
      AUTH0_MANAGEMENT_ORIGIN: "https://other.invalid/",
    }),
    false,
  );
  const calls = [];
  await deleteManagedIdentity(
    configuration,
    { issuer: configuration.OIDC_ISSUER, subject: "auth0|fixture/one" },
    async (url, options) => {
      calls.push({ url: String(url), options });
      return options.method === "POST"
        ? Response.json({
            access_token: "synthetic-management-token",
            token_type: "Bearer",
          })
        : new Response(null, { status: 404 });
    },
  );
  assert.equal(calls[0].url, "https://fixture.invalid/oauth/token");
  assert.equal(JSON.parse(calls[0].options.body).scope, "delete:users");
  assert.equal(
    calls[1].url,
    "https://fixture.invalid/api/v2/users/auth0%7Cfixture%2Fone",
  );
  assert.equal(calls[1].options.redirect, "error");
  await assert.rejects(
    () =>
      deleteManagedIdentity(
        configuration,
        { issuer: "https://other.invalid/", subject: "alice" },
        () => {
          throw Error("must not fetch");
        },
      ),
    /identity_management_unprovisioned/,
  );
  let failure = true,
    deletions = 0;
  const h = await harness({
    queueDelay: 30,
    bindings: configuration,
    outbound: async (request) => {
      if (request.url.endsWith("/oauth/token"))
        return Response.json({
          access_token: "synthetic-token",
          token_type: "Bearer",
        });
      assert.equal(request.method, "DELETE");
      assert.equal(
        request.url,
        "https://fixture.invalid/api/v2/users/auth0%7Calice",
      );
      deletions++;
      return new Response(null, { status: failure ? 503 : 204 });
    },
  });
  try {
    const a = await h.token("auth0|alice");
    assert.equal(
      (await h.request("/api/v1/account", "GET", undefined, a)).status,
      200,
    );
    const deleted = await h.request("/api/v1/account", "DELETE", undefined, a);
    assert.equal(deleted.status, 202);
    assert.equal((await deleted.json()).managedIdentityDeletion, "pending");
    assert.equal(
      (await h.request("/api/v1/account", "GET", undefined, a)).status,
      410,
    );
    const job = await h.db
      .prepare("SELECT * FROM outbox WHERE kind='deleteAccount'")
      .first();
    const env = await h.mf.getBindings("benchmarks-fixture");
    // Direct production function uses synthetic fetch solely for external provider; D1/R2 are actual bindings.
    const original = globalThis.fetch;
    globalThis.fetch = async (url, options) => {
      if (options.method === "POST")
        return Response.json({
          access_token: "synthetic-token",
          token_type: "Bearer",
        });
      deletions++;
      return new Response(null, { status: failure ? 503 : 204 });
    };
    try {
      await assert.rejects(
        () => processJob(env, job.id),
        /identity_delete_retry/,
      );
      let status = await h
        .request("/api/v1/account/deletion", "GET", undefined, a)
        .then((r) => r.json());
      assert.ok(status.deletion.content_cleaned_at);
      assert.equal(status.deletion.completed_at, null);
      assert.equal(
        status.deletion.identity_error,
        "identity_provider_failed_retrying",
      );
      failure = false;
      await processJob(env, job.id);
      await processJob(env, job.id);
      status = await h
        .request("/api/v1/account/deletion", "GET", undefined, a)
        .then((r) => r.json());
      assert.ok(status.deletion.completed_at);
      assert.equal(status.deletion.identity_error, null);
      assert.equal(deletions, 2);
    } finally {
      globalThis.fetch = original;
    }
  } finally {
    await h.close();
  }
});
