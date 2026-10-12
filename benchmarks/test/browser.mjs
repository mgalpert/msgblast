import { chromium } from "@playwright/test";
import assert from "node:assert/strict";
import { mkdir } from "node:fs/promises";
import { harness, projection, publication } from "./harness.mjs";
const dir = process.env.EVIDENCE_DIR ?? "../docs/evidence/benchmark-service";
await mkdir(dir, { recursive: true });
const h = await harness();
let browser;
try {
  const auth = await h.token();
  const result = await publication(h, auth);
  assert.equal(result.status, 201);
  const link = await result.json();
  const base = (await h.mf.ready).origin;
  browser = await chromium.launch({ headless: true });
  const desktop = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
    recordVideo: { dir, size: { width: 1440, height: 1000 } },
  });
  const page = await desktop.newPage();
  await page.goto(base + link.path);
  await page
    .getByRole("heading", { name: projection.title, exact: true })
    .waitFor();
  await page.waitForTimeout(800);
  assert.equal(await page.evaluate(() => window.compromised), undefined);
  assert.equal(await page.locator(".agent").count(), 2);
  assert.equal(await page.locator(".agent").nth(1).isVisible(), true);
  assert.equal(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
    true,
  );
  assert.equal(await page.locator(".message").count(), 3);
  await page.screenshot({ path: dir + "/reader-desktop.png", fullPage: true });
  await page.locator('[data-message="extra-1"]').scrollIntoViewIfNeeded();
  await page.waitForTimeout(800);
  const mobile = await browser.newContext({
    viewport: { width: 390, height: 844 },
    isMobile: true,
    deviceScaleFactor: 1,
    recordVideo: { dir, size: { width: 390, height: 844 } },
  });
  const phone = await mobile.newPage();
  await phone.goto(base + link.path);
  await phone.screenshot({
    path: dir + "/reader-mobile-messages.png",
    fullPage: true,
  });
  assert.equal(await phone.locator('[data-message="extra-1"]').count(), 1);
  await phone.locator('[data-message="extra-1"]').scrollIntoViewIfNeeded();
  await phone.waitForTimeout(700);
  await phone.getByRole("button", { name: "Agent B", exact: true }).click();
  await phone.waitForTimeout(700);
  assert.equal(
    await phone.locator('article[data-agent="agent-b"]').isVisible(),
    true,
  );
  assert.equal(
    await phone.locator('article[data-agent="agent-a"]').isVisible(),
    false,
  );
  assert.equal(
    await phone.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
    true,
  );
  await phone.screenshot({ path: dir + "/reader-mobile.png", fullPage: true });
  const privateProjection = structuredClone(projection);
  privateProjection.includesPrivate = true;
  privateProjection.turns[0].scope = "private";
  privateProjection.turns[0].targetedAgentIDs = ["agent-b"];
  privateProjection.turns[0].replies = [privateProjection.turns[0].replies[1]];
  const privateLink = await publication(h, auth, privateProjection).then((r) =>
    r.json(),
  );
  const privatePage = await mobile.newPage();
  await privatePage.goto(base + privateLink.path);
  await privatePage
    .getByRole("button", { name: "Agent A", exact: true })
    .click();
  assert.equal(
    await privatePage
      .getByText("Not asked in this turn.", { exact: true })
      .isVisible(),
    true,
  );
  await privatePage.screenshot({
    path: dir + "/reader-private-target.png",
    fullPage: true,
  });
  await privatePage.close();
  // The owner revokes through the actual authenticated API. This local synthetic fixture has no native account UI.
  assert.equal(
    (
      await h.request(
        `/api/v1/publications/${link.id}`,
        "DELETE",
        undefined,
        auth,
      )
    ).status,
    200,
  );
  await page.goto(base + "/robots.txt");
  await page.goBack();
  await page
    .getByRole("heading", { name: "Comparison unavailable", exact: true })
    .waitFor();
  await page.waitForTimeout(800);
  await page.screenshot({ path: dir + "/reader-revoked.png", fullPage: true });
  await phone.reload();
  assert.equal(
    await phone
      .getByRole("heading", { name: "Comparison unavailable", exact: true })
      .isVisible(),
    true,
  );
  const video = page.video();
  await desktop.close();
  await video.saveAs(dir + "/reader.webm");
  const mobileVideo = phone.video();
  await phone.waitForTimeout(700);
  await mobile.close();
  await mobileVideo.saveAs(dir + "/reader-mobile.webm");
  console.log(
    "PASS: desktop/mobile real local Worker reader, agent selection, hostile text inert, overflow, authenticated revoke and unavailable result. Synthetic fixture identity/content; no live provider or native flow.",
  );
} finally {
  await browser?.close();
  await h.close();
}
