import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { PLYLoader } from 'three/addons/loaders/PLYLoader.js';
import { parseMagneticRecording, visibleSamples, magnitudeRange, type MagneticSample } from './magnetic-data';

const folder = document.querySelector<HTMLInputElement>('#folder')!;
const roomSelect = document.querySelector<HTMLSelectElement>('#room')!;
const calibrated = document.querySelector<HTMLInputElement>('#calibrated')!;
const minY = document.querySelector<HTMLInputElement>('#min-y')!;
const maxY = document.querySelector<HTMLInputElement>('#max-y')!;
const status = document.querySelector<HTMLOutputElement>('#status')!;
const detail = document.querySelector<HTMLOutputElement>('#detail')!;
const view = document.querySelector<HTMLElement>('#view')!;
const canvas = document.querySelector<HTMLCanvasElement>('#magnetic-canvas')!;
const scene = new THREE.Scene();
scene.background = new THREE.Color('#111820');
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
const camera = new THREE.PerspectiveCamera(55, 1, 0.01, 2000);
camera.position.set(4, 4, 4);
const controls = new OrbitControls(camera, canvas);
controls.target.set(0, 0, 0);
const content = new THREE.Group(); scene.add(content);
scene.add(new THREE.HemisphereLight(0xffffff, 0x536171, 2));
scene.add(new THREE.AxesHelper(0.5));
let mesh: THREE.Mesh | undefined;
let dots: THREE.Points | undefined;
let samples: MagneticSample[] = [];
let shown: MagneticSample[] = [];
let truncated = false;
let epoch = 0;
let files = new Map<string, File>();
interface Room { index: number; name: string; mesh?: { file: string } }
let rooms: Room[] = [];

function render() { renderer.render(scene, camera); }
controls.addEventListener('change', render);
new ResizeObserver(() => {
  renderer.setSize(view.clientWidth, view.clientHeight, false);
  camera.aspect = view.clientWidth / Math.max(1, view.clientHeight);
  camera.updateProjectionMatrix(); render();
}).observe(view);

function release(object: THREE.Mesh | THREE.Points | undefined) {
  if (!object) return;
  content.remove(object); object.geometry.dispose();
  const materials = Array.isArray(object.material) ? object.material : [object.material];
  materials.forEach(m => m.dispose());
}

function fit() {
  const box = new THREE.Box3().setFromObject(content);
  if (box.isEmpty()) { controls.target.set(0, 0, 0); camera.position.set(4, 4, 4); }
  else {
    const center = box.getCenter(new THREE.Vector3());
    const radius = Math.max(box.getSize(new THREE.Vector3()).length() / 2, 0.5);
    controls.target.copy(center);
    camera.position.copy(center).add(new THREE.Vector3(1, 0.9, 1).normalize().multiplyScalar(radius / Math.sin(THREE.MathUtils.degToRad(camera.fov / 2)) * 1.2));
  }
  controls.update(); render();
}

function updatePoints() {
  release(dots); dots = undefined;
  const lowY = Number(minY.value), highY = Number(maxY.value);
  if (!Number.isFinite(lowY) || !Number.isFinite(highY) || lowY > highY) {
    status.textContent = 'Enter a valid Y range, with minimum no greater than maximum.'; render(); return;
  }
  shown = visibleSamples(samples, calibrated.checked, lowY, highY);
  // Fixed per-room color scale: changing the height filter must not change a point's color.
  const range = magnitudeRange(samples.filter(s => !calibrated.checked || s.calibrationAccuracy >= 0));
  const positions: number[] = [], colors: number[] = [];
  for (const sample of shown) {
    positions.push(...sample.position);
    const fraction = range && range[1] > range[0] ? (sample.magnitudeMicrotesla - range[0]) / (range[1] - range[0]) : 0.5;
    const color = new THREE.Color('#4996ff').lerp(new THREE.Color('#ee993c'), fraction);
    colors.push(color.r, color.g, color.b);
  }
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
  geometry.setAttribute('color', new THREE.Float32BufferAttribute(colors, 3));
  dots = new THREE.Points(geometry, new THREE.PointsMaterial({ size: 0.065, vertexColors: true, sizeAttenuation: true, depthTest: true }));
  content.add(dots);
  status.textContent = `${shown.length} / ${samples.length} samples shown${mesh ? ' · scan mesh loaded' : ' · no scan mesh'}${range ? `\nRoom range: ${range[0].toFixed(1)}–${range[1].toFixed(1)} µT` : ''}${truncated ? '\nRecording reached its sample limit.' : ''}`;
  detail.textContent = 'Click a point to inspect its reading.';
  render();
}

function safePath(path: unknown): string {
  if (typeof path !== 'string' || !path || path.startsWith('/') || path.includes('\\') || path.split('/').some(p => p === '..' || p === '.' || p === '')) throw new Error('Invalid capture file path.');
  return path;
}

async function readJSON(file: File | undefined): Promise<unknown> {
  if (!file) throw new Error('A required capture file is missing.');
  if (file.size > 24_000_000) throw new Error('JSON file is too large.');
  return JSON.parse(await file.text());
}

