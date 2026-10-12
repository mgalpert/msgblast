import { requireValue, now } from "./http";
import { Session } from "./ingest";
export async function finalizeManifest(
  env: Env,
  owner: string,
  s: Session,
  manifest: { sequenceEnd: unknown; hash: unknown },
) {
  requireValue(
    s.owner === owner &&
      s.next_sequence > 0 &&
      manifest.sequenceEnd === s.next_sequence &&
      manifest.hash === s.last_hash,
    "incomplete_manifest",
    409,
  );
  const result = await env.DB.batch([
    env.DB.prepare(
      'UPDATE sessions SET status="finalized" WHERE id=? AND owner=? AND deleted_at IS NULL AND next_sequence=? AND last_hash=? AND status IN("open","finalized") AND EXISTS(SELECT 1 FROM accounts WHERE id=? AND deleted_at IS NULL)',
    ).bind(s.id, owner, manifest.sequenceEnd, manifest.hash, owner),
    env.DB.prepare(
      'INSERT INTO outbox(id,kind,target,created_at) SELECT ?,"validate",?,? FROM sessions WHERE id=? AND owner=? AND deleted_at IS NULL AND next_sequence=? AND last_hash=? AND status="finalized" AND EXISTS(SELECT 1 FROM accounts WHERE id=? AND deleted_at IS NULL) ON CONFLICT(kind,target) DO UPDATE SET generation=generation+1,completed_at=NULL',
    ).bind(
      crypto.randomUUID(),
      s.id,
      now(),
      s.id,
      owner,
      manifest.sequenceEnd,
      manifest.hash,
      owner,
    ),
  ]);
  requireValue(result[0].meta.changes > 0, "manifest_changed_or_deleted", 409);
}
