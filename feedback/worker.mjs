// Native-app intake only. No public read route, bucket URLs, or request-content logging.
const MAX_BYTES = 64 * 1024;
const email = /^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,253}\.[A-Za-z]{2,24}$/;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const count = value => Number.isSafeInteger(value) && value >= 0 && value <= 1_000_000;
const choice = values => value => typeof value === 'string' && values.includes(value);
const token = pattern => value => typeof value === 'string' && (value === 'unknown' || pattern.test(value));
const diagnosticFields = {
  agentCount: count, attachmentCount: count, comparisonCount: count,
  buildNumber: token(/^[0-9A-Za-z._-]{1,32}$/), version: token(/^[0-9A-Za-z._-]{1,32}$/),
  bundleIdentifier: token(/^com\.msgblast\.[A-Za-z0-9-]{1,40}$/),
  fixtureMode: value => typeof value === 'boolean', hasDraft: value => typeof value === 'boolean',
  stateFilePresent: value => typeof value === 'boolean', updatesEnabled: value => typeof value === 'boolean',
  lastErrorCategory: choice(['none','messagesAccess','contacts','storage','send','other']),
  messagesStatus: choice(['checking','available','simulated','permissionPreview','unavailable']),
  operatingSystem: token(/^Version [0-9]+(?:\.[0-9]+){1,3} \(Build [0-9A-Za-z]{1,32}\)$/),
  permissionStage: choice(['idle','openingSettings','guiding','waitingForAccess','verified','unknown']),
  personalAgent: choice(['none','codex','claude','cursor','gemini','pi','grok','hermes']),
  stateFileBytes: value => Number.isSafeInteger(value) && value >= 0 && value <= 512_000_000,
  supportFolder: value => typeof value === 'string' && (['msgblast','MsgBlast-WebPreview','unknown'].includes(value) || /^msgblast-[A-Za-z0-9][A-Za-z0-9-]{0,40}$/.test(value)),
  updatesReason: choice(['','Updates are disabled in previews and test runs.','This development build has no configured update service.','unavailable']),
  variant: choice(['production','development','demo','other']),
  webProviderCounts: value => object(value) && Object.entries(value).every(([key,value]) => ['muse','chatgpt','claude','grok','codexCLI','claudeCode','dots','grokbot','os3','hark','museApp','grokBotApp','wabi','geminiApp','chatgptApp','dotsApp','claudeApp'].includes(key) && count(value) && value > 0),
  windowStyle: choice(['connected','separate','unknown'])
};

const exact = (value, keys) => object(value) && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value,key));
function validCrash(c) {
  return exact(c,['schema','incident','process','bundleIdentifier','version','build','exception','signal','day','frames','fingerprint'])
    && c.schema === 1 && typeof c.incident === 'string' && uuid.test(c.incident)
    && ['app','helper'].includes(c.process)
    && typeof c.bundleIdentifier === 'string' && /^com\.msgblast\.[A-Za-z0-9-]{1,40}$/.test(c.bundleIdentifier)
    && diagnosticFields.version(c.version) && diagnosticFields.buildNumber(c.build)
    && ['EXC_BAD_ACCESS','EXC_BAD_INSTRUCTION','EXC_ARITHMETIC','EXC_BREAKPOINT','EXC_CRASH','EXC_GUARD','EXC_RESOURCE'].includes(c.exception)
    && ['SIGABRT','SIGSEGV','SIGBUS','SIGILL','SIGTRAP','SIGFPE','SIGSYS'].includes(c.signal)
    && typeof c.day === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(c.day)
    && typeof c.fingerprint === 'string' && /^[a-f0-9]{64}$/.test(c.fingerprint)
    && Array.isArray(c.frames) && c.frames.length > 0 && c.frames.length <= 64
    && c.frames.every(f => exact(f,['uuid','arch','offset']) && typeof f.uuid === 'string' && uuid.test(f.uuid)
      && ['arm64','arm64e','x86_64','x86_64h'].includes(f.arch) && Number.isSafeInteger(f.offset) && f.offset >= 0);
}

