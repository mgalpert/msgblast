import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { handleTelemetry, PROVIDERS } from './worker.mjs';

globalThis.crypto ??= webcrypto;
const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const installation = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const event = (overrides = {}) => ({ id, name: 'app_active', category: 'activity', timestamp: '2026-10-12T12:00:00Z', properties: {}, ...overrides });
const env = (overrides = {}) => ({ POSTHOG_HOST: 'https://us.i.posthog.com', POSTHOG_PROJECT_TOKEN: 'test-project-token', TELEMETRY_RATE_LIMIT: { limit: async () => ({ success: true }) }, ...overrides });
const request = body => new Request('https://msgblast.app/api/telemetry', { method: 'POST', headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '192.0.2.1', 'User-Agent': 'sensitive-client' }, body: JSON.stringify(body) });
const batch = e => ({ schema: 1, events: [e] });

test('real handler forwards only allowed fields, preserving linked and unlinked UUIDs', async () => {
  const events = [event({ distinctID: installation, properties: { cohortDay: 7, cohortStartedAt: '2026-10-05T12:00:00Z', appVersion: '0.2.0', osMajor: 26 } }), event({ id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', name: 'agent_inventory', category: 'agentUsage', properties: { counts: { claude: 2, codexCLI: 1 } } })];
  let captured;
  const response = await handleTelemetry(request({ schema: 1, events }), env(), async (url, options) => {
    captured = { url, options, body: JSON.parse(options.body) };
    return new Response('1', { status: 200 });
  });
  assert.equal(response.status, 204);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.equal(captured.url, 'https://us.i.posthog.com/batch/');
  assert.equal(captured.options.redirect, 'manual');
  assert.deepEqual(captured.options.headers, { 'Content-Type': 'application/json' });
  assert.equal(captured.body.batch[0].distinct_id, installation);
  assert.equal(captured.body.batch[1].distinct_id, events[1].id);
  assert.equal(captured.body.batch[0].uuid, id);
  assert.equal(captured.body.batch[0].properties.cohortStartedAt, '2026-10-05T12:00:00Z');
  assert.equal(captured.body.batch[1].properties.cohortStartedAt, undefined);
  assert.equal(captured.body.batch[0].properties.$process_person_profile, false);
  assert.equal(captured.body.batch[0].properties.$geoip_disable, true);
  assert.ok(!captured.options.body.includes('192.0.2.1'));
  assert.ok(!captured.options.body.includes('sensitive-client'));
});

test('rejects private fields, invalid schemas, miscategorized events and malformed values before forwarding', async () => {
  const invalid = [
    batch(event({ name: 'onboarding_screen_viewed', category: 'agentUsage', properties: { screen: 'private URL' } })),
    batch(event({ name: 'onboarding_screen_viewed', category: 'agentUsage', properties: { screen: 'agents', previousScreen: 'personal name' } })),
    batch(event({ properties: { buildChannel: 'private' } })),
    batch(event({ properties: { prompt: 'private' } })), batch(event({ ip: 'private' })),
    batch(event({ category: 'agentUsage' })), batch(event({ name: 'unknown' })), batch(event({ name: ['app_active'] })),
    batch(event({ properties: { cohortDay: 1 } })), batch(event({ distinctID: 'account@example.com' })),
    batch(event({ properties: { cohortStartedAt: '2026-10-05T12:00:00Z' } })),
    batch(event({ distinctID: installation, properties: { cohortStartedAt: 'private' } })),
    batch(event({ id: [id] })), batch(event({ timestamp: 'today' })),
    batch(event({ properties: { fixture: true } })), batch(event({ properties: { appVersion: 'https://private' } })),
    batch(event({ name: 'agent_inventory', category: 'agentUsage', properties: { counts: { 'Personal Contact': 1 } } })),
    batch(event({ name: 'message_submitted', category: 'messageCounts', properties: { kind: 'shared', recipientCount: 0 } })),
    batch(event({ name: 'operation_timing', category: 'performance', properties: { operation: 'send', duration: '1ms' } })),
    { schema: 2, events: [event()] }, { schema: 1, events: [] }, { schema: 1, events: Array(21).fill(event()) },
    { schema: 1, events: [event(), event()] }, { schema: 1, events: [event()], extra: true },
  ];
  for (const body of invalid) {
    const response = await handleTelemetry(request(body), env(), () => { throw new Error('must not forward'); });
    assert.equal(response.status, 400, JSON.stringify(body));
  }
});

test('forwards the valid events of a mixed batch and drops only the ones outside the contract', async () => {
  const second = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  const events = [event(), event({ id: second, name: 'agent_inventory', category: 'agentUsage', properties: { counts: { 'Personal Contact': 1 } } }), event({ id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', properties: { prompt: 'private' } })];
  let captured;
  const response = await handleTelemetry(request({ schema: 1, events }), env(), async (url, options) => { captured = options.body; return new Response(null, { status: 200 }); });
  assert.equal(response.status, 204);
  assert.deepEqual(JSON.parse(captured).batch.map(e => e.uuid), [id]);
  assert.ok(!captured.includes('Personal Contact') && !captured.includes('private'));
});

test('accepts app agent and Alexa Shopping keys', async () => {
  for (const provider of ['chatgptApp', 'claudeApp', 'dotsApp', 'museApp', 'grokBotApp', 'wabi', 'geminiApp', 'alexaShopping']) {
    const added = event({ name: 'agent_added', category: 'agentUsage', properties: { provider, count: 1 } });
    const inventory = event({ id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', name: 'agent_inventory', category: 'agentUsage', properties: { counts: { [provider]: 1 } } });
    let forwarded = 0;
    const response = await handleTelemetry(request({ schema: 1, events: [added, inventory] }), env(), async (url, options) => { forwarded = JSON.parse(options.body).batch.length; return new Response(null, { status: 200 }); });
    assert.equal(response.status, 204, provider);
    assert.equal(forwarded, 2, provider);
  }
});

test('accepts every explicitly contracted event and permits fixtures only on configured test environments', async () => {
  const events = [
    event({ name: 'onboarding_completed' }),
    event({ name: 'onboarding_screen_viewed', category: 'agentUsage', properties: { screen: 'providerConnection', previousScreen: 'browserImport', provider: 'chatgpt', buildChannel: 'development' } }),
    event({ name: 'app_engaged' }),
    event({ name: 'agent_added', category: 'agentUsage', properties: { provider: 'poke', count: 1 } }),
    event({ name: 'message_submitted', category: 'messageCounts', properties: { kind: 'private', recipientCount: 1 } }),
    event({ name: 'operation_result', category: 'reliability', properties: { operation: 'storage', result: 'failure' } }),
    event({ name: 'operation_timing', category: 'performance', properties: { operation: 'setup', duration: 'over_30s', fixture: true } }),
  ];
  for (const e of events) assert.equal((await handleTelemetry(request(batch(e)), env({ TELEMETRY_ALLOW_FIXTURES: 'true' }), async () => new Response(null, { status: 200 }))).status, 204);
});

test('bounds chunked request bodies even without a Content-Length header', async () => {
  let cancelled = false;
  const stream = new ReadableStream({ pull(controller) { controller.enqueue(new Uint8Array(17000)); }, cancel() { cancelled = true; } });
  const r = new Request('https://msgblast.app/api/telemetry', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: stream, duplex: 'half' });
  assert.equal((await handleTelemetry(r, env(), () => { throw new Error('must not forward'); })).status, 413);
  assert.equal(cancelled, true);
});

test('fails closed for rate limits, missing bindings, arbitrary hosts and upstream failures', async () => {
  assert.equal((await handleTelemetry(request(batch(event())), env({ TELEMETRY_RATE_LIMIT: { limit: async () => ({ success: false }) } }))).status, 429);
  assert.equal((await handleTelemetry(request(batch(event())), env({ TELEMETRY_RATE_LIMIT: undefined }))).status, 503);
  assert.equal((await handleTelemetry(request(batch(event())), env({ POSTHOG_HOST: 'https://example.com' }))).status, 503);
  for (const status of [302, 400, 429, 500]) assert.equal((await handleTelemetry(request(batch(event())), env(), async () => new Response(null, { status }))).status, 502);
  assert.equal((await handleTelemetry(request(batch(event())), env(), async () => { throw new Error('private upstream error'); })).status, 502);
});

test('ephemeral rate-limit keys never contain the raw IP', async () => {
  let key;
  await handleTelemetry(request(batch(event())), env({ TELEMETRY_RATE_LIMIT: { limit: async args => { key = args.key; return { success: true }; } } }), async () => new Response(null, { status: 200 }));
  assert.match(key, /^[0-9a-f]{64}$/);
  assert.ok(!key.includes('192.0.2.1'));
});

// The Mac counts agents by these enums' raw values (AppModel.telemetryAgentCounts). A case the Worker
// does not list is dropped from stats, so every case must be listed before a build sends it.
test('lists every agent key the Mac app can send', () => {
  const cases = (file, enumName) => {
    const source = readFileSync(new URL(`../msgblast/Core/${file}`, import.meta.url), 'utf8');
    const body = source.slice(source.indexOf(`enum ${enumName}`));
    return body.match(/^\s*case ([^\n]+)$/m)[1].split(',').map(name => name.trim());
  };
  const keys = [...cases('WebProvider.swift', 'WebProvider'), ...cases('Onboarding.swift', 'OnboardingChoice'), ...cases('LocalAgentDetection.swift', 'LocalAgentRuntime')];
  assert.ok(keys.length > 20);
  assert.deepEqual(keys.filter(key => !PROVIDERS.has(key)), []);
});
