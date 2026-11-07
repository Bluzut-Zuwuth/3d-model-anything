import { timingSafeEqual } from 'node:crypto';

export function tokenMatches(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const aa = Buffer.from(a), bb = Buffer.from(b);
  return aa.length === bb.length && timingSafeEqual(aa, bb);
}
const vector = (x, n) => Array.isArray(x) && x.length === n && x.every(Number.isFinite);
export function validSample(s) {
  if (!s || !Number.isInteger(s.room) || s.room < 0 || !Number.isFinite(s.timestamp) || !Number.isFinite(s.motionTimestamp) ||
      !Number.isFinite(s.poseDeltaSeconds) || s.poseDeltaSeconds < 0 || s.poseDeltaSeconds > .1 ||
      Math.abs(Math.abs(s.timestamp - s.motionTimestamp) - s.poseDeltaSeconds) > .00001 ||
      !vector(s.position, 3) || !vector(s.cameraTransform, 16) || !vector(s.fieldDeviceMicrotesla, 3) ||
      !vector(s.deviceAttitudeQuaternion, 4) || ![-1, 0, 1, 2].includes(s.calibrationAccuracy) ||
      !Number.isFinite(s.magnitudeMicrotesla) || s.magnitudeMicrotesla < 0) return false;
  return Math.abs(Math.hypot(...s.fieldDeviceMicrotesla) - s.magnitudeMicrotesla) < .001 &&
    s.position.every((v, i) => Math.abs(v - s.cameraTransform[12 + i]) < .001);
}
export function validLiDAR(s) {
  return !!s && Number.isFinite(s.timestamp) && Number.isInteger(s.room) && s.room >= 0 &&
    vector(s.position, 3) && [s.width, s.height].every(n => Number.isInteger(n) && n > 0 && n <= 4096) &&
    Number.isInteger(s.sampleStride) && s.sampleStride >= 1 && s.sampleStride <= 64 &&
    Number.isInteger(s.validSampledPoints) && s.validSampledPoints >= 0 &&
    s.validSampledPoints <= Math.ceil(s.width / s.sampleStride) * Math.ceil(s.height / s.sampleStride) &&
    Number.isInteger(s.meshAnchors) && s.meshAnchors >= 0 && s.meshAnchors <= 100000 &&
    (s.validSampledPoints === 0 ? s.nearestMeters == null && s.farthestMeters == null :
      Number.isFinite(s.nearestMeters) && Number.isFinite(s.farthestMeters) && s.nearestMeters > 0 &&
      s.farthestMeters >= s.nearestMeters && s.farthestMeters <= 10);
}
export function summarize(samples, now = Date.now()) {
  const room = samples.at(-1)?.room;
  const recent = samples.filter(x => now - x.receivedAt < 60000 && x.room === room);
  const latest = recent.at(-1);
  if (!latest) return { fresh: false, sampleCount: 0, note: 'No measurements in the last minute. Enable magnetic recording and start scanning.' };
  const strengths = recent.map(x => x.magnitudeMicrotesla).sort((a, b) => a - b);
  return {
    fresh: now - latest.receivedAt < 3000, ageSeconds: (now - latest.receivedAt) / 1000,
    sampleCount: recent.length, units: 'microtesla', min: strengths[0], max: strengths.at(-1),
    median: strengths[Math.floor(strengths.length / 2)], latest,
    lastReadings: recent.slice(-8),
    note: 'Position Y is ARKit world Y, NOT height above floor. Device magnetic vectors are NOT ARKit world vectors. Strength alone cannot prove a source or predict Rebocap heading error.'
  };
}
