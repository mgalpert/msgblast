import { body, object, requireValue } from "./http";
export function identityConfigured(env: Env) {
  let issuer: URL, management: URL;
  try {
    issuer = new URL(env.OIDC_ISSUER);
    management = new URL(env.AUTH0_MANAGEMENT_ORIGIN);
  } catch {
    return false;
  }
  return (
    env.IDENTITY_PROVIDER === "auth0" &&
    issuer.protocol === "https:" &&
    issuer.pathname === "/" &&
    !issuer.search &&
    !issuer.hash &&
    !issuer.username &&
    !issuer.password &&
    issuer.hostname !== "identity.invalid" &&
    management.protocol === "https:" &&
    management.origin + "/" === management.href &&
    management.origin === issuer.origin &&
    Boolean(env.AUTH0_CLIENT_ID && env.AUTH0_CLIENT_SECRET && env.OIDC_AUDIENCE)
  );
}
export function requireService(request: Request, env: Env) {
  if (env.SERVICE_MODE === "fixture") {
    requireValue(
      ["localhost", "127.0.0.1", "[::1]"].includes(
        new URL(request.url).hostname,
      ),
      "fixture_mode_requires_loopback",
      503,
    );
    return;
  }
  requireValue(
    env.SERVICE_MODE === "live" && identityConfigured(env),
    "service_not_configured",
    503,
  );
}
export async function deleteManagedIdentity(
  env: Env,
  account: { issuer: string; subject: string },
  fetcher: typeof fetch = fetch,
) {
  requireValue(
    identityConfigured(env) && account.issuer === env.OIDC_ISSUER,
    "identity_management_unprovisioned",
    503,
  );
  requireValue(
    account.subject.length > 0 &&
      account.subject.length <= 256 &&
      account.subject !== "." &&
      account.subject !== "..",
    "identity_subject_invalid",
    503,
  );
  const base = env.AUTH0_MANAGEMENT_ORIGIN;
  const tokenResponse = await fetcher(new URL("/oauth/token", base), {
    method: "POST",
    redirect: "error",
    signal: AbortSignal.timeout(15000),
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      grant_type: "client_credentials",
      client_id: env.AUTH0_CLIENT_ID,
      client_secret: env.AUTH0_CLIENT_SECRET,
      audience: new URL("/api/v2/", base).href,
      scope: "delete:users",
    }),
  });
  requireValue(tokenResponse.ok, "identity_token_failed", 503);
  const token = object(
    (
      await body(
        new Request("https://bounded.invalid/", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: tokenResponse.body,
          duplex: "half",
        } as RequestInit),
        16384,
      )
    ).value,
  );
  requireValue(
    typeof token.access_token === "string" &&
      token.access_token.length > 0 &&
      token.access_token.length <= 12000 &&
      token.token_type === "Bearer",
    "identity_token_invalid",
    503,
  );
  const result = await fetcher(
    new URL("/api/v2/users/" + encodeURIComponent(account.subject), base),
    {
      method: "DELETE",
      redirect: "error",
      signal: AbortSignal.timeout(15000),
      headers: { authorization: "Bearer " + token.access_token },
    },
  );
  requireValue(
    result.status === 204 || result.status === 404,
    "identity_delete_failed",
    503,
  );
}
