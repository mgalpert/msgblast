// Synthetic loopback Worker for native controller/Demo checks. No live calls.
import { mkdir, writeFile, realpath } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
const [serviceDirectory, directory] = process.argv.slice(2);
if (!serviceDirectory || !directory) throw new Error('Provide benchmarks checkout and temporary fixture directory');
const service = await realpath(serviceDirectory);
process.chdir(service);
const { harness } = await import(pathToFileURL(path.join(service, 'test/harness.mjs')));
await mkdir(directory, { recursive: true, mode: 0o700 });
const h = await harness();
const serviceURL = (await h.mf.ready).toString();
const accessToken = await h.token('native-demo', { exp: '1h' });
await writeFile(path.join(directory, 'benchmark-fixture.json'), JSON.stringify({ serviceURL, accessToken }), { mode: 0o600 });
console.log(JSON.stringify({ serviceURL, fixtureDirectory: directory, identity: 'Synthetic signed fixture; no live OAuth', token: 'not displayed' }));
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, async () => { await h.close(); process.exit(0); });
await new Promise(() => {});
