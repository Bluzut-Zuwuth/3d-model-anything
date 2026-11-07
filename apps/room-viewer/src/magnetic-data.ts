export interface MagneticSample {
  room: number;
  timestamp: number;
  motionTimestamp: number;
  poseDeltaSeconds: number;
  position: [number, number, number];
  cameraTransform: number[];
  fieldDeviceMicrotesla: [number, number, number];
  magnitudeMicrotesla: number;
  calibrationAccuracy: number;
  deviceAttitudeQuaternion: [number, number, number, number];
}

export interface MagneticRecording {
  format: 'magnetic-capture/1';
  units: 'microtesla';
  coordinateSystem: string;
  attitudeReferenceFrame: string;
  device: string;
  sampleLimitReached: boolean;
  samples: MagneticSample[];
}

function finite(value: unknown): value is number { return typeof value === 'number' && Number.isFinite(value); }
function vector(value: unknown, length: number): value is number[] {
  return Array.isArray(value) && value.length === length && value.every(finite);
}

export function parseMagneticRecording(input: unknown): MagneticRecording {
  if (!input || typeof input !== 'object') throw new Error('Not a magnetic recording.');
  const r = input as Record<string, unknown>;
  if (r.format !== 'magnetic-capture/1' || r.units !== 'microtesla' ||
      !Array.isArray(r.samples) || r.samples.length > 9_000 ||
      typeof r.coordinateSystem !== 'string' || typeof r.attitudeReferenceFrame !== 'string' ||
      typeof r.device !== 'string' || typeof r.sampleLimitReached !== 'boolean') {
    throw new Error('Unsupported or malformed magnetic recording.');
  }
  let lastTime = -Infinity;
  for (const [i, entry] of r.samples.entries()) {
    const s = entry as MagneticSample | null;
    if (!s || !Number.isInteger(s.room) || s.room < 0 ||
        !finite(s.timestamp) || !finite(s.motionTimestamp) ||
        !finite(s.poseDeltaSeconds) || s.poseDeltaSeconds < 0 || s.poseDeltaSeconds > 0.1 ||
        Math.abs(Math.abs(s.timestamp - s.motionTimestamp) - s.poseDeltaSeconds) > 1e-5 ||
        s.timestamp <= lastTime || !vector(s.position, 3) ||
        !vector(s.cameraTransform, 16) || !vector(s.fieldDeviceMicrotesla, 3) ||
        !vector(s.deviceAttitudeQuaternion, 4) ||
        !finite(s.magnitudeMicrotesla) || s.magnitudeMicrotesla < 0 ||
        ![-1, 0, 1, 2].includes(s.calibrationAccuracy)) {
      throw new Error(`Invalid magnetic sample ${i + 1}.`);
    }
    if (Math.abs(Math.hypot(...s.fieldDeviceMicrotesla) - s.magnitudeMicrotesla) > 1e-4 ||
        s.position.some((n, k) => Math.abs(n - s.cameraTransform[12 + k]) > 0.001)) {
      throw new Error(`Inconsistent magnetic sample ${i + 1}.`);
    }
    lastTime = s.timestamp;
  }
  return input as MagneticRecording;
}

export function visibleSamples(samples: MagneticSample[], calibratedOnly: boolean, minY: number, maxY: number) {
  return samples.filter(s => (!calibratedOnly || s.calibrationAccuracy >= 0) && s.position[1] >= minY && s.position[1] <= maxY);
}

export function magnitudeRange(samples: MagneticSample[]): [number, number] | null {
  if (!samples.length) return null;
  let low = Infinity, high = -Infinity;
  for (const s of samples) { low = Math.min(low, s.magnitudeMicrotesla); high = Math.max(high, s.magnitudeMicrotesla); }
  return [low, high];
}
