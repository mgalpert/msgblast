// Explicit telemetry contract: never accept arbitrary client properties.
const MAX_BYTES = 32 * 1024;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PROVIDERS = new Set(['chatgpt', 'claude', 'grok', 'muse', 'dots', 'os3', 'hark', 'grokbot', 'codexCLI', 'claudeCode', 'dshCLI', 'openclaw', 'hermes', 'instinct', 'fo', 'szn', 'poke', 'otherMessages']);
const SCREENS = ['connectors', 'permissions', 'messages', 'agents', 'browserImport', 'providerConnection', 'runtimeSetup', 'feedback'];
const CONTRACT = {
  onboarding_completed: ['activity', []],
  onboarding_screen_viewed: ['agentUsage', ['screen']],
  agent_inventory: ['agentUsage', ['counts']],
  agent_added: ['agentUsage', ['provider', 'count']],
  message_submitted: ['messageCounts', ['kind', 'recipientCount']],
  app_active: ['activity', []],
  app_engaged: ['activity', []],
  operation_result: ['reliability', ['operation', 'result']],
  operation_timing: ['performance', ['operation', 'duration']],
};
const COMMON = ['appVersion', 'buildChannel', 'osMajor', 'cohortDay', 'cohortStartedAt', 'fixture'];
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const integer = (value, min, max) => Number.isInteger(value) && value >= min && value <= max;
const keysAllowed = (value, keys) => Object.keys(value).every(key => keys.includes(key));
const has = (value, key) => Object.hasOwn(value, key);

export function validEvent(event, allowFixtures = false) {
  if (!object(event) || !keysAllowed(event, ['id', 'name', 'category', 'timestamp', 'distinctID', 'properties'])) return false;
  const contract = typeof event.name === 'string' && has(CONTRACT, event.name) ? CONTRACT[event.name] : null;
  if (!contract || typeof event.id !== 'string' || !UUID.test(event.id) || event.category !== contract[0]) return false;
  if (typeof event.timestamp !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.test(event.timestamp) || !Number.isFinite(Date.parse(event.timestamp))) return false;
  if (has(event, 'distinctID') && (typeof event.distinctID !== 'string' || !UUID.test(event.distinctID))) return false;
  const p = event.properties;
  if (!object(p) || !keysAllowed(p, [...COMMON, ...contract[1], ...(event.name === 'onboarding_screen_viewed' ? ['previousScreen', 'provider'] : [])]) || !contract[1].every(key => has(p, key))) return false;
  if (has(p, 'appVersion') && (typeof p.appVersion !== 'string' || !/^[0-9][0-9A-Za-z._-]{0,31}$/.test(p.appVersion))) return false;
  if (has(p, 'buildChannel') && !['development', 'production'].includes(p.buildChannel)) return false;
  if (has(p, 'screen') && !SCREENS.includes(p.screen)) return false;
  if (has(p, 'osMajor') && !integer(p.osMajor, 15, 99)) return false;
  if (has(p, 'cohortDay') && (!has(event, 'distinctID') || !integer(p.cohortDay, 0, 3660))) return false;
  if (has(p, 'cohortStartedAt') && (!has(event, 'distinctID') || typeof p.cohortStartedAt !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(p.cohortStartedAt) || !Number.isFinite(Date.parse(p.cohortStartedAt)))) return false;
  if (has(p, 'fixture') && (typeof p.fixture !== 'boolean' || (p.fixture && !allowFixtures))) return false;
  if (has(p, 'counts') && (!object(p.counts) || Object.keys(p.counts).length > PROVIDERS.size || !Object.entries(p.counts).every(([key, count]) => PROVIDERS.has(key) && integer(count, 0, 100)))) return false;
  if (has(p, 'previousScreen') && !SCREENS.includes(p.previousScreen)) return false;
  if (has(p, 'provider') && !PROVIDERS.has(p.provider)) return false;
  if (has(p, 'count') && !integer(p.count, 1, 100)) return false;
  if (has(p, 'kind') && !['shared', 'private'].includes(p.kind)) return false;
  if (has(p, 'recipientCount') && !integer(p.recipientCount, 1, 100)) return false;
  if (has(p, 'operation') && !['send', 'setup', 'storage'].includes(p.operation)) return false;
  if (has(p, 'result') && !['success', 'failure'].includes(p.result)) return false;
  if (has(p, 'duration') && !['under_1s', '1_to_5s', '5_to_30s', 'over_30s'].includes(p.duration)) return false;
  return true;
}

async function readBoundedJSON(request) {
  if (!request.body) throw new Error('invalid');
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BYTES) throw new Error('oversized');
      chunks.push(value);
    }
  } catch (error) {
    await reader.cancel().catch(() => {});
    throw error;
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
}

const reply = (status, error) => new Response(error ? JSON.stringify({ error }) : null, {
  status, headers: { 'Cache-Control': 'no-store', ...(error ? { 'Content-Type': 'application/json' } : {}) },
});

// IP is used only for ephemeral abuse control; never copied into analytics or logs.
async function rateKey(request) {
  const hour = Math.floor(Date.now() / 3600000);
  const bytes = new TextEncoder().encode(`${hour}:${request.headers.get('CF-Connecting-IP') || 'unknown'}`);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
}

export async function handleTelemetry(request, env, fetchBackend = fetch) {
  if (new URL(request.url).pathname !== '/api/telemetry') return reply(404, 'not_found');
  if (request.method !== 'POST') return reply(405, 'method_not_allowed');
  if (!/^application\/json(?:\s*;|$)/i.test(request.headers.get('Content-Type') || '')) return reply(415, 'json_required');
  const host = env.POSTHOG_HOST;
  if (!['https://us.i.posthog.com', 'https://eu.i.posthog.com'].includes(host) || !env.POSTHOG_PROJECT_TOKEN || !env.TELEMETRY_RATE_LIMIT) return reply(503, 'unavailable');
  try {
    if (!(await env.TELEMETRY_RATE_LIMIT.limit({ key: await rateKey(request) })).success) return reply(429, 'rate_limited');
  } catch { return reply(503, 'unavailable'); }
  let body;
  try { body = await readBoundedJSON(request); }
  catch (error) { return reply(error.message === 'oversized' ? 413 : 400, 'invalid_batch'); }
  if (!object(body) || !keysAllowed(body, ['schema', 'events']) || body.schema !== 1 || !Array.isArray(body.events) || !integer(body.events.length, 1, 20) || !body.events.every(event => validEvent(event, env.TELEMETRY_ALLOW_FIXTURES === 'true')) || new Set(body.events.map(event => event.id.toLowerCase())).size !== body.events.length) return reply(400, 'invalid_batch');
  const batch = body.events.map(event => ({
    uuid: event.id.toLowerCase(), event: event.name, timestamp: event.timestamp,
    distinct_id: (event.distinctID || event.id).toLowerCase(),
    properties: { ...event.properties, category: event.category, $process_person_profile: false, $geoip_disable: true },
  }));
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 5000);
  try {
    const response = await fetchBackend(`${host}/batch/`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ api_key: env.POSTHOG_PROJECT_TOKEN, batch }),
      redirect: 'manual', signal: controller.signal,
    });
    await response.body?.cancel();
    return response.ok ? reply(204) : reply(502, 'upstream_unavailable');
  } catch { return reply(502, 'upstream_unavailable'); }
  finally { clearTimeout(timeout); }
}

export default { fetch: (request, env) => handleTelemetry(request, env) };
