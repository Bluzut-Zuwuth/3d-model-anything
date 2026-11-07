import test from 'node:test';
import assert from 'node:assert/strict';
import { parseMagneticRecording, magnitudeRange, visibleSamples } from '../apps/room-viewer/src/magnetic-data.ts';

function recording() {
  return {
    format: 'magnetic-capture/1', units: 'microtesla', coordinateSystem: 'ARKit session world',
    attitudeReferenceFrame: 'device', device: 'test fixture', sampleLimitReached: false,
    samples: [0, 1, 2].map((n) => ({
      room: 0, timestamp: 10 + n, motionTimestamp: 10 + n - 0.02, poseDeltaSeconds: 0.02,
      position: [n, n * 0.5, 0], cameraTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, n, n * 0.5, 0, 1],
      fieldDeviceMicrotesla: [30, 40, 0], magnitudeMicrotesla: 50,
      calibrationAccuracy: n - 1, deviceAttitudeQuaternion: [0, 0, 0, 1],
    })),
  };
}

test('reads room-scoped samples, magnitude and calibrated height slices', () => {
  const r = parseMagneticRecording(recording());
  assert.deepEqual(magnitudeRange(r.samples), [50, 50]);
  assert.deepEqual(visibleSamples(r.samples, true, 0, 0.75).map(s => s.timestamp), [11]);
  assert.equal(visibleSamples(r.samples, false, 0, 1).length, 3);
  assert.equal(magnitudeRange([]), null);
});

test('rejects stale or inconsistent pose/sensor timing', () => {
  const r = recording(); r.samples[0].poseDeltaSeconds = 0.11;
  assert.throws(() => parseMagneticRecording(r), /Invalid/);
  r.samples[0].poseDeltaSeconds = 0.01;
  assert.throws(() => parseMagneticRecording(r), /Invalid/);
});

test('rejects inconsistent magnitude, positions and non-finite vectors', () => {
  let r = recording(); r.samples[0].magnitudeMicrotesla = 500;
  assert.throws(() => parseMagneticRecording(r), /Inconsistent/);
  r = recording(); r.samples[0].position[0] = 2;
  assert.throws(() => parseMagneticRecording(r), /Inconsistent/);
  r = recording(); r.samples[0].fieldDeviceMicrotesla[0] = NaN;
  assert.throws(() => parseMagneticRecording(r), /Invalid/);
});

test('rejects wrong units, malformed vectors and reordered timestamps', () => {
  let r = recording(); r.units = 'milligauss';
  assert.throws(() => parseMagneticRecording(r), /Unsupported/);
  r = recording(); r.samples[0].cameraTransform.pop();
  assert.throws(() => parseMagneticRecording(r), /Invalid/);
  r = recording(); r.samples.reverse();
  assert.throws(() => parseMagneticRecording(r), /Invalid/);
});

test('empty recordings remain valid and produce no inferred measurements', () => {
  const r = recording(); r.samples = [];
  assert.deepEqual(parseMagneticRecording(r).samples, []);
});
