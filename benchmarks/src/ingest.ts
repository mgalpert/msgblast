import { providers } from "./providers";
import { immutableWrite } from "./objects";
import {
  canonical,
  hash,
  id,
  keys,
  object,
  requireValue,
  text,
  HttpError,
  now,
  json,
  body,
} from "./http";
export interface Session {
  id: string;
  owner: string;
  local_id: string;
  purpose: string;
  fixture: number;
  context: string;
  status: string;
  next_sequence: number;
  last_hash: string;
  bytes: number;
  deleted_at: string | null;
  current_revision: number;
}
export async function ownedSession(
  env: Env,
  owner: string,
  sid: string,
): Promise<Session> {
  const s = await env.DB.prepare(
    "SELECT * FROM sessions WHERE id=? AND owner=? AND deleted_at IS NULL",
  )
    .bind(sid, owner)
    .first<Session>();
  requireValue(s, "not_found", 404);
  return s;
}
export async function register(request: Request, env: Env, owner: string) {
  const v = object((await body(request, 8192)).value);
  keys(v, ["localID", "purpose", "consent", "fixture", "context"]);
  const local = id(v.localID);
  requireValue(v.consent === true, "upload_consent_required");
  requireValue(v.purpose === "sync" || v.purpose === "contribution");
  requireValue(typeof v.fixture === "boolean");
  requireValue(
    ["fresh", "prior", "unknown", "omitted"].includes(String(v.context)),
  );
  const existing = await env.DB.prepare(
    "SELECT * FROM sessions WHERE owner=? AND local_id=?",
  )
    .bind(owner, local)
    .first<Session>();
  if (existing) {
    requireValue(!existing.deleted_at, "session_deleted", 410);
    requireValue(
      existing.fixture === Number(v.fixture) &&
        existing.context === v.context &&
        existing.purpose === v.purpose,
      "registration_conflict",
      409,
    );
    return json(existing);
  }
  const count = await env.DB.prepare(
    "SELECT count(*) AS n FROM sessions WHERE owner=? AND deleted_at IS NULL",
  )
    .bind(owner)
    .first<{ n: number }>();
  requireValue(count && count.n < 200, "session_quota", 429);
  const sid = crypto.randomUUID();
  await env.DB.prepare(
    "INSERT INTO sessions(id,owner,local_id,purpose,fixture,context,created_at) SELECT ?,?,?,?,?,?,? FROM accounts WHERE id=? AND deleted_at IS NULL",
  )
    .bind(
      sid,
      owner,
      local,
      v.purpose,
      Number(v.fixture),
      v.context,
      now(),
      owner,
    )
    .run();
  return json(await ownedSession(env, owner, sid), 201);
}
const eventKeys = [
  "schemaVersion",
  "id",
  "sequence",
  "comparisonID",
  "segmentID",
  "kind",
  "stamp",
  "fixture",
  "previousHash",
  "agent",
  "turnID",
  "turnPosition",
  "scope",
  "messageID",
  "text",
  "sourceMS",
  "method",
  "reason",
  "selection",
  "requestGroupID",
  "targetAgentIDs",
];
export async function validateChunk(
  value: unknown,
  s: Session,
  previousEventHash?: string,
) {
  const chunk = object(value);
  keys(chunk, [
    "schemaVersion",
    "id",
    "sessionID",
    "sequenceStart",
    "sequenceEnd",
    "previousHash",
    "events",
    "artifacts",
  ]);
  requireValue(
    chunk.schemaVersion === 1 && chunk.sessionID === s.local_id,
    "schema_or_session_mismatch",
  );
  id(chunk.id);
  requireValue(
    Array.isArray(chunk.events) &&
      chunk.events.length > 0 &&
      chunk.events.length <= 1000,
    "event_limit",
  );
  requireValue(
    Number.isSafeInteger(chunk.sequenceStart) &&
      Number.isSafeInteger(chunk.sequenceEnd),
  );
  requireValue(
    chunk.sequenceEnd === Number(chunk.sequenceStart) + chunk.events.length - 1,
  );
  requireValue(Number(chunk.sequenceEnd) <= 10000, "session_event_limit", 429);
  requireValue(
    Array.isArray(chunk.artifacts) && chunk.artifacts.length === 0,
    "artifacts_not_supported_in_event_v1",
  );
  requireValue(
    chunk.previousHash === undefined ||
      /^[0-9a-f]{64}$/.test(String(chunk.previousHash)),
  );
  let previous = previousEventHash;
  for (let i = 0; i < chunk.events.length; i++) {
    const e = object(chunk.events[i]);
    keys(e, eventKeys);
    requireValue(
      e.schemaVersion === 1 &&
        e.comparisonID === s.local_id &&
        e.sequence === Number(chunk.sequenceStart) + i,
      "event_sequence_or_identity",
    );
    id(e.id);
    id(e.segmentID);
    requireValue(
      typeof e.fixture === "boolean" && Number(e.fixture) === s.fixture,
      "fixture_mismatch",
    );
    requireValue(
      [
        "segmentStarted",
        "turnStarted",
        "dispatched",
        "submitted",
        "replyObserved",
        "completed",
        "outcome",
        "feedback",
        "gap",
        "observationState",
        "segmentEnded",
      ].includes(String(e.kind)),
      "event_kind",
    );
    if (e.kind === "observationState") {
      requireValue(
        e.agent &&
          [
            "document-start",
            "generating",
            "idle",
            "unsupported-generation",
            "cancellation-requested",
          ].includes(String(e.reason)),
        "observation_state",
      );
    }
    const stamp = object(e.stamp);
    keys(stamp, ["clockID", "wallMS", "monotonicMS"]);
    id(stamp.clockID);
    requireValue(
      Number.isSafeInteger(stamp.wallMS) &&
        Number.isSafeInteger(stamp.monotonicMS) &&
        Number(stamp.monotonicMS) >= 0,
      "invalid_clock",
    );
    if (e.agent !== undefined) {
      const a = object(e.agent);
      keys(a, ["id", "name", "connection", "model", "provider"]);
      id(a.id);
      text(a.name, 256);
      requireValue(
        ["website", "messages", "cli", "grokBot"].includes(
          String(a.connection),
        ),
      );
      if (a.model !== undefined) text(a.model, 256);
      if (a.provider !== undefined)
        requireValue(
          providers.some((p) => p === a.provider),
          "unknown_canonical_provider",
        );
    }
    if (e.requestGroupID !== undefined) {
      requireValue(e.kind === "turnStarted", "group_membership_only_on_turn");
      id(e.requestGroupID);
    }
    if (e.targetAgentIDs !== undefined) {
      requireValue(
        e.kind === "turnStarted" &&
          Array.isArray(e.targetAgentIDs) &&
          e.targetAgentIDs.length > 0 &&
          e.targetAgentIDs.length <= 200,
        "target_membership",
      );
      const ids = e.targetAgentIDs.map(id);
      requireValue(new Set(ids).size === ids.length, "target_membership");
      if (e.agent)
        requireValue(
          ids.includes(String(object(e.agent).id)),
          "agent_not_targeted",
        );
    }
    if (e.turnID !== undefined) id(e.turnID);
    if (e.messageID !== undefined) text(e.messageID, 256);
    if (e.turnPosition !== undefined)
      requireValue(
        Number.isSafeInteger(e.turnPosition) && Number(e.turnPosition) >= 0,
      );
    if (e.scope !== undefined)
      requireValue(["shared", "private", "unknown"].includes(String(e.scope)));
    if (e.selection !== undefined)
      requireValue(
        ["favorite", "negative", "unmarked"].includes(String(e.selection)),
      );
    for (const key of ["text", "method", "reason"])
      if (e[key] !== undefined) text(e[key], key === "text" ? 100000 : 1000);
    if (e.sourceMS !== undefined)
      requireValue(Number.isSafeInteger(e.sourceMS));
    requireValue(e.previousHash === previous, "event_chain_mismatch");
    previous = await hash(canonical(e));
  }
  return chunk;
}
export async function append(
  request: Request,
  env: Env,
  owner: string,
  sid: string,
  revision = 1,
) {
  const s = await ownedSession(env, owner, sid);
  const { value, raw } = await body(request);
  requireValue(canonical(value) === raw, "canonical_bytes_required");
  const chunk = object(value);
  const cid = id(chunk.id);
  const digest = await hash(raw);
  const existing = await env.DB.prepare(
    "SELECT * FROM chunks WHERE session=? AND id=?",
  )
    .bind(sid, cid)
    .first();
  if (existing) {
    requireValue(
      existing.cloud_revision === revision,
      "cloud_revision_mismatch",
      409,
    );
    requireValue(existing.hash === digest, "immutable_chunk_conflict", 409);
    await ownedSession(env, owner, sid);
    return json(existing);
  }
  requireValue(s.current_revision === revision, "cloud_revision_mismatch", 409);
  requireValue(s.status === "open", "session_closed", 409);
  requireValue(
    chunk.sequenceStart === s.next_sequence + 1 &&
      (chunk.previousHash ?? "") === s.last_hash,
    "chunk_chain_mismatch",
    409,
  );
  let prior: string | undefined;
  if (s.next_sequence > 0) {
    const tail = await env.DB.prepare(
      "SELECT object_key FROM chunks WHERE session=? ORDER BY end_sequence DESC LIMIT 1",
    )
      .bind(sid)
      .first<{ object_key: string }>();
    requireValue(tail, "missing_chunk", 409);
    const object = await env.CONTENT.get(tail.object_key);
    requireValue(object, "missing_object", 409);
    const parsed = await object.json<{ events: unknown[] }>();
    prior = await hash(canonical(parsed.events.at(-1)));
  }
  await validateChunk(chunk, s, prior);
  const bytes = new TextEncoder().encode(raw).length;
  requireValue(s.bytes + bytes <= 16777216, "session_quota", 429);
  const usage = await env.DB.prepare(
    "SELECT COALESCE(sum(bytes),0) AS n FROM sessions WHERE owner=?",
  )
    .bind(owner)
    .first<{ n: number }>();
  requireValue(usage && usage.n + bytes <= 67108864, "account_quota", 429);
  const key = `sessions/${sid}/${cid}/${digest}`;
  await immutableWrite(env, owner, key, raw, sid);
  try {
    await env.DB.prepare(
      "INSERT INTO chunks(session,id,start_sequence,end_sequence,hash,previous_hash,object_key,bytes,received_at,cloud_revision) VALUES(?,?,?,?,?,?,?,?,?,?)",
    )
      .bind(
        sid,
        cid,
        chunk.sequenceStart,
        chunk.sequenceEnd,
        digest,
        chunk.previousHash ?? "",
        key,
        bytes,
        now(),
        revision,
      )
      .run();
  } catch (error) {
    const concurrent = await env.DB.prepare(
      "SELECT * FROM chunks WHERE session=? AND id=?",
    )
      .bind(sid, cid)
      .first();
    if (concurrent?.hash === digest && concurrent.cloud_revision === revision) {
      await env.DB.prepare("DELETE FROM object_intents WHERE object_key=?")
        .bind(key)
        .run();
      return json(concurrent);
    }
    if (
      error instanceof Error &&
      error.message.includes("chunk_conflict_or_quota")
    )
      throw new HttpError(409, "chunk_conflict_or_quota");
    throw error;
  }
  return json(
    await env.DB.prepare("SELECT * FROM chunks WHERE session=? AND id=?")
      .bind(sid, cid)
      .first(),
    201,
  );
}
