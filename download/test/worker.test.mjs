import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker, { createDownloadWorker, latestRelease } from '../worker.mjs';
const encoder = new TextEncoder();
const keys = await crypto.subtle.generateKey('Ed25519', true, ['sign', 'verify']);
const publicKey = Buffer.from(await crypto.subtle.exportKey('raw', keys.publicKey)).toString('base64');
function item(version, build, url = `https://updates.msgblast.app/downloads/msgblast-${version}-${build}.zip`) {
  return `<item><sparkle:version>${build}</sparkle:version><sparkle:shortVersionString>${version}</sparkle:shortVersionString><enclosure url="${url}" length="123" /></item>`;
}
async function signed(xml) {
  const bytes = encoder.encode(xml);
  const signature = Buffer.from(await crypto.subtle.sign('Ed25519', keys.privateKey, bytes)).toString('base64');
  return encoder.encode(`${xml}<!-- sparkle-signatures:\nedSignature: ${signature}\nlength: ${bytes.length}\n-->`);
}
test('chooses the highest build, independent of version and item order', async () => {
  const result = await latestRelease(await signed(`<rss>${item('1.0', '9')}${item('0.1.1', '10')}${item('0.1.0', '2')}</rss>`), publicKey);
  assert.deepEqual(result, { version: '0.1.1', build: '10', url: 'https://updates.msgblast.app/downloads/msgblast-0.1.1-10.zip' });
});
test('rejects tampering with a valid signed feed', async () => {
  const bytes = await signed(`<rss>${item('0.1.1', '3')}</rss>`);
  bytes[8] ^= 1;
  await assert.rejects(latestRelease(bytes, publicKey), /signature failed/);
});
test('rejects missing signatures and wrong signing keys', async () => {
  await assert.rejects(latestRelease(encoder.encode('<rss/>'), publicKey), /Missing/);
  await assert.rejects(latestRelease(await signed(`<rss>${item('0.1.1', '3')}</rss>`)), /signature failed/);
});
test('rejects redirect destinations outside the immutable archive convention', async () => {
  for (const url of ['https://evil.example/app.zip', 'https://updates.msgblast.app/downloads/msgblast-0.1.1-3.zip?next=evil', 'https://updates.msgblast.app/downloads/msgblast-0.1.1-4.zip']) {
    await assert.rejects(latestRelease(await signed(`<rss>${item('0.1.1', '3', url)}</rss>`), publicKey), /destination/);
  }
});
test('release notes and comments cannot supply fake items', async () => {
  const fake = item('99.0', '999');
  const result = await latestRelease(await signed(`<rss><!--${fake}--><description><![CDATA[${fake}]]></description>${item('0.1.1', '3')}</rss>`), publicKey);
  assert.equal(result.build, '3');
});
test('rejects malformed or absent release metadata and oversized feeds', async () => {
  for (const xml of ['<rss/>', `<rss>${item('0.1.1', '0')}</rss>`, `<rss>${item('0.1.1', '3').replace('<enclosure', '<missing')}</rss>`]) {
    await assert.rejects(latestRelease(await signed(xml), publicKey));
  }
  await assert.rejects(latestRelease(new Uint8Array(256 * 1024 + 1), publicKey), /size/);
});
test('signed length counts UTF-8 bytes and must end at the signature trailer', async () => {
  const xml = `<rss><description>café 🍏</description>${item('0.1.1', '3')}</rss>`;
  assert.equal((await latestRelease(await signed(xml), publicKey)).build, '3');
  const bytes = await signed(xml);
  await assert.rejects(latestRelease(encoder.encode(new TextDecoder().decode(bytes).replace('<!-- sparkle-signatures:', 'extra<!-- sparkle-signatures:')), publicKey), /trailer/);
});


function request(method = 'GET', path = '/latest.zip') {
  return new Request(`https://updates.msgblast.app${path}`, { method });
}

async function assertUnavailable(response, method) {
  assert.equal(response.status, 503);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.equal(response.headers.get('Retry-After'), '60');
  assert.equal(response.headers.get('Location'), null);
  assert.equal(await response.text(), method === 'HEAD' ? '' : 'Download temporarily unavailable. Please try again.');
}

