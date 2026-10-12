import { immutableWrite } from "./objects";
import {
  body,
  canonical,
  hash,
  id,
  json,
  keys,
  now,
  object,
  requireValue,
  securityHeaders,
  text,
} from "./http";
import { ownedSession } from "./ingest";
export interface Artifact {
  id: string;
  name: string;
  type: string;
  base64: string;
}
export interface PublishedMessage {
  messageID: string;
  text: string;
  outcome: string;
  timingLabel: string;
  feedback?: string;
  revisions?: { text: string; timingLabel: string }[];
}
export interface Reply {
  agentID: string;
  outcome: string;
  messages: PublishedMessage[];
}
export interface Turn {
  targetedAgentIDs?: string[];
  alignmentLabel?: string;
  id: string;
  kind: string;
  prompt: string;
  scope: string;
  replies: Reply[];
}
export interface Projection {
  schemaVersion: number;
  title: string;
  fixture: boolean;
  participants: { id: string; label: string; connectionType: string }[];
  turns: Turn[];
  omissions: string[];
  limitations: string[];
  includesPrivate: boolean;
  includesUnknown?: boolean;
  includesEarlierHistory: boolean;
  artifacts: Artifact[];
}
export function validateProjection(value: unknown): Projection {
  const p = object(value);
  keys(p, [
    "schemaVersion",
    "title",
    "fixture",
    "participants",
    "turns",
    "omissions",
    "limitations",
    "includesPrivate",
    "includesUnknown",
    "includesEarlierHistory",
    "artifacts",
  ]);
  requireValue(
    p.schemaVersion === 1 &&
      typeof p.fixture === "boolean" &&
      typeof p.includesPrivate === "boolean" &&
      typeof p.includesEarlierHistory === "boolean",
  );
  requireValue(
    p.includesUnknown === undefined || typeof p.includesUnknown === "boolean",
  );
  text(p.title, 200);
  requireValue(
    Array.isArray(p.participants) &&
      p.participants.length > 0 &&
      p.participants.length <= 12,
  );
  const agents = new Set<string>();
  for (const value of p.participants) {
    const a = object(value);
    keys(a, ["id", "label", "connectionType"]);
    const aid = id(a.id);
    requireValue(!agents.has(aid));
    agents.add(aid);
    text(a.label, 128);
    requireValue(
      ["website", "messages", "cli", "grokBot"].includes(
        String(a.connectionType),
      ),
    );
  }
  requireValue(
    Array.isArray(p.turns) && p.turns.length > 0 && p.turns.length <= 200,
  );
  const turns = new Set<string>();
  for (const value of p.turns) {
    const t = object(value);
    keys(t, [
      "id",
      "kind",
      "prompt",
      "scope",
      "replies",
      "targetedAgentIDs",
      "alignmentLabel",
    ]);
    if (t.alignmentLabel !== undefined) text(t.alignmentLabel, 1000);
    const targets =
      t.targetedAgentIDs === undefined
        ? agents
        : new Set(
            Array.isArray(t.targetedAgentIDs) ? t.targetedAgentIDs.map(id) : [],
          );
    requireValue(
      t.targetedAgentIDs === undefined ||
        (Array.isArray(t.targetedAgentIDs) &&
          targets.size === t.targetedAgentIDs.length &&
          targets.size > 0 &&
          [...targets].every((target) => agents.has(target))),
      "target_membership",
    );
    const tid = id(t.id);
    requireValue(!turns.has(tid));
    turns.add(tid);
    text(t.prompt, 100000);
    requireValue(["initial", "followUp", "unknown"].includes(String(t.kind)));
    requireValue(
      t.scope === "shared" ||
        (t.scope === "private" && p.includesPrivate === true) ||
        (t.scope === "unknown" &&
          p.includesUnknown === true &&
          t.kind === "unknown"),
      "scope_not_previewed",
    );
    requireValue(Array.isArray(t.replies) && t.replies.length <= 12);
    const seen = new Set<string>();
    for (const value of t.replies) {
      const r = object(value);
      keys(r, ["agentID", "outcome", "messages"]);
      const aid = id(r.agentID);
      requireValue(targets.has(aid) && !seen.has(aid));
      seen.add(aid);
      requireValue(validOutcome(r.outcome));
      requireValue(Array.isArray(r.messages) && r.messages.length <= 200);
      const messageIDs = new Set<string>();
      for (const value of r.messages) {
        const m = object(value);
        keys(m, [
          "messageID",
          "text",
          "outcome",
          "timingLabel",
          "feedback",
          "revisions",
        ]);
        const mid = text(m.messageID, 256);
        requireValue(mid.length > 0 && !messageIDs.has(mid));
        messageIDs.add(mid);
        text(m.text, 100000);
        text(m.timingLabel, 1000);
        requireValue(validOutcome(m.outcome));
        if (m.revisions !== undefined) {
          requireValue(Array.isArray(m.revisions) && m.revisions.length <= 200);
          for (const value of m.revisions) {
            const r = object(value);
            keys(r, ["text", "timingLabel"]);
            text(r.text, 100000);
            text(r.timingLabel, 1000);
          }
        }
        if (m.feedback !== undefined)
          requireValue(
            ["favorite", "negative", "unmarked"].includes(String(m.feedback)),
          );
      }
    }
  }
  for (const field of ["omissions", "limitations"]) {
    requireValue(
      Array.isArray(p[field]) && (p[field] as unknown[]).length <= 100,
    );
    for (const v of p[field] as unknown[]) text(v, 2000);
  }
  requireValue((p.limitations as unknown[]).length > 0, "limits_required");
  requireValue(Array.isArray(p.artifacts) && p.artifacts.length <= 10);
  const aids = new Set<string>();
  for (const value of p.artifacts) {
    const a = object(value);
    keys(a, ["id", "name", "type", "base64"]);
    const aid = id(a.id);
    requireValue(!aids.has(aid));
    aids.add(aid);
    text(a.name, 128);
    text(a.base64, 350000);
    requireValue(
      ["text/plain", "image/png", "image/jpeg"].includes(String(a.type)),
      "unsafe_artifact_type",
    );
    const bytes = artifactBytes(a as unknown as Artifact);
    requireValue(bytes.length <= 262144, "artifact_too_large", 413);
    if (a.type === "image/png")
      requireValue(
        bytes[0] === 137 &&
          bytes[1] === 80 &&
          bytes[2] === 78 &&
          bytes[3] === 71,
        "invalid_image",
      );
    if (a.type === "image/jpeg")
      requireValue(
        bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255,
        "invalid_image",
      );
  }
  return p as unknown as Projection;
}
function validOutcome(value: unknown) {
  return [
    "observedReply",
    "observedCompletion",
    "failed",
    "canceled",
    "timeout",
    "uncertain",
    "unsupported",
    "unobserved",
  ].includes(String(value));
}
function artifactBytes(a: Artifact) {
  try {
    return Uint8Array.from(atob(a.base64), (c) => c.charCodeAt(0));
  } catch {
    requireValue(false, "invalid_base64");
  }
}
export async function publish(request: Request, env: Env, owner: string) {
  const b = object((await body(request)).value);
  keys(b, ["consent", "projection", "previewHash", "sessionID", "localID"]);
  requireValue(b.consent === true, "publication_consent_required");
  const p = validateProjection(b.projection),
    raw = canonical(p),
    digest = await hash(raw);
  requireValue(b.previewHash === digest, "preview_hash_mismatch");
  const session =
    b.sessionID === undefined
      ? undefined
      : await ownedSession(env, owner, id(b.sessionID));
  const localID = b.localID === undefined ? session?.local_id : id(b.localID);
  requireValue(
    !session || localID === session.local_id,
    "publication_association_mismatch",
    409,
  );
  if (localID !== undefined) {
    const tombstone = await env.DB.prepare(
      "SELECT id FROM sessions WHERE owner=? AND local_id=? AND deleted_at IS NOT NULL",
    )
      .bind(owner, localID)
      .first();
    requireValue(!tombstone, "session_deleted", 410);
  }
  const count = await env.DB.prepare(
    "SELECT count(*) AS n FROM publications WHERE owner=?",
  )
    .bind(owner)
    .first<{ n: number }>();
  requireValue(count && count.n < 100, "publication_quota", 429);
  const pid = crypto.randomUUID();
  const token = Array.from(crypto.getRandomValues(new Uint8Array(24)))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  const key = `publications/${pid}/${digest}`;
  await immutableWrite(
    env,
    owner,
    key,
    raw,
    b.sessionID === undefined ? null : id(b.sessionID),
    localID ?? null,
  );
  await env.DB.prepare(
    "INSERT INTO publications(id,owner,token_hash,object_key,projection_hash,bytes,session,local_id,created_at) VALUES(?,?,?,?,?,?,?,?,?)",
  )
    .bind(
      pid,
      owner,
      await hash(token),
      key,
      digest,
      new TextEncoder().encode(raw).length,
      b.sessionID ?? null,
      localID ?? null,
      now(),
    )
    .run();
  const exists = await env.DB.prepare(
    "SELECT id FROM publications WHERE id=? AND revoked_at IS NULL",
  )
    .bind(pid)
    .first();
  requireValue(exists, "account_deleted", 410);
  return json(
    {
      id: pid,
      path: `/s/${token}`,
      projectionHash: digest,
      visibility: "unlisted; recipients can forward the link",
      provenance:
        "owner-reviewed; locally recorded; not independently witnessed",
    },
    201,
  );
}
export async function publicRead(
  request: Request,
  env: Env,
  token: string,
  route: string,
) {
  requireValue(/^[0-9a-f]{48}$/.test(token), "not_found", 404);
  // Direct D1 queries always use the primary (no replica session). Every artifact goes through this gate.
  const p = await env.DB.prepare(
    "SELECT p.* FROM publications p JOIN accounts a ON a.id=p.owner LEFT JOIN sessions s ON s.id=p.session WHERE p.token_hash=? AND p.revoked_at IS NULL AND a.deleted_at IS NULL AND (p.session IS NULL OR s.deleted_at IS NULL) AND NOT EXISTS(SELECT 1 FROM sessions tombstone WHERE tombstone.owner=p.owner AND tombstone.local_id=p.local_id AND tombstone.deleted_at IS NOT NULL)",
  )
    .bind(await hash(token))
    .first<{ object_key: string }>();
  requireValue(p, "not_found", 404);
  const stored = await env.CONTENT.get(p.object_key);
  requireValue(stored, "not_found", 404);
  const projection = await stored.json<Projection>();
  if (route === "data") return json(projection);
  if (route.startsWith("artifacts/")) {
    let artifactID: string;
    try {
      artifactID = decodeURIComponent(route.slice(10));
    } catch {
      requireValue(false, "not_found", 404);
    }
    const a = projection.artifacts.find((a) => a.id === artifactID);
    requireValue(a, "not_found", 404);
    return new Response(artifactBytes(a), {
      headers: {
        ...securityHeaders,
        "content-type": a.type,
        "content-disposition": `attachment; filename="artifact-${a.id.replace(/[^A-Za-z0-9.-]/g, "_")}"`,
      },
    });
  }
  requireValue(route === "", "not_found", 404);
  return new Response(render(projection, `/s/${token}`), {
    headers: { ...securityHeaders, "content-type": "text/html; charset=utf-8" },
  });
}
const escape = (s: string) =>
  s.replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ]!,
  );
