// The same signed feed drives Sparkle updates and first-time downloads.
const FEED_URL = 'https://updates.msgblast.app/appcast.xml';
const PUBLIC_KEY = 'viRxKUaLjuWqZ8CaRISfDeXh6NF1cTPZASOjTzNjy3I=';
const MAX_FEED_BYTES = 256 * 1024;
const NO_STORE = { 'Cache-Control': 'no-store', 'Content-Type': 'text/plain; charset=utf-8' };

function decodeBase64(value) {
  return Uint8Array.from(atob(value), character => character.charCodeAt(0));
}

export async function latestRelease(bytes, publicKey = PUBLIC_KEY) {
  if (!bytes.length || bytes.length > MAX_FEED_BYTES) throw new Error('Invalid feed size');
  const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decode(bytes);
  const signature = text.match(/<!-- sparkle-signatures:\s*edSignature: ([A-Za-z0-9+/=]+)\s*length: ([0-9]+)\s*-->\s*$/);
  if (!signature) throw new Error('Missing signed feed');
  const length = Number(signature[2]);
  if (!Number.isSafeInteger(length) || length <= 0 || length >= bytes.length) throw new Error('Invalid signed length');
  const signed = bytes.slice(0, length);
  // The trailer must start exactly where Sparkle's signed bytes end.
  if (new TextDecoder().decode(bytes.slice(length)).trim() !== signature[0].trim()) throw new Error('Invalid signature trailer');
  const key = await crypto.subtle.importKey('raw', decodeBase64(publicKey), 'Ed25519', false, ['verify']);
  if (!await crypto.subtle.verify('Ed25519', key, decodeBase64(signature[1]), signed)) throw new Error('Feed signature failed');

  // Parse only generate_appcast's bounded, authenticated item format. Release-note
  // CDATA and comments are removed so prose cannot masquerade as an item.
  const xml = new TextDecoder().decode(signed).replace(/<!\[CDATA\[[\s\S]*?\]\]>/g, '').replace(/<!--[\s\S]*?-->/g, '');
  let latest;
  for (const match of xml.matchAll(/<item>([\s\S]*?)<\/item>/g)) {
    const item = match[1];
    const build = item.match(/<sparkle:version>([1-9][0-9]*)<\/sparkle:version>/)?.[1];
    const version = item.match(/<sparkle:shortVersionString>([0-9]+(?:\.[0-9]+)*)<\/sparkle:shortVersionString>/)?.[1];
    const archive = item.match(/<enclosure\s[^>]*\burl="([^"]+)"/)?.[1];
    if (!build || !version || !archive) throw new Error('Invalid release item');
    const expected = 'https://updates.msgblast.app/downloads/msgblast-' + version + '-' + build + '.zip';
    if (archive !== expected) throw new Error('Invalid archive destination');
    if (!latest || BigInt(build) > BigInt(latest.build)) latest = { version, build, url: archive };
  }
  if (!latest) throw new Error('No published release');
  return latest;
}

async function readFeed(response) {
  if (!response.ok || !response.body) throw new Error('Feed unavailable');
  const reader = response.body.getReader();
  const chunks = [];
  let length = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > MAX_FEED_BYTES) throw new Error('Feed too large');
      chunks.push(value);
    }
  } finally {
    await reader.cancel();
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}

// Dependencies are fixed for the deployed entry point; local fixtures can supply
// their own transport, signing key, and timeout without network or release keys.
export function createDownloadWorker({ fetchFeed = (...args) => fetch(...args), publicKey = PUBLIC_KEY, timeoutSignal = AbortSignal.timeout } = {}) {
  return {
    async fetch(request) {
      const url = new URL(request.url);
      if (url.pathname !== '/latest.zip') return new Response('Not found', { status: 404, headers: NO_STORE });
      if (!['GET', 'HEAD'].includes(request.method)) return new Response('Method not allowed', { status: 405, headers: { ...NO_STORE, Allow: 'GET, HEAD' } });
      try {
        const feed = await fetchFeed(FEED_URL, {
          redirect: 'manual', signal: timeoutSignal(8000),
          headers: { 'User-Agent': 'msgblast-release-verifier', 'Cache-Control': 'no-cache' },
          cf: { cacheTtl: 0, cacheEverything: false }
        });
        const latest = await latestRelease(await readFeed(feed), publicKey);
        if (request.method === 'GET') console.log(JSON.stringify({ event: 'download_redirect', version: latest.version, build: latest.build }));
        return new Response(null, { status: 302, headers: { ...NO_STORE, Location: latest.url } });
      } catch (error) {
        console.error(JSON.stringify({ event: 'download_unavailable', reason: error.message }));
        return new Response(request.method === 'HEAD' ? null : 'Download temporarily unavailable. Please try again.', { status: 503, headers: { ...NO_STORE, 'Retry-After': '60' } });
      }
    }
  };
}

export default createDownloadWorker();
