import { body, json, keys, now, object, requireValue, text, id } from "./http";
import { ownedSession } from "./ingest";
import { jobStatement, dispatchPending } from "./jobs";
export async function reviseFeedback(
  request: Request,
  env: Env,
  owner: string,
  sid: string,
  ctx: ExecutionContext,
) {
  const s = await ownedSession(env, owner, sid);
  requireValue(s.status === "finalized", "finalization_required", 409);
  const b = object((await body(request, 4096)).value);
  keys(b, [
    "consent",
    "segmentID",
    "agentID",
    "messageID",
    "revision",
    "selection",
  ]);
  requireValue(b.consent === true, "feedback_upload_consent_required");
  const segment = id(b.segmentID),
    agent = id(b.agentID),
    message = text(b.messageID, 256);
  requireValue(Number.isSafeInteger(b.revision) && Number(b.revision) > 0);
  requireValue(
    ["favorite", "negative", "unmarked"].includes(String(b.selection)),
  );
  const chunks = await env.DB.prepare(
    "SELECT object_key FROM chunks WHERE session=? ORDER BY start_sequence",
  )
    .bind(sid)
    .all<{ object_key: string }>();
  let exists = false;
  for (const c of chunks.results) {
    const stored = await env.CONTENT.get(c.object_key);
    requireValue(stored, "missing_object", 409);
    const chunk = await stored.json<{ events: Record<string, unknown>[] }>();
    if (
      chunk.events.some(
        (e) =>
          e.kind === "replyObserved" &&
          e.segmentID === segment &&
          e.agent &&
          object(e.agent).id === agent &&
          e.messageID === message,
      )
    ) {
      exists = true;
      break;
    }
  }
  requireValue(exists, "reply_not_found", 404);
  const previous = await env.DB.prepare(
    "SELECT revision,selection FROM feedback_revisions WHERE session=? AND segment_id=? AND agent_id=? AND message_id=? ORDER BY revision DESC LIMIT 1",
  )
    .bind(sid, segment, agent, message)
    .first<{ revision: number; selection: string }>();
  if (previous) {
    requireValue(
      Number(b.revision) >= previous.revision,
      "stale_revision",
      409,
    );
    if (Number(b.revision) === previous.revision) {
      requireValue(
        b.selection === previous.selection,
        "immutable_revision_conflict",
        409,
      );
      return json({ status: "registered", revision: b.revision });
    }
  }
  await env.DB.batch([
    env.DB.prepare(
      "INSERT INTO feedback_revisions(session,segment_id,agent_id,message_id,revision,selection,created_at) SELECT ?,?,?,?,?,?,? FROM sessions s JOIN accounts a ON a.id=s.owner WHERE s.id=? AND s.deleted_at IS NULL AND a.deleted_at IS NULL",
    ).bind(sid, segment, agent, message, b.revision, b.selection, now(), sid),
    jobStatement(env, "validate", sid),
  ]);
  ctx.waitUntil(dispatchPending(env));
  return json(
    { status: "registered; revalidation pending", revision: b.revision },
    202,
  );
}
