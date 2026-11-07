import test from 'node:test';
import assert from 'node:assert/strict';
import { validSample, validLiDAR, summarize, tokenMatches } from './protocol.mjs';
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
test('LiDAR summary bounds and empty-depth handling', () => {
  const s = { timestamp: 100, room: 0, position: [1,2,3], width: 256, height: 192, sampleStride: 8,
    validSampledPoints: 400, meshAnchors: 12, nearestMeters: .3, farthestMeters: 4.1 };
  assert.equal(validLiDAR(s), true);
  assert.equal(validLiDAR({ ...s, validSampledPoints: 900 }), false);
  assert.equal(validLiDAR({ ...s, farthestMeters: Infinity }), false);
  assert.equal(validLiDAR({ ...s, nearestMeters: 5 }), false);
  assert.equal(validLiDAR({ ...s, position: [1,NaN,3] }), false);
  assert.equal(validLiDAR({ ...s, validSampledPoints: 0, nearestMeters: undefined, farthestMeters: undefined }), true);
});
