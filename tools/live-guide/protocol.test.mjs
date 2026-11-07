import test from 'node:test';
import assert from 'node:assert/strict';
import { validSample, summarize, tokenMatches } from './protocol.mjs';
export const sample = {
  room: 0, timestamp: 100, motionTimestamp: 99.96, poseDeltaSeconds: .04,
  position: [1, 2, 3], cameraTransform: [1,0,0,0,0,1,0,0,0,0,1,0,1,2,3,1],
  fieldDeviceMicrotesla: [30, 40, 0], magnitudeMicrotesla: 50,
  calibrationAccuracy: 2, deviceAttitudeQuaternion: [0,0,0,1]
};
test('accepts synchronized measurements, rejects stale or inconsistent pairings', () => {
  assert.equal(validSample(sample), true);
  for (const changes of [{ poseDeltaSeconds: .2 }, { motionTimestamp: 98 }, { magnitudeMicrotesla: 90 },
    { position: [0,0,0] }, { calibrationAccuracy: 10 }, { fieldDeviceMicrotesla: [NaN,0,0] }]) {
    assert.equal(validSample({ ...sample, ...changes }), false);
  }
});
test('snapshot distinguishes live, stale and absent measurements', () => {
  const s = { ...sample, receivedAt: 10000 };
  assert.equal(summarize([s], 11000).fresh, true);
  assert.equal(summarize([s], 14000).fresh, false);
  assert.equal(summarize([s], 80000).sampleCount, 0);
  assert.equal(summarize([]).fresh, false);
});
test('pair codes require exact matching', () => {
  assert.equal(tokenMatches('abcdef123456', 'abcdef123456'), true);
  assert.equal(tokenMatches('abcdef123456', 'abcdef123457'), false);
  assert.equal(tokenMatches(undefined, 'abcdef123456'), false);
  assert.equal(tokenMatches('', 'abcdef123456'), false);
});
