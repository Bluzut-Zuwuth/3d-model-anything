import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import net from 'node:net';
import { once } from 'node:events';

const sample = { room: 0, timestamp: 100, motionTimestamp: 99.96, poseDeltaSeconds: .04,
  position: [1,2,3], cameraTransform: [1,0,0,0,0,1,0,0,0,0,1,0,1,2,3,1],
  fieldDeviceMicrotesla: [30,40,0], magnitudeMicrotesla: 50, calibrationAccuracy: 2, deviceAttitudeQuaternion: [0,0,0,1] };
const delay = ms => new Promise(r => setTimeout(r, ms));
async function waitFor(check) {
  for (let i = 0; i < 100; i++) { const v = await check(); if (v) return v; await delay(30); }
  throw new Error('Timed out');
}
test('pairing, readable telemetry, Unicode questions, rejected second phone and shutdown', { timeout: 15000 }, async t => {
  const base = 22000 + Math.floor(Math.random() * 10000);
  const proc = spawn(process.execPath, ['tools/live-guide/server.mjs'], {
    env: { ...process.env, SCAN_PORT: String(base), SCAN_DASHBOARD_PORT: String(base + 1) }, windowsHide: true
  });
  t.after(() => proc.kill());
  let output = ''; proc.stdout.on('data', b => { output += b; });
  proc.stderr.on('data', b => { output += b; });
  const token = await waitFor(() => output.match(/Pairing code: (\w+)/)?.[1]);
  const connect = async () => { const s = net.connect(base, '127.0.0.1'); await once(s, 'connect'); return s; };
  const bad = await connect(); const badClosed = once(bad, 'close');
  bad.write(JSON.stringify({ type: 'hello', version: 1, token: 'wrong' }) + '\n'); await badClosed;
  const phone = await connect(); t.after(() => phone.destroy());
  let messages = ''; phone.on('data', b => { messages += b; });
  phone.write(JSON.stringify({ type: 'hello', version: 1, token }) + '\n');
  await waitFor(() => messages.includes('ready'));
  const duplicate = await connect(); const dupClosed = once(duplicate, 'close');
  duplicate.write(JSON.stringify({ type: 'hello', version: 1, token }) + '\n'); await dupClosed;
  phone.write(JSON.stringify({ type: 'status', phase: 'scanning', paused: false, tracking: 'normal', room: 0, roomName: 'Test room' }) + '\n');
  phone.write(JSON.stringify({ type: 'sample', sample }) + '\n');
  phone.write(JSON.stringify({ type: 'lidar', timestamp: 100, room: 0, position: [1,2,3], width: 256, height: 192,
    sampleStride: 8, validSampledPoints: 300, meshAnchors: 8, nearestMeters: .5, farthestMeters: 3 }) + '\n');
  const get = async () => (await fetch(`http://127.0.0.1:${base + 1}/snapshot`)).json();
  const data = await waitFor(async () => { const d = await get(); return d.measurements.sampleCount === 1 && d; });
  assert.equal(data.measurements.latest.magnitudeMicrotesla, 50);
  assert.equal(data.status.roomName, 'Test room');
  assert.equal(data.measurements.fresh, true);
  const depth = await waitFor(async () => (await get()).lidar);
  assert.equal(depth.meshAnchors, 8);
  assert.equal(depth.fresh, true);
  const question = Buffer.from(JSON.stringify({ type: 'question', text: 'Höhe?' }) + '\n');
  const index = question.indexOf(Buffer.from('ö')) + 1;
  phone.write(question.subarray(0, index)); await delay(20); phone.write(question.subarray(index));
  await waitFor(() => messages.includes('telemetry-only'));
  const closed = once(phone, 'close');
  phone.write(JSON.stringify({ type: 'sample', sample: { ...sample, magnitudeMicrotesla: 200 } }) + '\n');
  await closed;
  await waitFor(async () => !(await get()).connected);
});