test('GET and HEAD redirect to the authenticated highest build without caching', async () => {
  const bytes = await signed(`<rss>${item('1.0', '9')}${item('0.1.1', '10')}</rss>`);
  const calls = [];
  const local = createDownloadWorker({ publicKey, fetchFeed: async (url, options) => {
    calls.push({ url, options });
    return new Response(bytes);
  } });
  for (const method of ['GET', 'HEAD']) {
    const response = await local.fetch(request(method));
    assert.equal(response.status, 302);
    assert.equal(response.headers.get('Location'), 'https://updates.msgblast.app/downloads/msgblast-0.1.1-10.zip');
    assert.equal(response.headers.get('Cache-Control'), 'no-store');
    assert.equal(await response.text(), '');
  }
  assert.equal(calls.length, 2);
  for (const { url, options } of calls) {
    assert.equal(url, 'https://updates.msgblast.app/appcast.xml');
    assert.equal(options.redirect, 'manual');
    assert.equal(options.headers['Cache-Control'], 'no-cache');
    assert.deepEqual(options.cf, { cacheTtl: 0, cacheEverything: false });
    assert.ok(options.signal instanceof AbortSignal);
  }
});

test('unrecognized routes and methods reject before fetching the feed', async () => {
  let calls = 0;
  const local = createDownloadWorker({ fetchFeed: async () => { calls++; throw new Error('Unexpected fetch'); } });
  for (const [method, path, status, text] of [
    ['GET', '/other.zip', 404, 'Not found'],
    ['POST', '/latest.zip', 405, 'Method not allowed'],
  ]) {
    const response = await local.fetch(request(method, path));
    assert.equal(response.status, status);
    assert.equal(response.headers.get('Cache-Control'), 'no-store');
    assert.equal(await response.text(), text);
    if (status === 405) assert.equal(response.headers.get('Allow'), 'GET, HEAD');
  }
  assert.equal(calls, 0);
});

test('upstream HTTP, transport, and signature failures return retryable uncached responses', async () => {
  for (const fetchFeed of [
    async () => new Response('unavailable', { status: 500 }),
    async () => { throw new Error('Network unavailable'); },
    async () => new Response('<rss>unsigned feed</rss>'),
  ]) {
    const local = createDownloadWorker({ publicKey, fetchFeed });
    for (const method of ['GET', 'HEAD']) await assertUnavailable(await local.fetch(request(method)), method);
  }
});

test('the deployed entry point rejects a fixture signing key', async context => {
  const bytes = await signed(`<rss>${item('0.1.1', '3')}</rss>`);
  context.mock.method(globalThis, 'fetch', async () => new Response(bytes));
  await assertUnavailable(await worker.fetch(request()), 'GET');
});

test('a feed timeout aborts its transport and returns a retryable response', async () => {
  const controller = new AbortController();
  let timeout;
  let aborted = false;
  const local = createDownloadWorker({
    timeoutSignal: milliseconds => { timeout = milliseconds; return controller.signal; },
    fetchFeed: (_url, { signal }) => new Promise((_resolve, reject) => {
      signal.addEventListener('abort', () => { aborted = true; reject(signal.reason); }, { once: true });
      controller.abort(new DOMException('Timed out', 'TimeoutError'));
    }),
  });
  await assertUnavailable(await local.fetch(request()), 'GET');
  assert.equal(timeout, 8000);
  assert.equal(aborted, true);
});

test('an oversized streamed feed stops reading and cancels the source', async () => {
  let chunks = 0;
  let cancelled = false;
  const body = new ReadableStream({
    pull(controller) { chunks++; controller.enqueue(new Uint8Array(128 * 1024)); },
    cancel() { cancelled = true; },
  }, { highWaterMark: 0 });
  const local = createDownloadWorker({ publicKey, fetchFeed: async () => new Response(body) });
  await assertUnavailable(await local.fetch(request()), 'GET');
  assert.equal(chunks, 3);
  assert.equal(cancelled, true);
});
