import { requireService } from "./identity";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { hash, HttpError, requireValue } from "./http";
// Bind caches to a runtime's D1 binding: fixture isolates may share an issuer URL
// but use independent signing keys. jose retains its normal expiry/rotation rules.
const resolverCaches = new WeakMap<
  object,
  Map<string, ReturnType<typeof createRemoteJWKSet>>
>();
function jwksResolver(env: Env, issuer: URL) {
  let cache = resolverCaches.get(env.DB);
  if (!cache) {
    cache = new Map();
    resolverCaches.set(env.DB, cache);
  }
  const url = new URL(".well-known/jwks.json", issuer);
  const key = env.SERVICE_MODE + "\u0000" + url.href;
  let resolver = cache.get(key);
  if (!resolver) {
    resolver = createRemoteJWKSet(url);
    if (cache.size >= 8) cache.delete(cache.keys().next().value!);
    cache.set(key, resolver);
  }
  return resolver;
}
export async function authenticate(
  request: Request,
  env: Env,
  allowDeleted = false,
): Promise<string> {
  requireService(request, env);
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
      jwksResolver(env, issuer),
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