async function loadRoom() {
  const request = ++epoch;
  release(mesh); mesh = undefined; release(dots); dots = undefined; samples = []; shown = [];
  detail.textContent = 'Click a point to inspect its reading.';
  const room = rooms.find(r => r.index === Number(roomSelect.value));
  if (!room) return;
  status.textContent = 'Loading local capture…'; render();
  try {
    const recording = parseMagneticRecording(await readJSON(files.get(`magnetic/room-${room.index}.json`)));
    if (recording.samples.some(s => s.room !== room.index)) throw new Error('Magnetic samples do not belong to the selected room.');
    if (request !== epoch) return;
    let geometry: THREE.BufferGeometry | undefined;
    if (room.mesh) {
      const file = files.get(safePath(room.mesh.file));
      if (!file) throw new Error('The scan mesh listed in the manifest is missing.');
      if (file.size > 256_000_000) throw new Error('Mesh exceeds the 256 MB viewer limit.');
      geometry = new PLYLoader().parse(await file.arrayBuffer());
      if (request !== epoch) { geometry.dispose(); return; }
      geometry.computeVertexNormals();
    }
    if (geometry) {
      mesh = new THREE.Mesh(geometry, new THREE.MeshStandardMaterial({ color: '#82909d', transparent: true, opacity: 0.22, side: THREE.DoubleSide, depthWrite: false }));
      content.add(mesh);
    }
    samples = recording.samples; truncated = recording.sampleLimitReached;
    let bottom = Infinity, top = -Infinity;
    for (const s of samples) { bottom = Math.min(bottom, s.position[1]); top = Math.max(top, s.position[1]); }
    minY.value = (samples.length ? Math.floor(bottom * 10) / 10 : -10).toString();
    maxY.value = (samples.length ? Math.ceil(top * 10) / 10 : 10).toString();
    minY.disabled = maxY.disabled = false;
    updatePoints(); fit();
  } catch (error) {
    if (request !== epoch) return;
    release(mesh); mesh = undefined; samples = []; shown = [];
    minY.disabled = maxY.disabled = true;
    status.textContent = error instanceof Error ? error.message : String(error); render();
  }
}

folder.addEventListener('change', async () => {
  const request = ++epoch;
  release(mesh); mesh = undefined; release(dots); dots = undefined; samples = []; shown = [];
  rooms = []; files = new Map(); roomSelect.disabled = true; minY.disabled = maxY.disabled = true;
  roomSelect.replaceChildren(new Option('No capture loaded', ''));
  detail.textContent = 'Click a point to inspect its reading.'; status.textContent = 'Reading local folder…'; render();
  try {
    for (const file of folder.files ?? []) {
      const relative = file.webkitRelativePath;
      files.set(relative.slice(relative.indexOf('/') + 1), file);
    }
    const manifest = await readJSON(files.get('manifest.json')) as { format?: string; rooms?: Room[]; magneticFiles?: string[] };
    if (request !== epoch) return;
    if (!manifest?.format?.startsWith('house-capture/') || !Array.isArray(manifest.rooms)) throw new Error('Choose a room/session folder directly containing manifest.json.');
    const magneticFiles = Array.isArray(manifest.magneticFiles) ? manifest.magneticFiles : [];
    rooms = manifest.rooms.filter(r => r && Number.isInteger(r.index) && r.index >= 0 && typeof r.name === 'string' && magneticFiles.includes(`magnetic/room-${r.index}.json`));
    if (!rooms.length) throw new Error('No magnetic recording in this capture. Enable magnetic recording in the modified iPhone app and scan again.');
    roomSelect.replaceChildren(...rooms.map(r => new Option(r.name, String(r.index))));
    roomSelect.disabled = false;
    await loadRoom();
  } catch (error) { if (request === epoch) status.textContent = error instanceof Error ? error.message : String(error); }
});

roomSelect.addEventListener('change', loadRoom);
calibrated.addEventListener('change', updatePoints);
minY.addEventListener('input', updatePoints); maxY.addEventListener('input', updatePoints);
document.querySelector('#fit')!.addEventListener('click', fit);
const ray = new THREE.Raycaster(); ray.params.Points.threshold = 0.08;
let pointerStart = { x: 0, y: 0 };
canvas.addEventListener('pointerdown', event => { pointerStart = { x: event.clientX, y: event.clientY }; });
canvas.addEventListener('pointerup', event => {
  if (!dots || Math.hypot(event.clientX - pointerStart.x, event.clientY - pointerStart.y) > 5) return;
  const rect = canvas.getBoundingClientRect();
  ray.setFromCamera(new THREE.Vector2((event.clientX - rect.left) / rect.width * 2 - 1, -(event.clientY - rect.top) / rect.height * 2 + 1), camera);
  const hit = ray.intersectObject(dots)[0];
  const s = hit?.index === undefined ? undefined : shown[hit.index];
  if (!s) return;
  const accuracy: Record<number, string> = { [-1]: 'uncalibrated', 0: 'low', 1: 'medium', 2: 'high' };
  detail.textContent = `${s.magnitudeMicrotesla.toFixed(2)} µT\nPosition: ${s.position.map(n => n.toFixed(2)).join(', ')} m\nDevice vector: ${s.fieldDeviceMicrotesla.map(n => n.toFixed(2)).join(', ')} µT\nCalibration: ${accuracy[s.calibrationAccuracy]}\nPose / sensor timing difference: ${(s.poseDeltaSeconds * 1000).toFixed(1)} ms\nTime since boot: ${s.timestamp.toFixed(3)} s`;
});
render();
