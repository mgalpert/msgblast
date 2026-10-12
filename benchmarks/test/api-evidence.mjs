import { chromium } from "@playwright/test";
import { mkdir, writeFile, readFile } from "node:fs/promises";
import { harness, projection, canonical, digest } from "./harness.mjs";
const directory =
  process.env.EVIDENCE_DIR ?? "../docs/evidence/benchmark-service";
await mkdir(directory, { recursive: true });
const h = await harness();
let browser, context;
const steps = [];
try {
  const auth = await h.token();
  browser = await chromium.launch({ headless: true });
  context = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
    recordVideo: { dir: directory, size: { width: 1440, height: 1000 } },
  });
  const page = await context.newPage();
  async function record(action, result) {
    steps.push({ action, ...result });
    console.log(JSON.stringify(steps.at(-1)));
    await page.setContent(
      '<!doctype html><html><meta charset="utf-8"><body style="background:#10181b;color:#dbe8eb;font:18px system-ui;padding:40px"><h1>Local benchmark API workflow</h1><p>Synthetic signed fixture account; token not displayed. Actual local Worker / D1 / private R2 / Queue responses.</p><p>This is an API evidence viewer, not the native account or preview interface. Private sync off; contribution is a separate choice.</p><pre style="white-space:pre-wrap;font-size:18px;line-height:1.55"></pre></body></html>',
    );
    await page
      .locator("pre")
      .evaluate(
        (node, text) => (node.textContent = text),
        steps.map((s) => JSON.stringify(s, null, 2)).join("\n\n"),
      );
    await page.waitForTimeout(500);
  }
  const account = await h.request("/api/v1/account", "GET", undefined, auth);
  await record("GET /api/v1/account", {
    status: account.status,
    identity: "Verified fixture bearer; no live OIDC login",
  });
  const without = await h.request(
    "/api/v1/publications",
    "POST",
    { consent: false, projection, previewHash: digest(canonical(projection)) },
    auth,
  );
  await record("POST publication without consent", {
    status: without.status,
    error: (await without.json()).error,
  });
  const created = await h.request(
      "/api/v1/publications",
      "POST",
      { consent: true, projection, previewHash: digest(canonical(projection)) },
      auth,
    ),
    publication = await created.json();
  const counts = await h.db
    .prepare(
      "SELECT (SELECT count(*) FROM sessions) AS privateSessions,(SELECT count(*) FROM contribution_revisions) AS contributions",
    )
    .first();
  await record("POST exact preview with explicit publication consent", {
    status: created.status,
    projectionHash: publication.projectionHash,
    ...counts,
  });
  await record("GET unlisted page without account", {
    status: (await h.request(publication.path)).status,
    visibility: "Direct link; no-store, noindex; recipients may forward",
  });
  const revoke = await h.request(
    `/api/v1/publications/${publication.id}`,
    "DELETE",
    undefined,
    auth,
  );
  await record("DELETE owner publication", {
    status: revoke.status,
    result: (await revoke.json()).status,
  });
  await record("GET revoked page / JSON", {
    page: (await h.request(publication.path)).status,
    data: (await h.request(publication.path + "/data")).status,
  });
  await page.screenshot({
    path: directory + "/api-workflow.png",
    fullPage: true,
  });
  const video = page.video();
  await context.close();
  await video.saveAs(directory + "/api-workflow.webm");
  await writeFile(
    directory + "/api-workflow.json",
    JSON.stringify(
      {
        fixture: true,
        limits:
          "Synthetic account/inputs; no native UI or live services; scripted pauses",
        steps,
      },
      null,
      2,
    ) + "\n",
  );
} finally {
  await browser?.close();
  await h.close();
}
