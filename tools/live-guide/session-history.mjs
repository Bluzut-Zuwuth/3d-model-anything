import { mkdirSync, openSync, writeSync, fsyncSync, closeSync, createReadStream, createWriteStream } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { createInterface } from 'node:readline';
import { once } from 'node:events';
import { makeZip } from './zip.mjs';

const point = s => ({ elapsedSeconds: s.elapsedSeconds, room: s.room, position: s.position,
  magnitudeMicrotesla: s.magnitudeMicrotesla, calibrationAccuracy: s.calibrationAccuracy });

export class SessionHistory {
  constructor(directory, now = Date.now()) {
    this.startedAt = now;
    this.id = new Date(now).toISOString().replace(/[:.]/g, '-') + '-' + randomBytes(3).toString('hex');
    this.directory = path.join(directory, this.id);
    mkdirSync(this.directory, { recursive: true });
    this.journal = path.join(this.directory, 'events.ndjson');
    this.fd = openSync(this.journal, 'wx');
    this.counts = { sample: 0, lidar: 0, status: 0, question: 0, reply: 0, error: 0 };
    this.bins = [];
    this.width = 15;
    this.turns = [];
    this.total = 0; this.sum = 0; this.min = null; this.max = null;
    this.lastElapsed = 0;
    this.event('start', { scope: 'Phone-only environmental data collection; no wearable trackers required.' }, now);
  }
  event(type, data, now = Date.now()) {
    if (this.fd == null) throw new Error('Session already closed');
    const elapsedSeconds = Math.max(0, (now - this.startedAt) / 1000);
    const event = { type, receivedAt: now, elapsedSeconds, data };
    writeSync(this.fd, JSON.stringify(event) + '\n');
    if (type in this.counts) this.counts[type]++;
    this.lastElapsed = elapsedSeconds;
    if (type === 'sample') this.addSample({ ...data, elapsedSeconds });
    if (type === 'question' || type === 'reply') this.turns.push({ elapsedSeconds, role: type === 'question' ? 'user' : 'guide', text: data.text });
    return event;
  }
  addSample(s) {
    const p = point(s);
    this.total++; this.sum += p.magnitudeMicrotesla;
    if (!this.min || p.magnitudeMicrotesla < this.min.magnitudeMicrotesla) this.min = p;
    if (!this.max || p.magnitudeMicrotesla > this.max.magnitudeMicrotesla) this.max = p;
    let bin = this.bins.at(-1);
    const start = Math.floor(s.elapsedSeconds / this.width) * this.width;
    if (!bin || bin.startSeconds !== start) {
      bin = { startSeconds: start, endSeconds: start + this.width, count: 0, sum: 0, min: p, max: p, last: p, calibrationCounts: {} };
      this.bins.push(bin);
    }
    bin.count++; bin.sum += p.magnitudeMicrotesla; bin.last = p;
    if (p.magnitudeMicrotesla < bin.min.magnitudeMicrotesla) bin.min = p;
    if (p.magnitudeMicrotesla > bin.max.magnitudeMicrotesla) bin.max = p;
    const accuracy = String(s.calibrationAccuracy);
    bin.calibrationCounts[accuracy] = (bin.calibrationCounts[accuracy] || 0) + 1;
    // Keep the entire session represented while bounding the per-question prompt.
    if (this.bins.length > 96) {
      this.width *= 2;
      const merged = [];
      for (const b of this.bins) {
        const startSeconds = Math.floor(b.startSeconds / this.width) * this.width;
        const last = merged.at(-1);
        if (last?.startSeconds === startSeconds) {
          last.count += b.count; last.sum += b.sum; last.last = b.last;
          if (b.min.magnitudeMicrotesla < last.min.magnitudeMicrotesla) last.min = b.min;
          if (b.max.magnitudeMicrotesla > last.max.magnitudeMicrotesla) last.max = b.max;
          for (const [key, count] of Object.entries(b.calibrationCounts)) last.calibrationCounts[key] = (last.calibrationCounts[key] || 0) + count;
        } else merged.push({ ...b, startSeconds, endSeconds: startSeconds + this.width, calibrationCounts: { ...b.calibrationCounts } });
      }
      this.bins = merged;
    }
  }
  summary() {
    return {
      sessionID: this.id, startedAt: new Date(this.startedAt).toISOString(), durationSeconds: this.lastElapsed,
      counts: { ...this.counts }, magnetic: { sampleCount: this.total, units: 'microtesla',
        mean: this.total ? this.sum / this.total : null, min: this.min, max: this.max },
      timeBinWidthSeconds: this.width,
      timeline: this.bins.map(({ sum, ...b }) => ({ ...b, meanMicrotesla: sum / b.count })),
      conversation: this.turns,
      interpretation: 'All accepted magnetic samples contribute to this session summary, including old readings. Timeline bins contain exact extrema and their original positions/times, not every raw reading. Complete events are in the PC export. Coordinates are ARKit world meters; Y is not floor height. No automatic source identification or tracker-interference conclusion.'
    };
  }
  guideContext() {
    const summary = this.summary();
    // Recent turns in full; earlier remarks stay available as a compact timeline.
    summary.conversation = this.turns.slice(-24);
    summary.earlierConversation = this.turns.slice(0, -24).map(t => ({ ...t, text: t.text.slice(0, 240) })).slice(-120);
    summary.conversationTruncated = this.turns.length > 144;
    return summary;
  }
  async finish(reason, now = Date.now()) {
    if (this.finished) return this.finished;
    this.event('end', { reason }, now);
    fsyncSync(this.fd); closeSync(this.fd); this.fd = null;
    this.finished = this.export(reason, now);
    return this.finished;
  }
  async export(reason, now) {
    const summary = { ...this.summary(), endedAt: new Date(now).toISOString(), reason };
    const json = path.join(this.directory, 'session.json');
    const out = createWriteStream(json);
    // Attach a listener before writes so errors cannot become unhandled events.
    let failure;
    out.on('error', e => { failure = e; });
    const put = async text => { if (failure) throw failure; if (!out.write(text)) await once(out, 'drain'); };
    try {
      await put('{"format":"live-survey-session/1","summary":' + JSON.stringify(summary) + ',"events":[\n');
      const lines = createInterface({ input: createReadStream(this.journal), crlfDelay: Infinity });
      let first = true;
      for await (const line of lines) if (line) { await put((first ? '' : ',\n') + line); first = false; }
      await put('\n]}\n');
      const done = once(out, 'finish'); out.end(); await done;
    } catch (error) { out.destroy(); throw error; }
    const f = x => x ? `${x.magnitudeMicrotesla.toFixed(2)} µT at ${x.elapsedSeconds.toFixed(1)} s, position [${x.position.map(n => n.toFixed(3)).join(', ')}]` : 'No readings';
    const markdown = `# Live room-data survey\n\nSession: ${this.id}\nStarted: ${summary.startedAt}\nEnded: ${summary.endedAt}\nReason: ${reason}\n\nMagnetic samples: ${this.total}\nLiDAR summaries: ${this.counts.lidar}\nMinimum: ${f(this.min)}\nMaximum: ${f(this.max)}\n\nThis was phone-only environmental data collection. No Rebocap trackers or VR equipment were required to be worn or activated.\n\nAttach the ZIP or session.json to your chat. The JSON includes the complete accepted event history, raw magnetic samples with timestamps/positions, LiDAR summaries, status and guide conversation. It does not contain photos, full mesh, full depth buffers, passwords, pairing code, API keys or prior private context.\n\nARKit Y is not height above floor. Magnitude alone cannot identify a source or establish tracker interference. Each connection has a separate coordinate scope.\n`;
    await writeFile(path.join(this.directory, 'summary.md'), markdown);
    const zip = path.join(this.directory, 'survey-for-chat.zip');
    await makeZip(zip, [json, path.join(this.directory, 'summary.md')]);
    return { directory: this.directory, json, zip, summary };
  }
}
