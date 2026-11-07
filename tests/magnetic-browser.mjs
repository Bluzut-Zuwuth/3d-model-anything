// Run after installing @playwright/test temporarily; does not require a real scan.
import { chromium } from '@playwright/test';
import { createServer } from 'vite';
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import assert from 'node:assert/strict';

const root = resolve(import.meta.dirname, '..');
const fixture = resolve(root, '../magnetic-browser-fixtures/capture');
await mkdir(resolve(fixture, 'magnetic'), { recursive: true });
await mkdir(resolve(fixture, 'mesh'), { recursive: true });
const samples = [0, 1, 2].map(n => ({
  room: 0, timestamp: 10 + n, motionTimestamp: 10 + n - 0.02, poseDeltaSeconds: 0.02,
  position: [n * 0.3, n * 0.5, 0],
  cameraTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, n * 0.3, n * 0.5, 0, 1],
  fieldDeviceMicrotesla: [30, 40 + n * 10, 0], magnitudeMicrotesla: Math.hypot(30, 40 + n * 10),
  calibrationAccuracy: n - 1, deviceAttitudeQuaternion: [0, 0, 0, 1],
}));
await writeFile(resolve(fixture, 'manifest.json'), JSON.stringify({ format: 'house-capture/5', magneticFiles: ['magnetic/room-0.json'], rooms: [{ index: 0, name: 'Synthetic test room', mesh: { file: 'mesh/room-0.ply' } }] }));
await writeFile(resolve(fixture, 'magnetic/room-0.json'), JSON.stringify({ format: 'magnetic-capture/1', units: 'microtesla', coordinateSystem: 'ARKit session', attitudeReferenceFrame: 'device', device: 'synthetic fixture', sampleLimitReached: false, samples }));
await writeFile(resolve(fixture, 'mesh/room-0.ply'), 'ply\nformat ascii 1.0\nelement vertex 4\nproperty float x\nproperty float y\nproperty float z\nelement face 2\nproperty list uchar int vertex_indices\nend_header\n-1 -0.1 -1\n1 -0.1 -1\n1 -0.1 1\n-1 -0.1 1\n3 0 1 2\n3 0 2 3\n');
const server = await createServer({ configFile: resolve(root, 'apps/room-viewer/vite.config.ts'), server: { port: 5190, host: '127.0.0.1' } });
let browser;
try {
  await server.listen();
  browser = await chromium.launch({ channel: 'msedge', headless: true });
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto('http://127.0.0.1:5190/magnetic.html');
  await page.locator('#folder').setInputFiles(fixture);
  await page.getByText('2 / 3 samples shown', { exact: false }).waitFor();
  assert.match(await page.locator('#status').textContent(), /scan mesh loaded/);
  await page.locator('#calibrated').uncheck();
  assert.match(await page.locator('#status').textContent(), /3 \/ 3/);
  await page.locator('#max-y').fill('0.6');
  assert.match(await page.locator('#status').textContent(), /2 \/ 3/);
  await page.locator('#max-y').fill('-1');
  assert.match(await page.locator('#status').textContent(), /valid Y range/);
  await page.locator('#max-y').fill('1');
  await page.locator('#fit').click();
  await page.screenshot({ path: resolve(root, '../../outputs/magnetic-survey-preview.png'), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: resolve(root, '../magnetic-browser-fixtures/mobile.png'), fullPage: true });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  const empty = resolve(root, '../magnetic-browser-fixtures/old-capture');
  await mkdir(empty, { recursive: true });
  await writeFile(resolve(empty, 'manifest.json'), JSON.stringify({ format: 'house-capture/5', rooms: [{ index: 0, name: 'Old capture' }] }));
  await page.locator('#folder').setInputFiles(empty);
  await page.getByText('No magnetic recording in this capture.', { exact: false }).waitFor();
  assert.equal(await page.locator('#room').isDisabled(), true);
  assert.deepEqual(errors, []);
  console.log('PASS: folder import, PLY rendering, calibration and height filters, invalid range, mobile layout, old-capture empty state, no browser errors. Screenshots use synthetic measurements.');
} finally { await browser?.close(); await server.close(); }
