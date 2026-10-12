import { requireService } from "./identity";
import { finalizeManifest, openRevision } from "./sessions";
import { reviseFeedback } from "./feedback";
import { authenticate, mutationOrigin } from "./auth";
import { append, ownedSession, register } from "./ingest";
import { publicRead, publish } from "./publications";
import { contribute, history, statistics, withdraw } from "./contributions";
import { dispatchPending, jobStatement, processJob, reconcile } from "./jobs";
import {
  body,
  HttpError,
  id,
  json,
  keys,
  now,
  object,
  requireValue,
  securityHeaders,
} from "./http";
async function route(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
): Promise<Response> {
  const url = new URL(request.url),
    parts = url.pathname.split("/").filter(Boolean),
    method = request.method;
  requireService(request, env);
  if (method === "GET" && parts[0] === "s") {
    return publicRead(request, env, parts[1] ?? "", parts.slice(2).join("/"));
  }
  if (
    method === "GET" &&
    ["/reader.css", "/reader.js", "/robots.txt"].includes(url.pathname)
  ) {
    const asset = await env.ASSETS.fetch(request);
    const response = new Response(asset.body, asset);
    for (const [k, v] of Object.entries(securityHeaders))
      response.headers.set(k, v);
    return response;
  }
  requireValue(parts[0] === "api" && parts[1] === "v1", "not_found", 404);
  if (method !== "GET") {
    mutationOrigin(request);
    requireValue(
      ["POST", "DELETE"].includes(method),
      "method_not_allowed",
      405,
    );
  }
  const owner = await authenticate(
    request,
    env,
    method === "GET" &&
      parts.length === 4 &&
      parts[2] === "account" &&
      parts[3] === "deletion",
  );
  if (
    parts.length === 4 &&
    parts[2] === "account" &&
    parts[3] === "deletion" &&
    method === "GET"
  ) {
    const deletion = await env.DB.prepare(
      'SELECT created_at,content_cleaned_at,blocked_reason,identity_error,completed_at FROM outbox WHERE kind="deleteAccount" AND target=?',
    )
      .bind(owner)
      .first();
    return json({ accountID: owner, deletion });
  }
  if (parts.length === 3 && parts[2] === "account") {
    if (method === "GET")
      return json({
        accountID: owner,
        identity: "verified OIDC bearer",
        privateSync: "client opt-in required",
        publication: "independent explicit opt-in",
        contribution: "independent explicit opt-in",
      });
    if (method === "DELETE") {
      const stamp = now();
      await env.DB.batch([
        env.DB.prepare("UPDATE accounts SET deleted_at=? WHERE id=?").bind(
          stamp,
          owner,
        ),
        env.DB.prepare(
          'UPDATE sessions SET deleted_at=?,status="deleting" WHERE owner=?',
        ).bind(stamp, owner),
        env.DB.prepare(
          "UPDATE publications SET revoked_at=? WHERE owner=? AND revoked_at IS NULL",
        ).bind(stamp, owner),
        env.DB.prepare(
          "UPDATE contribution_revisions SET withdrawn_at=? WHERE session IN(SELECT id FROM sessions WHERE owner=?) AND withdrawn_at IS NULL",
        ).bind(stamp, owner),
        jobStatement(env, "deleteAccount", owner),
      ]);
      ctx.waitUntil(dispatchPending(env));
      return json(
        {
          status: "tombstoned",
          contentCleanup: "pending",
          managedIdentityDeletion:
            env.SERVICE_MODE === "live"
              ? "pending"
              : "blocked: management adapter unprovisioned",
        },
        202,
      );
    }
  }
  if (parts.length === 3 && parts[2] === "contributions" && method === "GET")
    return history(env, owner);
  if (parts.length === 3 && parts[2] === "statistics" && method === "GET")
    return statistics(env);
  if (parts[2] === "publications") {
    if (parts.length === 3 && method === "POST")
      return publish(request, env, owner);
    if (parts.length === 3 && method === "GET")
      return json(
        (
          await env.DB.prepare(
            "SELECT id,session,projection_hash,created_at,revoked_at FROM publications WHERE owner=?",
          )
            .bind(owner)
            .all()
        ).results,
      );
    if (parts.length === 4 && method === "DELETE") {
      const pid = id(parts[3]);
      const p = await env.DB.prepare(
        "SELECT id FROM publications WHERE id=? AND owner=?",
      )
        .bind(pid, owner)
        .first();
      requireValue(p, "not_found", 404);
      await env.DB.batch([
        env.DB.prepare(
          "UPDATE publications SET revoked_at=? WHERE id=? AND revoked_at IS NULL",
        ).bind(now(), pid),
        jobStatement(env, "deletePublication", pid),
      ]);
      ctx.waitUntil(dispatchPending(env));
      return json({ status: "revoked" });
    }
  }
  if (parts[2] === "sessions") {
    if (parts.length === 3 && method === "POST")
      return register(request, env, owner);
    if (parts.length === 3 && method === "GET")
      return json(
        (
          await env.DB.prepare(
            "SELECT id,local_id,purpose,fixture,context,status,current_revision,next_sequence,last_hash,bytes,created_at FROM sessions WHERE owner=? AND deleted_at IS NULL ORDER BY created_at DESC",
          )
            .bind(owner)
            .all()
        ).results,
      );
    const sid = id(parts[3]);
    const s = await ownedSession(env, owner, sid);
    if (parts.length === 4 && method === "GET")
      return json({
        ...s,
        verification: "server-registered; not independently witnessed",
      });
    if (parts.length === 4 && method === "DELETE") {
      const stamp = now();
      await env.DB.batch([
        env.DB.prepare(
          'UPDATE sessions SET deleted_at=?,status="deleting" WHERE id=?',
        ).bind(stamp, sid),
        env.DB.prepare(
          "UPDATE publications SET revoked_at=? WHERE owner=? AND (session=? OR local_id=?) AND revoked_at IS NULL",
        ).bind(stamp, owner, sid, s.local_id),
        env.DB.prepare(
          "UPDATE contribution_revisions SET withdrawn_at=? WHERE session=? AND withdrawn_at IS NULL",
        ).bind(stamp, sid),
        jobStatement(env, "deleteSession", sid),
      ]);
      ctx.waitUntil(dispatchPending(env));
      return json({ status: "tombstoned", cleanup: "pending" }, 202);
    }
    if (parts.length === 5 && parts[4] === "revisions" && method === "POST")
      return openRevision(request, env, owner, sid);
    if (parts.length === 5 && parts[4] === "snapshots" && method === "GET")
      return json(
        (
          await env.DB.prepare(
            "SELECT id AS snapshotID,revision,sequence_end AS sequenceEnd,hash,created_at FROM snapshots WHERE session=? ORDER BY revision",
          )
            .bind(sid)
            .all()
        ).results,
      );
    if (
      parts.length === 7 &&
      parts[4] === "snapshots" &&
      parts[6] === "validation" &&
      method === "GET"
    ) {
      const head = await env.DB.prepare(
        "SELECT id FROM snapshots WHERE id=? AND session=?",
      )
        .bind(id(parts[5]), sid)
        .first();
      requireValue(head, "not_found", 404);
      const v = await env.DB.prepare(
        "SELECT * FROM snapshot_validations WHERE snapshot=?",
      )
        .bind(id(parts[5]))
        .first();
      const job = await env.DB.prepare(
        "SELECT blocked_reason FROM outbox WHERE kind='validate' AND target=?",
      )
        .bind(id(parts[5]))
        .first<{ blocked_reason: string | null }>();
      return json(
        v
          ? {
              ...v,
              reasons: JSON.parse(String(v.reasons)),
              metrics: JSON.parse(String(v.metrics)),
            }
          : {
              status: job?.blocked_reason ? "blocked" : "pending",
              blocked_reason: job?.blocked_reason ?? null,
            },
      );
    }
    if (parts.length === 7 && parts[4] === "revisions") {
      const revision = Number(parts[5]);
      requireValue(
        Number.isSafeInteger(revision) && revision >= 1 && revision <= 1000,
        "invalid_revision",
      );
      if (parts[6] === "chunks" && method === "POST")
        return append(request, env, owner, sid, revision);
      if (parts[6] === "finalize" && method === "POST") {
        const b = object((await body(request, 4096)).value);
        keys(b, ["sequenceEnd", "hash"]);
        const head = await finalizeManifest(
          env,
          owner,
          s,
          { sequenceEnd: b.sequenceEnd, hash: b.hash },
          revision,
        );
        ctx.waitUntil(dispatchPending(env));
        return json(
          {
            sessionID: sid,
            revision,
            snapshotID: head.id,
            sequenceEnd: head.sequence_end,
            hash: head.hash,
            status: "pending-validation",
          },
          202,
        );
      }
    }
    if (parts.length === 5 && parts[4] === "chunks" && method === "POST")
      return append(request, env, owner, sid);
    if (parts.length === 6 && parts[4] === "chunks" && method === "GET") {
      const receipt = await env.DB.prepare(
        "SELECT id,start_sequence,end_sequence,hash,previous_hash,bytes,received_at FROM chunks WHERE session=? AND id=?",
      )
        .bind(sid, id(parts[5]))
        .first();
      requireValue(receipt, "not_found", 404);
      return json(receipt);
    }
    if (parts.length === 5 && parts[4] === "finalize" && method === "POST") {
      const b = object((await body(request, 4096)).value);
      keys(b, ["sequenceEnd", "hash"]);
      const head = await finalizeManifest(env, owner, s, {
        sequenceEnd: b.sequenceEnd,
        hash: b.hash,
      });
      ctx.waitUntil(dispatchPending(env));
      return json(
        {
          status: "pending-validation",
          sessionID: sid,
          revision: head.revision,
          snapshotID: head.id,
          sequenceEnd: head.sequence_end,
          hash: head.hash,
        },
        202,
      );
    }
    if (parts.length === 5 && parts[4] === "validation" && method === "GET") {
      const v = await env.DB.prepare(
        "SELECT v.*,p.session FROM snapshots p JOIN snapshot_validations v ON v.snapshot=p.id WHERE p.session=? AND p.revision=(SELECT max(revision) FROM snapshots WHERE session=p.session)",
      )
        .bind(sid)
        .first();
      const job = await env.DB.prepare(
        "SELECT blocked_reason FROM outbox WHERE kind='validate' AND target=(SELECT id FROM snapshots WHERE session=? ORDER BY revision DESC LIMIT 1)",
      )
        .bind(sid)
        .first<{ blocked_reason: string | null }>();
      return json(
        v
          ? {
              ...v,
              reasons: JSON.parse(String(v.reasons)),
              metrics: JSON.parse(String(v.metrics)),
            }
          : {
              status: job?.blocked_reason ? "blocked" : "pending",
              blocked_reason: job?.blocked_reason ?? null,
            },
      );
    }
    if (parts.length === 5 && parts[4] === "feedback" && method === "POST")
      return reviseFeedback(request, env, owner, sid, ctx);
    if (parts.length === 5 && parts[4] === "contribution") {
      if (method === "POST") return contribute(request, env, owner, sid);
      if (method === "DELETE") return withdraw(env, owner, sid);
    }
  }
  throw new HttpError(404, "not_found");
}
export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext) {
    try {
      return await route(request, env, ctx);
    } catch (error) {
      if (error instanceof HttpError) {
        if (new URL(request.url).pathname.startsWith("/s/"))
          return new Response(
            '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/reader.css"><title>Comparison unavailable</title><main><h1>Comparison unavailable</h1><p>This link may have been revoked or deleted.</p></main></html>',
            {
              status: error.status,
              headers: {
                ...securityHeaders,
                "content-type": "text/html; charset=utf-8",
              },
            },
          );
        return json({ error: error.code }, error.status);
      }
      // Do not log exception text, request URLs, subjects, tokens or bodies. Binding errors may contain private SQL values.
      console.error(
        JSON.stringify({
          event: "request_failed",
          requestID: crypto.randomUUID(),
        }),
      );
      return json({ error: "temporarily_unavailable" }, 503);
    }
  },
  async queue(batch: MessageBatch<{ id: string }>, env: Env) {
    for (const message of batch.messages) {
      try {
        await processJob(env, id(message.body.id));
        message.ack();
      } catch {
        console.error(JSON.stringify({ event: "job_retry" }));
        message.retry({ delaySeconds: 30 });
      }
    }
  },
  async scheduled(
    _controller: ScheduledController,
    env: Env,
    ctx: ExecutionContext,
  ) {
    ctx.waitUntil(reconcile(env));
  },
} satisfies ExportedHandler<Env, { id: string }>;
