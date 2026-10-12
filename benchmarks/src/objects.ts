import { now, requireValue, HttpError } from "./http";
export async function immutableWrite(
  env: Env,
  owner: string,
  key: string,
  bytes: string,
  relatedSession: string | null = null,
) {
  // Renew a durable upload lease before touching R2. Reconciliation claims old leases atomically,
  // so a cleanup cannot race a receipt commit from a retry of the same immutable object.
  const size = new TextEncoder().encode(bytes).length;
  try {
    await env.DB.prepare(
      'INSERT OR IGNORE INTO object_intents(object_key,owner,session,bytes,state,updated_at) VALUES(?,?,?,?,"uploading",?)',
    )
      .bind(key, owner, relatedSession, size, now())
      .run();
  } catch (error) {
    if (
      error instanceof Error &&
      error.message.includes("pending_object_quota")
    )
      throw new HttpError(429, "pending_object_quota");
    throw error;
  }
  await env.DB.prepare(
    'UPDATE object_intents SET updated_at=? WHERE object_key=? AND owner=? AND bytes=? AND state="uploading"',
  )
    .bind(now(), key, owner, size)
    .run();
  const intent = await env.DB.prepare(
    "SELECT state FROM object_intents WHERE object_key=? AND owner=? AND bytes=?",
  )
    .bind(key, owner, size)
    .first<{ state: string }>();
  requireValue(
    intent?.state === "uploading",
    "object_reconciliation_pending",
    409,
  );
  await env.CONTENT.put(key, bytes, {
    onlyIf: { etagDoesNotMatch: "*" },
    httpMetadata: { contentType: "application/json" },
  });
  const active = await env.DB.prepare(
    "SELECT id FROM accounts WHERE id=? AND deleted_at IS NULL AND (? IS NULL OR EXISTS(SELECT 1 FROM sessions WHERE id=? AND owner=? AND deleted_at IS NULL))",
  )
    .bind(owner, relatedSession, relatedSession, owner)
    .first();
  if (!active) {
    try {
      await env.CONTENT.delete(key);
      await env.DB.prepare("DELETE FROM object_intents WHERE object_key=?")
        .bind(key)
        .run();
    } catch {
      await env.DB.prepare(
        'INSERT INTO object_intents(object_key,owner,session,bytes,state,updated_at) VALUES(?,?,?,?,"deleting",?) ON CONFLICT(object_key) DO UPDATE SET state="deleting",updated_at=excluded.updated_at',
      )
        .bind(key, owner, relatedSession, size, now())
        .run();
      await env.DB.prepare(
        'UPDATE outbox SET completed_at=NULL,content_cleaned_at=NULL,blocked_reason=NULL,generation=generation+1 WHERE (kind="deleteAccount" AND target=?) OR (kind="deleteSession" AND target=?)',
      )
        .bind(owner, relatedSession)
        .run();
    }
    throw new HttpError(410, "owner_or_session_deleted");
  }
}
export async function reconcileObjects(env: Env) {
  const cutoff = new Date(Date.now() - 86400000).toISOString();
  const intents = await env.DB.prepare(
    'SELECT object_key FROM object_intents WHERE updated_at<? OR state="deleting" LIMIT 100',
  )
    .bind(cutoff)
    .all<{ object_key: string }>();
  for (const row of intents.results) {
    const claimed = await env.DB.prepare(
      'UPDATE object_intents SET state="deleting" WHERE object_key=? AND (updated_at<? OR state="deleting")',
    )
      .bind(row.object_key, cutoff)
      .run();
    if (!claimed.meta.changes) continue;
    const committed = await env.DB.prepare(
      "SELECT object_key FROM chunks WHERE object_key=? UNION ALL SELECT object_key FROM publications WHERE object_key=? LIMIT 1",
    )
      .bind(row.object_key, row.object_key)
      .first();
    if (!committed) await env.CONTENT.delete(row.object_key);
    await env.DB.prepare(
      'DELETE FROM object_intents WHERE object_key=? AND state="deleting"',
    )
      .bind(row.object_key)
      .run();
  }
}
