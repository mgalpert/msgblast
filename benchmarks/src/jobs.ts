import { deleteManagedIdentity, identityConfigured } from "./identity";
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
  comparisonOwner: string | null = null,
  localID: string | null = null,
) {
  const rows = await env.DB.prepare(
    "SELECT object_key FROM object_intents WHERE (? IS NOT NULL AND owner=?) OR (? IS NOT NULL AND session=?) OR (? IS NOT NULL AND owner=? AND local_id=?)",
  )
    .bind(owner, owner, session, session, localID, comparisonOwner, localID)
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
    const snapshot = await env.DB.prepare(
      "SELECT p.* FROM snapshots p JOIN sessions s ON s.id=p.session JOIN accounts a ON a.id=s.owner WHERE p.id=? AND s.deleted_at IS NULL AND a.deleted_at IS NULL",
    )
      .bind(job.target)
      .first<{
        id: string;
        session: string;
        revision: number;
        sequence_end: number;
        hash: string;
      }>();
    const s = await env.DB.prepare(
      "SELECT s.* FROM sessions s JOIN accounts a ON a.id=s.owner WHERE s.id=? AND s.deleted_at IS NULL AND a.deleted_at IS NULL",
    )
      .bind(snapshot?.session ?? job.target)
      .first<Session>();
    if (s && (snapshot || s.status === "finalized")) {
      const frozen = snapshot
        ? {
            ...s,
            next_sequence: snapshot.sequence_end,
            last_hash: snapshot.hash,
          }
        : s;
      const v = await validateSession(env, frozen, Boolean(snapshot));
      const stamp = now();
      const args = [
        v.completeness,
        Number(v.eligible),
        JSON.stringify(v.reasons),
        JSON.stringify(v.metrics),
        stamp,
      ];
      const requiredBytes =
        new TextEncoder().encode(String(args[2]) + String(args[3])).length +
        500;
      if (requiredBytes > 1048576) {
        await env.DB.prepare(
          "UPDATE outbox SET blocked_reason='validation_record_limit',required_validation_bytes=? WHERE id=? AND generation=?",
        )
          .bind(requiredBytes, jid, job.generation)
          .run();
        return;
      }
      const fence =
        "EXISTS(SELECT 1 FROM sessions s JOIN accounts a ON a.id=s.owner WHERE s.id=? AND s.deleted_at IS NULL AND a.deleted_at IS NULL) AND EXISTS(SELECT 1 FROM outbox WHERE id=? AND generation=? AND completed_at IS NULL)";
      if (snapshot) {
        try {
          await env.DB.prepare(
            `INSERT OR IGNORE INTO snapshot_validations(snapshot,completeness,eligible,reasons,metrics,validated_at) SELECT ?,?,?,?,?,? WHERE ${fence}`,
          )
            .bind(snapshot.id, ...args, s.id, jid, job.generation)
            .run();
        } catch (error) {
          if (
            !(error instanceof Error) ||
            !error.message.includes("validation_storage_quota")
          )
            throw error;
          await env.DB.prepare(
            "UPDATE outbox SET blocked_reason='validation_storage_quota',required_validation_bytes=? WHERE id=? AND generation=?",
          )
            .bind(requiredBytes, jid, job.generation)
            .run();
          return;
        }
      }
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
      "SELECT id,owner,local_id FROM sessions WHERE id=? AND deleted_at IS NOT NULL",
    )
      .bind(job.target)
      .first<{ id: string; owner: string; local_id: string }>();
    requireValue(s, "deletion_not_tombstoned", 409);
    await deletePrefix(env, `sessions/${job.target}/`);
    await cleanPendingObjects(env, null, job.target, s.owner, s.local_id);
    const pubs = await env.DB.prepare(
      "SELECT id FROM publications WHERE owner=? AND (session=? OR local_id=?)",
    )
      .bind(s.owner, job.target, s.local_id)
      .all<{ id: string }>();
    for (const p of pubs.results) {
      await deletePrefix(env, `publications/${p.id}/`);
      await env.DB.prepare("UPDATE publications SET bytes=0 WHERE id=?")
        .bind(p.id)
        .run();
    }
    await env.DB.batch([
      env.DB.prepare("UPDATE sessions SET bytes=0 WHERE id=?").bind(job.target),
      env.DB.prepare(
        "DELETE FROM snapshot_validations WHERE snapshot IN(SELECT id FROM snapshots WHERE session=?)",
      ).bind(job.target),
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
      env.DB.prepare(
        "DELETE FROM legacy_feedback_baselines WHERE session=?",
      ).bind(job.target),
      env.DB.prepare("DELETE FROM snapshots WHERE session=?").bind(job.target),
      env.DB.prepare("DELETE FROM session_revisions WHERE session=?").bind(
        job.target,
      ),
    ]);
  } else if (job.kind === "deleteAccount") {
    const a = await env.DB.prepare(
      "SELECT id,issuer,subject FROM accounts WHERE id=? AND deleted_at IS NOT NULL",
    )
      .bind(job.target)
      .first<{ id: string; issuer: string; subject: string }>();
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
        env.DB.prepare(
          "DELETE FROM snapshot_validations WHERE snapshot IN(SELECT p.id FROM snapshots p JOIN sessions s ON s.id=p.session WHERE s.owner=?)",
        ).bind(job.target),
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
        env.DB.prepare(
          "DELETE FROM legacy_feedback_baselines WHERE session IN(SELECT id FROM sessions WHERE owner=?)",
        ).bind(job.target),
        env.DB.prepare(
          "DELETE FROM snapshots WHERE session IN(SELECT id FROM sessions WHERE owner=?)",
        ).bind(job.target),
        env.DB.prepare(
          "DELETE FROM session_revisions WHERE session IN(SELECT id FROM sessions WHERE owner=?)",
        ).bind(job.target),
      ]);
      await env.DB.prepare(
        "UPDATE outbox SET content_cleaned_at=? WHERE id=? AND generation=?",
      )
        .bind(now(), jid, job.generation)
        .run();
    }
    if (!identityConfigured(env)) {
      await env.DB.prepare(
        "UPDATE outbox SET blocked_reason=? WHERE id=? AND generation=?",
      )
        .bind("identity_management_unprovisioned", jid, job.generation)
        .run();
      return;
    }
    try {
      await deleteManagedIdentity(env, a);
    } catch {
      // Keep retryable jobs dispatchable; the status is truthful without retaining provider error bodies.
      await env.DB.prepare(
        "UPDATE outbox SET blocked_reason=NULL,identity_error='identity_provider_failed_retrying' WHERE id=? AND generation=?",
      )
        .bind(jid, job.generation)
        .run();
      throw new Error("identity_delete_retry");
    }
  }
  await env.DB.prepare(
    "UPDATE outbox SET completed_at=?,identity_error=NULL WHERE id=? AND generation=?",
  )
    .bind(now(), jid, job.generation)
    .run();
}
export async function reconcile(env: Env) {
  if (identityConfigured(env))
    await env.DB.prepare(
      "UPDATE outbox SET blocked_reason=NULL WHERE kind='deleteAccount' AND blocked_reason='identity_management_unprovisioned' AND completed_at IS NULL",
    ).run();
  await env.DB.prepare(
    "UPDATE outbox SET blocked_reason=NULL WHERE blocked_reason='validation_storage_quota' AND required_validation_bytes+COALESCE((SELECT sum(length(CAST(v.metrics AS BLOB))+length(CAST(v.reasons AS BLOB))+500) FROM snapshot_validations v JOIN snapshots p ON p.id=v.snapshot JOIN sessions s ON s.id=p.session WHERE s.owner=(SELECT s2.owner FROM snapshots p2 JOIN sessions s2 ON s2.id=p2.session WHERE p2.id=outbox.target)),0)<=16777216",
  ).run();
  await dispatchPending(env);
  await reconcileObjects(env);
}