function validate(body) {
  if (!object(body) || Object.keys(body).some(key => !['id','kind','note','contact','diagnostics','crash'].includes(key))) return null;
  if (typeof body.id !== 'string' || !uuid.test(body.id) || !['feedback','bug','crash'].includes(body.kind)) return null;
  if (typeof body.note !== 'string' || !body.note.trim() || body.note.length > 16000) return null;
  if (body.contact !== undefined && (typeof body.contact !== 'string' || body.contact.trim().length > 120 || (body.contact.trim() && !email.test(body.contact.trim())))) return null;
  const result = {id:body.id.toLowerCase(), kind:body.kind, note:body.note, contact:body.contact?.trim() ?? ''};
  if (body.diagnostics !== undefined) {
    if (typeof body.diagnostics !== 'string') return null;
    let diagnostics;
    try { diagnostics = JSON.parse(body.diagnostics); } catch { return null; }
    if (!object(diagnostics) || Object.keys(diagnostics).length !== Object.keys(diagnosticFields).length || !Object.entries(diagnosticFields).every(([key, valid]) => Object.hasOwn(diagnostics,key) && valid(diagnostics[key]))) return null;
    // Mirror invariants of DiagnosticPayload, not caller-supplied arbitrary data.
    const variant = {'com.msgblast.mac':'production','com.msgblast.development':'development','com.msgblast.demo':'demo'}[diagnostics.bundleIdentifier] ?? 'other';
    if (diagnostics.variant !== variant || (!diagnostics.stateFilePresent && diagnostics.stateFileBytes !== 0)) return null;
    result.diagnostics = diagnostics;
  }
  if (body.kind === 'crash') {
    if (!validCrash(body.crash)) return null;
    result.crash = body.crash;
  } else if (body.crash !== undefined) return null;
  return result;
}

function canonical(value) {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (!object(value)) return JSON.stringify(value);
  return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}';
}
function json(status, value, headers = {}) {
  return new Response(JSON.stringify(value), {status,headers:{'content-type':'application/json; charset=utf-8','cache-control':'no-store',...headers}});
}
async function boundedJSON(request) {
  const length = request.headers.get('content-length');
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > MAX_BYTES)) throw 413;
  if (!request.body) throw 400;
  const reader = request.body.getReader();
  const chunks = []; let size = 0;
  try {
    while (true) {
      const {done,value} = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BYTES) { await reader.cancel(); throw 413; }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk,offset); offset += chunk.byteLength; }
    return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
  } catch (error) { throw error === 413 ? 413 : 400; }
  finally { reader.releaseLock(); }
}

export async function handleFeedback(request, env) {
  if (request.method !== 'POST') return json(405,{error:'method_not_allowed'},{Allow:'POST'});
  if (request.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') return json(415,{error:'json_required'});
  try {
    const limit = await env.FEEDBACK_RATE_LIMIT.limit({key:request.headers.get('CF-Connecting-IP') || 'local'});
    if (!limit || typeof limit.success !== 'boolean') return json(503,{error:'temporarily_unavailable'});
    if (!limit.success) return json(429,{error:'try_again_later'},{'retry-after':'60'});
  } catch { return json(503,{error:'temporarily_unavailable'}); }
  let input;
  try { input = validate(await boundedJSON(request)); }
  catch (status) { return json(status,{error:status === 413 ? 'report_too_large' : 'invalid_report'}); }
  if (!input) return json(400,{error:'invalid_report'});
  try {
    const hashBytes = await crypto.subtle.digest('SHA-256',new TextEncoder().encode(canonical(input)));
    const contentHash = Array.from(new Uint8Array(hashBytes),value=>value.toString(16).padStart(2,'0')).join('');
    const key = `reports/${input.id}.json`;
    const previous = await env.FEEDBACK_BUCKET.head(key);
    if (previous) return previous.customMetadata?.contentHash === contentHash ? json(200,{id:input.id}) : json(409,{error:'report_id_conflict'});
    const stored = await env.FEEDBACK_BUCKET.put(key,JSON.stringify({...input,receivedAt:new Date().toISOString()}),{
      onlyIf:{etagDoesNotMatch:'*'}, httpMetadata:{contentType:'application/json'}, customMetadata:{contentHash}
    });
    if (stored) return json(201,{id:input.id});
    // A racing request won the conditional write. Its content determines the retry outcome.
    const winner = await env.FEEDBACK_BUCKET.head(key);
    if (!winner) return json(503,{error:'temporarily_unavailable'});
    return winner.customMetadata?.contentHash === contentHash ? json(200,{id:input.id}) : json(409,{error:'report_id_conflict'});
  } catch { return json(503,{error:'temporarily_unavailable'}); }
}

export default {
  async fetch(request,env) {
    if (new URL(request.url).pathname === '/api/feedback') return handleFeedback(request,env);
    return env.ASSETS ? env.ASSETS.fetch(request) : new Response('Not found',{status:404});
  }
};
