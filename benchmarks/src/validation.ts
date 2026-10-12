import { canonical, hash, object, requireValue } from "./http";
import { Session, validateChunk } from "./ingest";
type Event = Record<string, unknown>;
interface Sample {
  agent: string;
  connection: string;
  provider: string | null;
  position: number | null;
  model: string | null;
  outcome: string;
  firstReplyMS: number | null;
  submissionMS: number | null;
  completionMS: number | null;
  additionalReplyMS: (number | null)[];
  method: string | null;
}
export interface Validation {
  completeness: "complete" | "partial";
  eligible: boolean;
  reasons: string[];
  metrics: {
    schemaVersion: 1;
    selection: "voluntary-selected-sample";
    verification: "server-registered; locally observed; not independently witnessed";
    context: string;
    samples: Sample[];
    preferences: {
      favorite: number;
      negative: number;
      unmarked: number;
      rated: number;
      replies: number;
    };
  };
}
function elapsed(
  a: Event | undefined,
  b: Event | undefined,
  boundaries: Map<string, { sequence: number; agent: string | null }[]>,
) {
  if (!a || !b || a.segmentID !== b.segmentID) return null;
  const x = object(a.stamp),
    y = object(b.stamp);
  const dt = Number(y.monotonicMS) - Number(x.monotonicMS);
  const aid = a.agent ? String(object(a.agent).id) : null;
  const crosses = (boundaries.get(String(a.segmentID)) ?? []).some(
    (boundary) =>
      boundary.sequence > Number(a.sequence) &&
      boundary.sequence < Number(b.sequence) &&
      (boundary.agent === null || boundary.agent === aid),
  );
  return x.clockID === y.clockID && dt >= 0 && !crosses ? dt : null;
}
export async function validateSession(
  env: Env,
  s: Session,
  frozen = false,
): Promise<Validation> {
  const rows = await env.DB.prepare(
    "SELECT * FROM chunks WHERE session=? AND end_sequence<=? ORDER BY start_sequence",
  )
    .bind(s.id, s.next_sequence)
    .all<{
      start_sequence: number;
      end_sequence: number;
      hash: string;
      previous_hash: string;
      object_key: string;
    }>();
  let seq = 1,
    prev = "",
    eventHash: string | undefined;
  const events: Event[] = [];
  for (const row of rows.results) {
    requireValue(
      row.start_sequence === seq && row.previous_hash === prev,
      "stored_chain_invalid",
      409,
    );
    const stored = await env.CONTENT.get(row.object_key);
    requireValue(stored, "stored_chunk_missing", 409);
    const raw = await stored.text();
    requireValue((await hash(raw)) === row.hash, "stored_hash_invalid", 409);
    const chunk = await validateChunk(JSON.parse(raw), s, eventHash);
    requireValue(
      chunk.sequenceStart === row.start_sequence &&
        chunk.sequenceEnd === row.end_sequence,
      "stored_sequence_invalid",
      409,
    );
    events.push(...(chunk.events as Event[]));
    seq = row.end_sequence + 1;
    prev = row.hash;
    eventHash = await hash(canonical(events.at(-1)));
  }
  requireValue(
    seq - 1 === s.next_sequence && prev === s.last_hash,
    "snapshot_head_mismatch",
    409,
  );
  const gaps = new Map<string, { sequence: number; agent: string | null }[]>();
  const reasons: string[] = [];
  const segments = new Map<string, { started: boolean; ended: boolean }>();
  const seen = new Set<string>();
  for (const e of events) {
    const eid = String(e.id);
    if (seen.has(eid)) reasons.push("duplicate-event");
    seen.add(eid);
    const seg = segments.get(String(e.segmentID)) ?? {
      started: false,
      ended: false,
    };
    if (e.kind === "segmentStarted") {
      if (seg.started || e.reason !== "recording-started")
        reasons.push("partial-segment");
      seg.started = true;
    }
    if (e.kind === "segmentEnded") seg.ended = true;
    if (e.kind === "gap" || e.kind === "segmentEnded") {
      if (e.kind === "gap") reasons.push("recording-gap");
      const list = gaps.get(String(e.segmentID)) ?? [];
      list.push({
        sequence: Number(e.sequence),
        agent: e.kind === "gap" && e.agent ? String(object(e.agent).id) : null,
      });
      gaps.set(String(e.segmentID), list);
    }
    segments.set(String(e.segmentID), seg);
  }
  if (
    !events.length ||
    [...segments.values()].some((s) => !s.started || !s.ended)
  )
    reasons.push("open-or-missing-segment");
  const attempts = new Map<string, Event[]>();
  const replies = new Map<string, string>();
  const feedbackSequences = new Map<string, number>();
  for (const e of events) {
    const agent = e.agent ? object(e.agent) : undefined;
    if (e.kind === "replyObserved" && agent && e.messageID) {
      const key = `${e.segmentID}:${agent.id}:${e.messageID}`;
      if (!replies.has(key)) replies.set(key, "unmarked");
    }
    if (e.kind === "feedback" && agent && e.messageID && e.selection) {
      const k = `${e.segmentID}:${agent.id}:${e.messageID}`;
      if (replies.has(k)) {
        replies.set(k, String(e.selection));
        feedbackSequences.set(k, Number(e.sequence));
      }
    }
    if (e.turnID) {
      const key = `${e.segmentID}:${agent?.id ?? "unknown"}:${e.turnID}`;
      const list = attempts.get(key) ?? [];
      list.push(e);
      attempts.set(key, list);
    }
  }
  const samples: Sample[] = [];
  for (const list of attempts.values()) {
    const start = list.find((e) => e.kind === "turnStarted");
    if (!start) continue;
    const agent = start.agent ? object(start.agent) : undefined;
    if (!agent) {
      reasons.push("unknown-agent");
      continue;
    }
    const dispatch = list.find((e) => e.kind === "dispatched"),
      submitted = list.find((e) => e.kind === "submitted"),
      done = list.find((e) => e.kind === "completed"),
      outcome = list.find((e) => e.kind === "outcome");
    const distinct: Event[] = [];
    const mids = new Set<string>();
    for (const e of list.filter((e) => e.kind === "replyObserved")) {
      if (e.messageID && e.text && !mids.has(String(e.messageID))) {
        mids.add(String(e.messageID));
        distinct.push(e);
      }
    }
    if (!done && !outcome && !distinct.length)
      reasons.push("unresolved-attempt");
    const first = !distinct[0]?.method
      ? null
      : elapsed(dispatch, distinct[0], gaps);
    const completion = !done?.method ? null : elapsed(dispatch, done, gaps);
    if (first === null) reasons.push("first-reply-timing-unavailable");
    if (completion === null) reasons.push("completion-timing-unavailable");
    const reason = String(outcome?.reason ?? "uncertain");
    const category =
      ["failed", "canceled", "timeout", "uncertain", "unsupported"].find(
        (k) => reason === k || reason.startsWith(k + ":"),
      ) ?? "uncertain";
    const terminal = done
      ? "observedCompletion"
      : outcome
        ? category
        : distinct.length
          ? "observedReply"
          : "unobserved";
    samples.push({
      agent: String(agent.id),
      connection: String(agent.connection),
      provider: agent.provider === undefined ? null : String(agent.provider),
      position:
        start.turnPosition === undefined ? null : Number(start.turnPosition),
      model: agent.model === undefined ? null : String(agent.model),
      outcome: terminal,
      firstReplyMS: first,
      submissionMS: elapsed(start, submitted, gaps),
      completionMS: completion,
      additionalReplyMS: distinct
        .slice(1)
        .map((e, i) => elapsed(distinct[i], e, gaps)),
      method: distinct[0]?.method ? String(distinct[0].method) : null,
    });
  }
  const partial = reasons.some((r) =>
    [
      "duplicate-event",
      "partial-segment",
      "recording-gap",
      "open-or-missing-segment",
      "unresolved-attempt",
    ].includes(r),
  );
  if (s.fixture) reasons.push("fixture-excluded");
  if (s.context !== "fresh") reasons.push("not-controlled-fresh-context");
  if (!samples.length) reasons.push("no-attempts");
  const baseline = await env.DB.prepare(
    "SELECT * FROM legacy_feedback_baselines WHERE session=?",
  )
    .bind(s.id)
    .all<{
      segment_id: string;
      agent_id: string;
      message_id: string;
      sequence_end: number;
      selection: string;
    }>();
  for (const f of baseline.results) {
    const key = `${f.segment_id}:${f.agent_id}:${f.message_id}`;
    if (replies.has(key) && (feedbackSequences.get(key) ?? 0) <= f.sequence_end)
      replies.set(key, f.selection);
  }
  const feedback = await env.DB.prepare(
    "SELECT f.* FROM feedback_revisions f WHERE f.session=? AND f.revision=(SELECT max(f2.revision) FROM feedback_revisions f2 WHERE f2.session=f.session AND f2.segment_id=f.segment_id AND f2.agent_id=f.agent_id AND f2.message_id=f.message_id)",
  )
    .bind(frozen ? "" : s.id)
    .all<{
      segment_id: string;
      agent_id: string;
      message_id: string;
      selection: string;
    }>();
  for (const f of feedback.results) {
    const key = `${f.segment_id}:${f.agent_id}:${f.message_id}`;
    if (replies.has(key)) replies.set(key, f.selection);
  }
  const selections = [...replies.values()];
  const favorite = selections.filter((x) => x === "favorite").length,
    negative = selections.filter((x) => x === "negative").length;
  return {
    completeness: partial ? "partial" : "complete",
    eligible: !partial && !s.fixture && samples.length > 0,
    reasons: [...new Set(reasons)],
    metrics: {
      schemaVersion: 1,
      selection: "voluntary-selected-sample",
      verification:
        "server-registered; locally observed; not independently witnessed",
      context: s.context,
      samples,
      preferences: {
        favorite,
        negative,
        unmarked: selections.length - favorite - negative,
        rated: favorite + negative,
        replies: selections.length,
      },
    },
  };
}
