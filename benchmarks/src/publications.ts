import { BusinessChoices, validateBusinessChoices } from "./businessChoices";
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
  businessChoices?: BusinessChoices;
  revisions?: { text: string; timingLabel: string; businessChoices?: BusinessChoices }[];
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
          "businessChoices",
        ]);
        const mid = text(m.messageID, 256);
        requireValue(mid.length > 0 && !messageIDs.has(mid));
        messageIDs.add(mid);
        text(m.text, 100000);
        text(m.timingLabel, 1000);
        requireValue(validOutcome(m.outcome));
        if (m.businessChoices !== undefined) validateBusinessChoices(m.businessChoices);
        if (m.revisions !== undefined) {
          requireValue(Array.isArray(m.revisions) && m.revisions.length <= 200);
          for (const value of m.revisions) {
            const r = object(value);
            keys(r, ["text", "timingLabel", "businessChoices"]);
            if (r.businessChoices !== undefined) validateBusinessChoices(r.businessChoices);
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
function renderPicker(p: Projection) {
  return `<nav class="agent-picker" aria-label="Select conversation">${p.participants.map((a, i) => `<button data-agent="${escape(a.id)}" aria-pressed="${i === 0}">${escape(a.label)}</button>`).join("")}</nav>`;
}
function renderBusinessChoices(card: BusinessChoices) {
  return `<div class="bubble reply business-card" role="group" aria-label="Read-only business choices"><div class="business-title">${escape(card.title)}</div>${card.options.map(option => `<div class="business-option">${option.section ? `<div class="business-section">${escape(option.section)}</div>` : ""}<button type="button" class="business-choice" disabled><span>${escape(option.title)}</span>${option.selected ? '<span class="selection-mark" aria-hidden="true">✓</span><span class="sr-only">Selected</span>' : ""}</button>${option.subtitle ? `<div class="business-subtitle">${escape(option.subtitle)}</div>` : ""}</div>`).join("")}</div>`;
}
function renderContent(m: { text: string; businessChoices?: BusinessChoices }) {
  return m.businessChoices ? renderBusinessChoices(m.businessChoices) : `<div class="bubble reply">${escape(m.text)}</div>`;
}
function renderMessage(m: PublishedMessage, index: number) {
  return `<section class="message" data-message="${escape(m.messageID)}"><h4 class="sr-only">Reply ${index + 1}</h4>${renderContent(m)}${m.revisions?.length ? `<details class="versions"><summary>Earlier versions</summary>${m.revisions.map(renderContent).join("")}</details>` : ""}</section>`;
}
function renderConversation(p: Projection, agent: Projection["participants"][number], index: number) {
  const turns = p.turns.map((turn) => {
    const reply = turn.replies.find((r) => r.agentID === agent.id);
    const targeted = turn.targetedAgentIDs?.includes(agent.id);
    if (targeted === false) return '<p class="chat-status">Not asked in this turn.</p>';
    if (targeted === undefined && !reply) return '<p class="chat-status">No conversation captured for this request.</p>';
    // Only repeat a request in columns with declared membership or a captured
    // response. Preserve unknown alignment without implying a shared send.
    return `<div class="exchange"><div class="bubble prompt">${escape(turn.prompt)}</div>${reply?.messages.length ? reply.messages.map(renderMessage).join("") : '<p class="chat-status">No reply captured.</p>'}</div>`;
  }).join("");
  return `<article data-agent="${escape(agent.id)}" class="agent agent-color-${index % 6} ${index === 0 ? "selected" : ""}"><header class="agent-header"><span class="avatar" aria-hidden="true">${escape(Array.from(agent.label)[0] ?? "?")}</span><h2>${escape(agent.label)}</h2></header><div class="transcript" tabindex="0" role="region" aria-label="${escape(agent.label)} conversation">${turns}</div></article>`;
}
function renderArtifacts(p: Projection, base: string) {
  return p.artifacts.length
    ? `<section><h2>Included artifacts</h2>${p.artifacts.map((a) => `<p><a href="${escape(base + "/artifacts/" + encodeURIComponent(a.id))}">${escape(a.name)}</a> · ${escape(a.type)}</p>`).join("")}</section>`
    : "";
}
function render(p: Projection, base: string) {
  const title = p.title === "Shared comparison" ? (p.turns.find((t) => t.kind === "initial")?.prompt ?? p.turns[0]?.prompt ?? p.title) : p.title;
  const unassigned = p.turns.filter((t) => t.targetedAgentIDs === undefined && !t.replies.length);
  const requests = unassigned.length ? `<section aria-label="Requests without a captured conversation"><h2>Requests</h2>${unassigned.map((t) => `<div class="bubble prompt">${escape(t.prompt)}</div>`).join("")}</section>` : "";
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex,nofollow,noarchive"><title>${escape(title)} | msgblast</title><link rel="stylesheet" href="/reader.css"><script defer src="/reader.js"></script></head><body><main class="chat-window"><header class="window-chrome"><span class="window-controls" aria-hidden="true"><i></i><i></i><i></i></span><h1 title="${escape(title)}">${escape(title)}</h1><span class="brand">msgblast</span></header>${renderPicker(p)}<div class="agents">${p.participants.map((a, i) => renderConversation(p, a, i)).join("")}</div>${requests}${renderArtifacts(p, base)}</main></body></html>`;
}
