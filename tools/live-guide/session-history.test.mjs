import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { inflateRawSync } from 'node:zlib';
import { SessionHistory } from './session-history.mjs';
import { crc32 } from './zip.mjs';

test('whole-session extrema and every sample survive recent-buffer limits and time-bin compaction', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'survey-history-'));
  const start = 1700000000000, history = new SessionHistory(root, start);
  for (let i = 0; i < 10000; i++) {
    history.event('sample', { room: 0, position: [i / 100, 0, 1], magnitudeMicrotesla: i === 1 ? 150 : 50,
      calibrationAccuracy: 2 }, start + i * 1000);
  }
  history.event('question', { text: 'Compare the first pass to now.' }, start + 10001000);
  history.event('reply', { text: 'The earlier peak was at one second.' }, start + 10002000);
  const summary = history.guideContext();
  assert.equal(summary.magnetic.sampleCount, 10000);
  assert.equal(summary.magnetic.max.elapsedSeconds, 1);
  assert.equal(summary.magnetic.max.magnitudeMicrotesla, 150);
  assert.equal(summary.timeline.reduce((sum, b) => sum + b.count, 0), 10000);
  assert.ok(summary.timeline.length <= 96);
  assert.equal(summary.conversation[0].text, 'Compare the first pass to now.');
  const result = await history.finish('test-disconnect', start + 10003000);
  const data = JSON.parse(await readFile(result.json, 'utf8'));
  assert.equal(data.events.filter(x => x.type === 'sample').length, 10000);
  assert.equal(data.events.at(-1).type, 'end');
  assert.equal(data.summary.reason, 'test-disconnect');
  const zip = await readFile(result.zip);
  assert.equal(zip.readUInt32LE(zip.length - 22), 0x06054b50);
  let central = zip.readUInt32LE(zip.length - 6);
  const files = {};
  for (let i = 0; i < 2; i++) {
    assert.equal(zip.readUInt32LE(central), 0x02014b50);
    const nameLength = zip.readUInt16LE(central + 28), compressed = zip.readUInt32LE(central + 20);
    const filename = zip.subarray(central + 46, central + 46 + nameLength).toString();
    const local = zip.readUInt32LE(central + 42);
    const content = local + 30 + zip.readUInt16LE(local + 26) + zip.readUInt16LE(local + 28);
    files[filename] = inflateRawSync(zip.subarray(content, content + compressed));
    assert.equal(crc32(files[filename]), zip.readUInt32LE(central + 16));
    central += 46 + nameLength + zip.readUInt16LE(central + 30) + zip.readUInt16LE(central + 32);
  }
  assert.equal(JSON.parse(files['session.json'].toString()).summary.magnetic.sampleCount, 10000);
  assert.match(files['summary.md'].toString(), /phone-only environmental data collection/i);
});
test('ZIP CRC matches a standard independent check value', () => {
  assert.equal(crc32(Buffer.from('123456789')), 0xcbf43926);
  assert.equal(crc32(Buffer.from('56789'), crc32(Buffer.from('1234'))), 0xcbf43926);
});
