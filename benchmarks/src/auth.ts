import { createRemoteJWKSet, jwtVerify } from "jose";
import { hash, HttpError, requireValue } from "./http";
export async function authenticate(
  request: Request,
  env: Env,
  allowDeleted = false,
): Promise<string> {
  requireValue(
    env.SERVICE_MODE === "fixture",
    "service_not_configured: live identity management unprovisioned",
    503,
  );
  requireValue(
    ["localhost", "127.0.0.1", "[::1]"].includes(new URL(request.url).hostname),
    "fixture_mode_requires_loopback",
    503,
  );
  const issuer = new URL(env.OIDC_ISSUER);
  requireValue(
    issuer.protocol === "https:" && issuer.hostname !== "identity.invalid",
    "identity_not_configured",
    503,
  );
  const header = request.headers.get("authorization");
  requireValue(
    header && header.startsWith("Bearer "),
    "authentication_required",
    401,
  );
  let subject: string;
  try {
    const { payload } = await jwtVerify(
      header.slice(7),
      createRemoteJWKSet(new URL(".well-known/jwks.json", issuer)),
      {
        issuer: env.OIDC_ISSUER,
        audience: env.OIDC_AUDIENCE,
        algorithms: ["RS256"],
        requiredClaims: ["sub", "exp", "iat"],
        clockTolerance: 5,
      },
    );
    requireValue(
      typeof payload.sub === "string" &&
        payload.sub.length > 0 &&
        payload.sub.length <= 256,
      "invalid_token",
      401,
    );
    requireValue(
      typeof payload.scope === "string" &&
        payload.scope.split(" ").includes("benchmarks:write"),
      "scope_required",
      403,
    );
    subject = payload.sub;
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(401, "invalid_token");
  }
  // Identity is derived from verified issuer/subject; no client-provided account id is accepted.
  const owner = await hash(env.OIDC_ISSUER + "\u0000" + subject);
  await env.DB.prepare(
    "INSERT OR IGNORE INTO accounts(id,issuer,subject) VALUES(?,?,?)",
  )
    .bind(owner, env.OIDC_ISSUER, subject)
    .run();
  const account = await env.DB.prepare(
    "SELECT deleted_at FROM accounts WHERE id=?",
  )
    .bind(owner)
    .first<{ deleted_at: string | null }>();
  requireValue(
    account && (allowDeleted || !account.deleted_at),
    "account_deleted",
    410,
  );
  return owner;
}
export function mutationOrigin(request: Request) {
  const origin = request.headers.get("origin");
  if (origin)
    requireValue(
      origin === new URL(request.url).origin,
      "origin_rejected",
      403,
    );
  const site = request.headers.get("sec-fetch-site");
  requireValue(
    !site || site === "same-origin" || site === "none",
    "origin_rejected",
    403,
  );
  // No cookie authentication or CORS. Native clients use bearer tokens; browser clients must be same-origin.
}
