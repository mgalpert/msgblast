import { observationMethod } from "./providers";
import { body, json, keys, now, object, requireValue } from "./http";
import { ownedSession } from "./ingest";
import { Validation } from "./validation";
export async function contribute(
  request: Request,
  env: Env,
  owner: string,
  sid: string,
) {
  const s = await ownedSession(env, owner, sid);

  const b = object((await body(request, 4096)).value);
  keys(b, ["consent", "revision", "snapshotID"]);
  const snapshot = await env.DB.prepare(
    "SELECT id FROM snapshots WHERE session=? AND " +
      (b.snapshotID === undefined ? "revision=1" : "id=?"),
  )
    .bind(sid, ...(b.snapshotID === undefined ? [] : [String(b.snapshotID)]))
    .first<{ id: string }>();
  requireValue(snapshot, "finalization_required", 409);
  requireValue(
    b.snapshotID !== undefined || s.current_revision === 1,
    "snapshot_selection_required",
    409,
  );
  requireValue(b.consent === true, "contribution_consent_required");
  requireValue(
    Number.isSafeInteger(b.revision) &&
      Number(b.revision) >= 1 &&
      Number(b.revision) <= 10000,
  );
  const latest = await env.DB.prepare(
    "SELECT revision,withdrawn_at,snapshot FROM contribution_revisions WHERE session=? ORDER BY revision DESC LIMIT 1",
  )
    .bind(sid)
    .first<{
      revision: number;
      withdrawn_at: string | null;
      snapshot: string;
    }>();
  requireValue(
    !latest || Number(b.revision) >= latest.revision,
    "stale_revision",
    409,
  );
  requireValue(
    !latest || Number(b.revision) !== latest.revision || !latest.withdrawn_at,
    "withdrawn_revision",
    409,
  );
  requireValue(
    !latest ||
      latest.revision !== Number(b.revision) ||
      latest.snapshot === snapshot.id,
    "contribution_snapshot_conflict",
    409,
  );
  await env.DB.prepare(
    "INSERT OR IGNORE INTO contribution_revisions(id,session,revision,requested_at,snapshot) SELECT ?,?,?,?,? FROM sessions s JOIN accounts a ON a.id=s.owner WHERE s.id=? AND s.deleted_at IS NULL AND a.deleted_at IS NULL",
  )
    .bind(crypto.randomUUID(), sid, b.revision, now(), snapshot.id, sid)
    .run();
  const registered = await env.DB.prepare(
    "SELECT c.snapshot FROM contribution_revisions c JOIN sessions s ON s.id=c.session JOIN accounts a ON a.id=s.owner WHERE c.session=? AND c.revision=? AND c.withdrawn_at IS NULL AND s.deleted_at IS NULL AND a.deleted_at IS NULL",
  )
    .bind(sid, b.revision)
    .first<{ snapshot: string }>();
  requireValue(
    registered && registered.snapshot === snapshot.id,
    "contribution_changed_or_deleted",
    409,
  );
  return json(
    {
      sessionID: sid,
      revision: b.revision,
      snapshotID: snapshot.id,
      status: "validation-dependent",
      selection: "voluntary-selected-sample",
    },
    202,
  );
}
export async function withdraw(env: Env, owner: string, sid: string) {
  await ownedSession(env, owner, sid);
  await env.DB.prepare(
    "UPDATE contribution_revisions SET withdrawn_at=? WHERE session=? AND withdrawn_at IS NULL",
  )
    .bind(now(), sid)
    .run();
  return json({ status: "withdrawn", sessionID: sid });
}
export async function history(env: Env, owner: string) {
  const rows = await env.DB.prepare(
    "SELECT c.session,c.revision,c.snapshot AS snapshotID,j.blocked_reason,c.requested_at,c.withdrawn_at,v.completeness,v.eligible,v.reasons,v.metrics,v.validated_at,s.fixture FROM contribution_revisions c JOIN sessions s ON s.id=c.session LEFT JOIN snapshot_validations v ON v.snapshot=c.snapshot LEFT JOIN outbox j ON j.kind='validate' AND j.target=c.snapshot WHERE s.owner=? AND s.deleted_at IS NULL AND c.revision=(SELECT max(c2.revision) FROM contribution_revisions c2 WHERE c2.session=c.session) ORDER BY c.requested_at DESC",
  )
    .bind(owner)
    .all();
  return json({
    selection: "voluntary-selected-sample",
    acceptedDistinctSessions: rows.results.filter(
      (r) => r.eligible === 1 && !r.withdrawn_at,
    ).length,
    history: rows.results.map((r) => ({
      ...r,
      reasons: r.reasons ? JSON.parse(String(r.reasons)) : [],
      metrics: r.metrics ? JSON.parse(String(r.metrics)) : null,
      status: r.withdrawn_at
        ? "withdrawn"
        : r.blocked_reason
          ? "blocked"
          : r.completeness
            ? r.eligible
              ? "accepted"
              : "ineligible"
            : "pending",
    })),
    benefits: "No rewards or payouts defined",
  });
}
export async function statistics(env: Env) {
  const rows = await env.DB.prepare(
    "SELECT s.owner,v.metrics,v.validated_at FROM contribution_revisions c JOIN snapshot_validations v ON v.snapshot=c.snapshot JOIN sessions s ON s.id=c.session JOIN accounts a ON a.id=s.owner WHERE v.eligible=1 AND s.fixture=0 AND s.deleted_at IS NULL AND a.deleted_at IS NULL AND c.withdrawn_at IS NULL AND c.revision=(SELECT max(c2.revision) FROM contribution_revisions c2 WHERE c2.session=c.session)",
  ).all<{ owner: string; metrics: string; validated_at: string }>();
  type Timing = {
    method: string;
    turnKind: string;
    first: number[];
    completion: number[];
    additional: number[];
    missingFirst: number;
    missingCompletion: number;
    missingAdditional: number;
    attempts: number;
  };
  type Group = {
    provider: string | null;
    connection: string;
    model: string | null;
    context: string;
    attempts: number;
    outcomes: Record<string, number>;
    first: number[];
    completion: number[];
    accounts: Set<string>;
    timings: Map<string, Timing>;
    initialSamples: number;
    followUpSamples: number;
    unknownPositionSamples: number;
  };
  const groups = new Map<string, Group>(),
    accounts = new Set<string>();
  const prefs = { favorite: 0, negative: 0, unmarked: 0, rated: 0, replies: 0 };
  let earliest: string | undefined, latest: string | undefined;
  for (const row of rows.results) {
    accounts.add(row.owner);
    earliest =
      !earliest || row.validated_at < earliest ? row.validated_at : earliest;
    latest = !latest || row.validated_at > latest ? row.validated_at : latest;
    const m = JSON.parse(row.metrics) as Validation["metrics"];
    for (const key of Object.keys(prefs) as (keyof typeof prefs)[])
      prefs[key] += m.preferences[key];
    for (const sample of m.samples) {
      // Provider outcome denominators include no-reply failures. Timing methods are separate subcohorts.
      const group = JSON.stringify([
        sample.provider,
        sample.connection,
        sample.model,
        m.context,
      ]);
      const g = groups.get(group) ?? {
        provider: sample.provider,
        connection: sample.connection,
        model: sample.model,
        context: m.context,
        attempts: 0,
        outcomes: {},
        first: [],
        completion: [],
        accounts: new Set<string>(),
        timings: new Map<string, Timing>(),
        initialSamples: 0,
        followUpSamples: 0,
        unknownPositionSamples: 0,
      };
      g.attempts++;
      g.accounts.add(row.owner);
      g.outcomes[sample.outcome] = (g.outcomes[sample.outcome] ?? 0) + 1;
      const turnKind =
        sample.position === null
          ? "unknown"
          : sample.position === 0
            ? "initial"
            : "followUp";
      if (turnKind === "initial") g.initialSamples++;
      else if (turnKind === "followUp") g.followUpSamples++;
      else g.unknownPositionSamples++;
      const method = observationMethod(sample.method),
        key = JSON.stringify([method, turnKind]);
      const t = g.timings.get(key) ?? {
        method,
        turnKind,
        first: [],
        completion: [],
        additional: [],
        missingFirst: 0,
        missingCompletion: 0,
        missingAdditional: 0,
        attempts: 0,
      };
      t.attempts++;
      if (sample.firstReplyMS === null) t.missingFirst++;
      else {
        t.first.push(sample.firstReplyMS);
        g.first.push(sample.firstReplyMS);
      }
      if (sample.completionMS === null) t.missingCompletion++;
      else {
        t.completion.push(sample.completionMS);
        g.completion.push(sample.completionMS);
      }
      for (const value of sample.additionalReplyMS) {
        if (value === null) t.missingAdditional++;
        else t.additional.push(value);
      }
      g.timings.set(key, t);
      groups.set(group, g);
    }
  }
  const median = (v: number[]) => {
    const values = [...v].sort((a, b) => a - b);
    return values.length
      ? (values[Math.floor((values.length - 1) / 2)] +
          values[Math.floor(values.length / 2)]) /
          2
      : null;
  };
  return json({
    schemaVersion: 1,
    selection: "voluntary-selected-sample; not representative of all usage",
    verification: "server-registered; not independently witnessed",
    unknownProviderLabel:
      "Unclassified collection, not an agent benchmark; never inferred from editable names",
    sessions: rows.results.length,
    distinctContributingAccounts: accounts.size,
    contributorDefinition:
      "Distinct contributing accounts are not independently verified unique humans",
    validationDates: earliest
      ? [earliest, ...(rows.results.length > 1 ? [latest] : [])]
      : [],
    measurementDefinitions: {
      firstReply:
        "dispatch to first newly observed nonempty assistant message; same segment and clock; not model-token latency",
      completion:
        "dispatch to supported observed completion; missing timings excluded only from that metric",
      outcomes:
        "all qualifying recorded attempts within provider/connection/model/context, including no-reply failures, cancellations and unobserved replies",
      timingCohorts:
        "observation method and initial/follow-up measured separately; heterogeneous medians are unavailable",
      preferences:
        "owner favorite/negative/unmarked; rated denominator excludes unmarked; not task quality",
    },
    collectionGroups: [...groups.values()].map((g) => ({
      provider: g.provider,
      connection: g.connection,
      model: g.model,
      context: g.context,
      attempts: g.attempts,
      outcomes: g.outcomes,
      distinctContributingAccounts: g.accounts.size,
      initialSamples: g.initialSamples,
      followUpSamples: g.followUpSamples,
      unknownPositionSamples: g.unknownPositionSamples,
      firstReplyCount: g.first.length,
      missingFirstReplyCount: g.attempts - g.first.length,
      firstReplyMedianMS:
        [...g.timings.values()].filter((t) => t.first.length).length <= 1
          ? median(g.first)
          : null,
      completionCount: g.completion.length,
      missingCompletionCount: g.attempts - g.completion.length,
      completionMedianMS:
        [...g.timings.values()].filter((t) => t.completion.length).length <= 1
          ? median(g.completion)
          : null,
      timingCohorts: [...g.timings.values()].map((t) => ({
        method: t.method,
        turnKind: t.turnKind,
        attempts: t.attempts,
        firstReplyCount: t.first.length,
        firstReplyMedianMS: median(t.first),
        missingFirstReplyCount: t.missingFirst,
        completionCount: t.completion.length,
        completionMedianMS: median(t.completion),
        missingCompletionCount: t.missingCompletion,
        additionalReplyCount: t.additional.length,
        additionalReplyMedianMS: median(t.additional),
        missingAdditionalReplyCount: t.missingAdditional,
      })),
    })),
    preferences: prefs,
  });
}
