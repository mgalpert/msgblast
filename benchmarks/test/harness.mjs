import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { generateKeyPair, exportJWK, SignJWT } from "jose";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
export async function harness({ queueDelay = 0 } = {}) {
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk = {
    ...(await exportJWK(publicKey)),
    kid: "fixture-key",
    alg: "RS256",
    use: "sig",
  };
  const mf = new Miniflare(
    convertV4MiniflareOptions({
      name: "benchmarks-fixture",
      modules: true,
      scriptPath: "dist/worker.js",
      compatibilityDate: "2026-10-11",
      compatibilityFlags: ["nodejs_compat"],
      bindings: {
        OIDC_ISSUER: "https://fixture.invalid/",
        OIDC_AUDIENCE: "msgblast-benchmarks",
        SERVICE_MODE: "fixture",
      },
      assets: {
        directory: "site",
        binding: "ASSETS",
        run_worker_first: true,
        routerConfig: { has_user_worker: true },
      },
      d1Databases: ["DB"],
      r2Buckets: ["CONTENT"],
      queueProducers: { JOBS: "fixture-jobs" },
      queueConsumers: {
        "fixture-jobs": {
          maxBatchTimeout: queueDelay,
          maxBatchSize: queueDelay ? 100 : 1,
        },
      },
      outboundService: async (request) => {
        if (request.url !== "https://fixture.invalid/.well-known/jwks.json")
          throw new Error("Unexpected network request");
        return Response.json({ keys: [jwk] });
      },
    }),
  );
  const db = await mf.getD1Database("DB");
  const sql = await readFile("migrations/0001_initial.sql", "utf8");
  for (const stmt of sql.split(/;\n(?=CREATE)/).filter((s) => s.trim()))
    await db.prepare(stmt).run();
  async function token(sub = "alice", overrides = {}) {
    return new SignJWT({ scope: "benchmarks:write", ...overrides })
      .setProtectedHeader({ alg: "RS256", kid: "fixture-key" })
      .setIssuer(overrides.iss ?? "https://fixture.invalid/")
      .setAudience(overrides.aud ?? "msgblast-benchmarks")
      .setSubject(sub)
      .setIssuedAt()
      .setExpirationTime(overrides.exp ?? "5m")
      .sign(privateKey);
  }
  async function request(path, method = "GET", body, auth) {
    const headers = {};
    if (auth) headers.authorization = `Bearer ${auth}`;
    if (body !== undefined) headers["content-type"] = "application/json";
    return mf.dispatchFetch(`http://localhost${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  }
  return { mf, db, token, request, close: () => mf.dispose() };
}
export const projection = {
  schemaVersion: 1,
  title: "Synthetic comparison",
  fixture: true,
  participants: [
    { id: "agent-a", label: "Agent A", connectionType: "website" },
    { id: "agent-b", label: "Agent B", connectionType: "cli" },
  ],
  turns: [
    {
      id: "turn-1",
      kind: "initial",
      prompt: "Explain a rainbow.",
      scope: "shared",
      targetedAgentIDs: ["agent-a", "agent-b"],
      replies: [
        {
          agentID: "agent-a",
          outcome: "observedCompletion",
          messages: [
            {
              messageID: "ack-1",
              text: "I will explain it.",
              outcome: "observedReply",
              timingLabel:
                "First observed reply: 1200 ms; fixture cadence 500 ms",
            },
            {
              messageID: "answer-1",
              text: "<script>window.compromised=true</script> Light bends and separates into colors.",
              outcome: "observedReply",
              timingLabel:
                "Additional reply interval: 800 ms; fixture observation",
              feedback: "favorite",
            },
            {
              messageID: "extra-1",
              text: "A second reflection produces a fainter rainbow.",
              outcome: "observedCompletion",
              timingLabel:
                "Additional reply interval: 400 ms; observed completion 2400 ms",
            },
          ],
        },
        { agentID: "agent-b", outcome: "timeout", messages: [] },
      ],
    },
  ],
  omissions: [
    "One private follow-up omitted. Earlier provider history omitted.",
  ],
  limitations: [
    "Synthetic Demo fixture. Server receipts do not authenticate local observations.",
  ],
  includesPrivate: false,
  includesEarlierHistory: false,
  artifacts: [],
};

export function canonical(value) {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
  return (
    "{" +
    Object.keys(value)
      .sort()
      .map((k) => JSON.stringify(k) + ":" + canonical(value[k]))
      .join(",") +
    "}"
  );
}
export const digest = (value) =>
  createHash("sha256").update(value).digest("hex");
export async function publication(h, auth, p = projection, sessionID) {
  return h.request(
    "/api/v1/publications",
    "POST",
    {
      consent: true,
      projection: p,
      previewHash: digest(canonical(p)),
      ...(sessionID ? { sessionID } : {}),
    },
    auth,
  );
}