function renderScope(p: Projection) {
  return `<aside aria-label="Scope and evidence"><h2>Included context and limits</h2><p>${p.includesPrivate ? "Owner explicitly included private follow-ups." : "Private follow-ups excluded."} ${p.includesEarlierHistory ? "Owner explicitly included earlier history." : "Earlier provider history excluded."}</p><ul>${[...p.omissions, ...p.limitations, "Server receipts preserve received bytes; they do not prove local DOM authenticity."].map((x) => `<li>${escape(x)}</li>`).join("")}</ul></aside>`;
}
function renderPicker(p: Projection) {
  return `<nav class="agent-picker" aria-label="Select agent">${p.participants.map((a, i) => `<button data-agent="${escape(a.id)}" aria-pressed="${i === 0}">${escape(a.label)}</button>`).join("")}</nav>`;
}
const outcomeLabels: Record<string, string> = {
  observedReply: "Reply observed",
  observedCompletion: "Answer completion observed",
  failed: "Failed",
  canceled: "Canceled",
  timeout: "No reply observed before timeout",
  uncertain: "Outcome uncertain",
  unsupported: "Observation unsupported",
  unobserved: "No reply observed",
};
const connectionLabels: Record<string, string> = {
  website: "Website",
  messages: "Messages",
  cli: "Local CLI",
  grokBot: "Grok Bot",
};
function renderMessage(m: PublishedMessage, index: number) {
  return `<section class="message" data-message="${escape(m.messageID)}"><h4>Reply ${index + 1}</h4><p class="outcome">${escape(outcomeLabels[m.outcome] ?? "Outcome unknown")} · ${escape(m.timingLabel)}</p><div class="reply">${escape(m.text)}</div>${m.revisions?.length ? `<details><summary>${m.revisions.length} earlier observed streaming revisions</summary>${m.revisions.map((r) => `<p>${escape(r.timingLabel)}</p><div class="reply">${escape(r.text)}</div>`).join("")}</details>` : ""}${m.feedback ? `<p>Owner preference: ${escape(m.feedback)} (not task accuracy)</p>` : ""}</section>`;
}
function renderAgent(
  a: Projection["participants"][number],
  reply: Reply | undefined,
  index: number,
  targeted: boolean | null = true,
) {
  if (targeted === false)
    return `<article data-agent="${escape(a.id)}" class="agent ${index === 0 ? "selected" : ""}"><h3>${escape(a.label)}</h3><p>Not asked in this turn.</p></article>`;
  if (targeted === null)
    return `<article data-agent="${escape(a.id)}" class="agent ${index === 0 ? "selected" : ""}"><h3>${escape(a.label)}</h3><p>Turn membership was not declared. No captured reply is available for this agent.</p></article>`;
  return `<article data-agent="${escape(a.id)}" class="agent ${index === 0 ? "selected" : ""}"><h3>${escape(a.label)}</h3><p class="connection">${escape(connectionLabels[a.connectionType] ?? "Connection unknown")}</p><p class="outcome">Turn outcome: ${escape(outcomeLabels[reply?.outcome ?? "unobserved"] ?? "Outcome unknown")}</p>${reply?.messages.length ? reply.messages.map(renderMessage).join("") : '<p class="reply">No reply captured. This missing response is retained.</p>'}</article>`;
}
function renderTurn(p: Projection, t: Turn, index: number) {
  return `<section class="turn"><h2>Turn ${index + 1} · ${t.kind === "initial" ? "Initial request" : t.kind === "followUp" ? "Follow-up" : "Recorded request (position unknown)"} · ${escape(t.scope === "unknown" ? "Scope unknown" : t.scope === "private" ? "Private" : "Shared")}</h2>${t.alignmentLabel ? `<p>${escape(t.alignmentLabel)}</p>` : ""}<div class="prompt">${escape(t.prompt)}</div><div class="agents">${p.participants
    .map((a, j) =>
      renderAgent(
        a,
        t.replies.find((r) => r.agentID === a.id),
        j,
        t.targetedAgentIDs === undefined
          ? t.replies.some((r) => r.agentID === a.id)
            ? true
            : null
          : t.targetedAgentIDs.includes(a.id),
      ),
    )
    .join("")}</div></section>`;
}
function renderArtifacts(p: Projection, base: string) {
  return p.artifacts.length
    ? `<section><h2>Included artifacts</h2>${p.artifacts.map((a) => `<p><a href="${escape(base + "/artifacts/" + encodeURIComponent(a.id))}">${escape(a.name)}</a> · ${escape(a.type)}</p>`).join("")}</section>`
    : "";
}
function render(p: Projection, base: string) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex,nofollow,noarchive"><title>${escape(p.title)} | msgblast</title><link rel="stylesheet" href="/reader.css"><script defer src="/reader.js"></script></head><body><main><header><p class="brand">msgblast · shared comparison</p><h1>${escape(p.title)}</h1><p>Unlisted link. Anyone who receives it can forward it.</p>${p.fixture ? '<p class="fixture">Synthetic Demo fixture · no live agent requests</p>' : ""}</header>${renderScope(p)}${renderPicker(p)}${p.turns.map((t, i) => renderTurn(p, t, i)).join("")}${renderArtifacts(p, base)}<footer>Measured observations and optional preferences are separate. No overall assistant score.</footer></main></body></html>`;
}
