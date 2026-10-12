import { reconcileObjects } from "./objects";
import { now, requireValue } from "./http";
import { Session } from "./ingest";
import { validateSession } from "./validation";
interface Job {
  id: string;
  kind: string;
  target: string;
  completed_at: string | null;
  generation: number;
  content_cleaned_at: string | null;
  blocked_reason: string | null;
}
export function jobStatement(env: Env, kind: string, target: string) {
  return env.DB.prepare(
    "INSERT INTO outbox(id,kind,target,created_at) VALUES(?,?,?,?) ON CONFLICT(kind,target) DO UPDATE SET generation=generation+1,completed_at=NULL",
  ).bind(crypto.randomUUID(), kind, target, now());
}
export async function dispatchPending(env: Env) {
  const jobs = await env.DB.prepare(
    "SELECT id FROM outbox WHERE completed_at IS NULL AND blocked_reason IS NULL ORDER BY created_at LIMIT 100",
  ).all<{ id: string }>();
  for (const job of jobs.results)
    await env.JOBS.send({ id: job.id }, { contentType: "json" });
}
async function cleanPendingObjects(
  env: Env,
  owner: string | null,
  session: string | null,
) {
  const rows = await env.DB.prepare(
    "SELECT object_key FROM object_intents WHERE (? IS NOT NULL AND owner=?) OR (? IS NOT NULL AND session=?)",
  )
    .bind(owner, owner, session, session)
    .all<{ object_key: string }>();
  for (const row of rows.results) {
    await env.CONTENT.delete(row.object_key);
    await env.DB.prepare("DELETE FROM object_intents WHERE object_key=?")
      .bind(row.object_key)
      .run();
  }
}
async function deletePrefix(env: Env, prefix: string) {
  let cursor: string | undefined;
  do {
    const page = await env.CONTENT.list({ prefix, cursor, limit: 100 });
    if (page.objects.length)
      await env.CONTENT.delete(page.objects.map((o) => o.key));
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
}
export async function processJob(env: Env, jid: string) {
  const job = await env.DB.prepare("SELECT * FROM outbox WHERE id=?")
    .bind(jid)
    .first<Job>();
  if (!job || job.completed_at) return;
  if (job.kind === "validate") {
    const s = await env.DB.prepare(
      'SELECT s.* FROM sessions s JOIN accounts a ON a.id=s.owner WHERE s.id=? AND s.deleted_at IS NULL AND a.deleted_at IS NULL AND s.status="finalized"',
    )
      .bind(job.target)
      .first<Session>();
    if (s) {
      const v = await validateSession(env, s);
      await env.DB.prepare(
        "INSERT INTO validations(session,completeness,eligible,reasons,metrics,validated_at) SELECT ?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM sessions s JOIN accounts a ON a.id=s.owner WHERE s.id=? AND s.deleted_at IS NULL AND a.deleted_at IS NULL AND EXISTS(SELECT 1 FROM outbox WHERE id=? AND generation=? AND completed_at IS NULL)) ON CONFLICT(session) DO UPDATE SET completeness=excluded.completeness,eligible=excluded.eligible,reasons=excluded.reasons,metrics=excluded.metrics,validated_at=excluded.validated_at",
      )
        .bind(
          s.id,
          v.completeness,
          Number(v.eligible),
          JSON.stringify(v.reasons),
          JSON.stringify(v.metrics),
          now(),
          s.id,
          jid,
          job.generation,
        )
        .run();
    }
  } else if (job.kind === "deletePublication") {
    const p = await env.DB.prepare(
      "SELECT id FROM publications WHERE id=? AND revoked_at IS NOT NULL",
    )
      .bind(job.target)
      .first();
    requireValue(p, "deletion_not_tombstoned", 409);
    await deletePrefix(env, `publications/${job.target}/`);
    await env.DB.prepare("UPDATE publications SET bytes=0 WHERE id=?")
      .bind(job.target)
      .run();
  } else if (job.kind === "deleteSession") {
    const s = await env.DB.prepare(
      "SELECT id FROM sessions WHERE id=? AND deleted_at IS NOT NULL",
    )
      .bind(job.target)
      .first();
    requireValue(s, "deletion_not_tombstoned", 409);
    await deletePrefix(env, `sessions/${job.target}/`);
    await cleanPendingObjects(env, null, job.target);
    const pubs = await env.DB.prepare(
      "SELECT id FROM publications WHERE session=?",
    )
      .bind(job.target)
      .all<{ id: string }>();
    for (const p of pubs.results) {
      await deletePrefix(env, `publications/${p.id}/`);
      await env.DB.prepare("UPDATE publications SET bytes=0 WHERE id=?")
        .bind(p.id)
        .run();
    }
    await env.DB.batch([
      env.DB.prepare("UPDATE sessions SET bytes=0 WHERE id=?").bind(job.target),
      env.DB.prepare("DELETE FROM chunks WHERE session=?").bind(job.target),
      env.DB.prepare("DELETE FROM validations WHERE session=?").bind(
        job.target,
      ),
      env.DB.prepare("DELETE FROM contribution_revisions WHERE session=?").bind(
        job.target,
      ),
      env.DB.prepare("DELETE FROM feedback_revisions WHERE session=?").bind(
        job.target,
      ),
    ]);
  } else if (job.kind === "deleteAccount") {
    const a = await env.DB.prepare(
      "SELECT id FROM accounts WHERE id=? AND deleted_at IS NOT NULL",
    )
      .bind(job.target)
      .first();
    requireValue(a, "deletion_not_tombstoned", 409);
    if (!job.content_cleaned_at) {
      await cleanPendingObjects(env, job.target, null);
      const sessions = await env.DB.prepare(
        "SELECT id FROM sessions WHERE owner=?",
      )
        .bind(job.target)
        .all<{ id: string }>();
      for (const s of sessions.results)
        await deletePrefix(env, `sessions/${s.id}/`);
      const pubs = await env.DB.prepare(
        "SELECT id FROM publications WHERE owner=?",
      )
        .bind(job.target)
        .all<{ id: string }>();
      for (const p of pubs.results) {
        await deletePrefix(env, `publications/${p.id}/`);
        await env.DB.prepare("UPDATE publications SET bytes=0 WHERE id=?")
          .bind(p.id)
          .run();
      }
      await env.DB.batch([
        env.DB.prepare("UPDATE sessions SET bytes=0 WHERE owner=?").bind(
          job.target,
        ),
        env.DB.prepare(
          "DELETE FROM validations WHERE session IN(SELECT id FROM sessions WHERE owner=?)",
        ).bind(job.target),
        env.DB.prepare(
          "DELETE FROM contribution_revisions WHERE session IN(SELECT id FROM sessions WHERE owner=?)",
        ).bind(job.target),
        env.DB.prepare(
          "DELETE FROM chunks WHERE session IN(SELECT id FROM sessions WHERE owner=?)",
        ).bind(job.target),
        env.DB.prepare(
          "DELETE FROM feedback_revisions WHERE session IN(SELECT id FROM sessions WHERE owner=?)",
        ).bind(job.target),
      ]);
      await env.DB.prepare(
        "UPDATE outbox SET content_cleaned_at=? WHERE id=? AND generation=?",
      )
        .bind(now(), jid, job.generation)
        .run();
    }
    await env.DB.prepare(
      "UPDATE outbox SET blocked_reason=? WHERE id=? AND generation=?",
    )
      .bind("identity_management_unprovisioned", jid, job.generation)
      .run();
    // Managed identity deletion is deliberately blocked until its management adapter is provisioned.
    // Retain a minimal subject tombstone to prevent re-registration, and keep the deletion job pending.
    return;
  }
  await env.DB.prepare(
    "UPDATE outbox SET completed_at=? WHERE id=? AND generation=?",
  )
    .bind(now(), jid, job.generation)
    .run();
}
export async function reconcile(env: Env) {
  await dispatchPending(env);
  await reconcileObjects(env);
}
