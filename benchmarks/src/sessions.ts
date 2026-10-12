import {
  body,
  id,
  json,
  keys,
  object,
  requireValue,
  now,
  HttpError,
} from "./http";
import { ownedSession, Session } from "./ingest";
export interface Snapshot {
  id: string;
  session: string;
  revision: number;
  sequence_end: number;
  hash: string;
  created_at: string;
}
export async function openRevision(
  request: Request,
  env: Env,
  owner: string,
  sid: string,
) {
  const s = await ownedSession(env, owner, sid);
  const b = object((await body(request, 4096)).value);
  keys(b, ["consent", "requestID", "parentHash", "parentSequenceEnd"]);
  requireValue(b.consent === true, "upload_consent_required");
  const rid = id(b.requestID);
  const existing = await env.DB.prepare(
    "SELECT r.* FROM session_revisions r JOIN sessions s ON s.id=r.session JOIN accounts a ON a.id=s.owner WHERE r.session=? AND r.request_id=? AND s.deleted_at IS NULL AND a.deleted_at IS NULL",
  )
    .bind(sid, rid)
    .first<{
      revision: number;
      parent_hash: string;
      parent_sequence: number;
    }>();
  if (existing) {
    requireValue(
      existing.parent_hash === b.parentHash &&
        existing.parent_sequence === b.parentSequenceEnd,
      "revision_request_conflict",
      409,
    );
    return json({
      sessionID: sid,
      revision: existing.revision,
      parentHash: existing.parent_hash,
      parentSequenceEnd: existing.parent_sequence,
      status: "open",
    });
  }
  requireValue(
    s.status === "finalized" &&
      s.last_hash === b.parentHash &&
      s.next_sequence === b.parentSequenceEnd,
    "parent_snapshot_mismatch",
    409,
  );
  requireValue(s.current_revision < 1000, "revision_limit", 429);
  const revision = s.current_revision + 1;
  await env.DB.batch([
    env.DB.prepare(
      "INSERT OR IGNORE INTO session_revisions(session,revision,request_id,parent_hash,parent_sequence,created_at) SELECT id,?,?,?,?,? FROM sessions WHERE id=? AND owner=? AND deleted_at IS NULL AND status='finalized' AND current_revision=? AND next_sequence=? AND last_hash=? AND EXISTS(SELECT 1 FROM accounts WHERE id=? AND deleted_at IS NULL) AND EXISTS(SELECT 1 FROM snapshots WHERE session=? AND revision=? AND hash=? AND sequence_end=?)",
    ).bind(
      revision,
      rid,
      b.parentHash,
      b.parentSequenceEnd,
      now(),
      sid,
      owner,
      s.current_revision,
      b.parentSequenceEnd,
      b.parentHash,
      owner,
      sid,
      s.current_revision,
      b.parentHash,
      b.parentSequenceEnd,
    ),
    env.DB.prepare(
      "UPDATE sessions SET current_revision=?,status='open' WHERE id=? AND owner=? AND deleted_at IS NULL AND current_revision=? AND status='finalized' AND EXISTS(SELECT 1 FROM accounts WHERE id=? AND deleted_at IS NULL) AND EXISTS(SELECT 1 FROM session_revisions WHERE session=? AND revision=? AND request_id=?)",
    ).bind(revision, sid, owner, s.current_revision, owner, sid, revision, rid),
  ]);
  const saved = await env.DB.prepare(
    "SELECT r.revision FROM session_revisions r JOIN sessions s ON s.id=r.session JOIN accounts a ON a.id=s.owner WHERE r.session=? AND r.request_id=? AND s.deleted_at IS NULL AND a.deleted_at IS NULL",
  )
    .bind(sid, rid)
    .first<{ revision: number }>();
  requireValue(saved, "revision_changed_or_deleted", 409);
  return json(
    {
      sessionID: sid,
      revision: saved.revision,
      parentHash: b.parentHash,
      parentSequenceEnd: b.parentSequenceEnd,
      status: "open",
    },
    201,
  );
}
export async function finalizeManifest(
  env: Env,
  owner: string,
  s: Session,
  manifest: { sequenceEnd: unknown; hash: unknown },
  revision = 1,
) {
  const existing = await env.DB.prepare(
    "SELECT p.* FROM snapshots p JOIN sessions s ON s.id=p.session JOIN accounts a ON a.id=s.owner WHERE p.session=? AND p.revision=? AND s.owner=? AND s.deleted_at IS NULL AND a.deleted_at IS NULL",
  )
    .bind(s.id, revision, owner)
    .first<Snapshot>();
  if (existing) {
    requireValue(
      existing.hash === manifest.hash &&
        existing.sequence_end === manifest.sequenceEnd,
      "snapshot_conflict",
      409,
    );
    return existing;
  }
  requireValue(
    s.owner === owner &&
      s.current_revision === revision &&
      s.status === "open" &&
      s.next_sequence > 0 &&
      manifest.sequenceEnd === s.next_sequence &&
      manifest.hash === s.last_hash,
    "incomplete_manifest",
    409,
  );
  const count = await env.DB.prepare(
    "SELECT count(*) AS n FROM snapshots p JOIN sessions s ON s.id=p.session WHERE s.owner=?",
  )
    .bind(owner)
    .first<{ n: number }>();
  requireValue(count && count.n < 1000, "snapshot_quota", 429);
  const snapshotID = crypto.randomUUID(),
    stamp = now();
  try {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT OR IGNORE INTO snapshots(id,session,revision,sequence_end,hash,created_at) SELECT ?,id,?,?,?,? FROM sessions WHERE id=? AND owner=? AND deleted_at IS NULL AND current_revision=? AND next_sequence=? AND last_hash=? AND status='open' AND EXISTS(SELECT 1 FROM accounts WHERE id=? AND deleted_at IS NULL)",
      ).bind(
        snapshotID,
        revision,
        manifest.sequenceEnd,
        manifest.hash,
        stamp,
        s.id,
        owner,
        revision,
        manifest.sequenceEnd,
        manifest.hash,
        owner,
      ),
      env.DB.prepare(
        "UPDATE sessions SET status='finalized' WHERE id=? AND owner=? AND deleted_at IS NULL AND current_revision=? AND EXISTS(SELECT 1 FROM snapshots WHERE session=? AND revision=? AND sequence_end=? AND hash=?)",
      ).bind(
        s.id,
        owner,
        revision,
        s.id,
        revision,
        manifest.sequenceEnd,
        manifest.hash,
      ),
      env.DB.prepare(
        "INSERT OR IGNORE INTO outbox(id,kind,target,created_at) SELECT ?,'validate',id,? FROM snapshots WHERE session=? AND revision=? AND sequence_end=? AND hash=? AND EXISTS(SELECT 1 FROM sessions s JOIN accounts a ON a.id=s.owner WHERE s.id=? AND s.deleted_at IS NULL AND a.deleted_at IS NULL)",
      ).bind(
        crypto.randomUUID(),
        stamp,
        s.id,
        revision,
        manifest.sequenceEnd,
        manifest.hash,
        s.id,
      ),
    ]);
  } catch (error) {
    if (error instanceof Error && error.message.includes("snapshot_quota"))
      throw new HttpError(429, "snapshot_quota");
    throw error;
  }
  const saved = await env.DB.prepare(
    "SELECT p.* FROM snapshots p JOIN sessions s ON s.id=p.session JOIN accounts a ON a.id=s.owner WHERE p.session=? AND p.revision=? AND s.deleted_at IS NULL AND a.deleted_at IS NULL",
  )
    .bind(s.id, revision)
    .first<Snapshot>();
  requireValue(
    saved &&
      saved.hash === manifest.hash &&
      saved.sequence_end === manifest.sequenceEnd,
    "manifest_changed_or_deleted",
    409,
  );
  return saved;
}
