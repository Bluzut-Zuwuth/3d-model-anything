import { createReadStream, createWriteStream } from 'node:fs';
import { Transform } from 'node:stream';
import { createDeflateRaw } from 'node:zlib';
import { once } from 'node:events';
import path from 'node:path';

const table = Array.from({ length: 256 }, (_, n) => {
  for (let k = 0; k < 8; k++) n = n & 1 ? 0xedb88320 ^ (n >>> 1) : n >>> 1;
  return n >>> 0;
});
export function crc32(data, seed = 0) {
  let crc = seed ^ 0xffffffff;
  for (const byte of data) crc = table[(crc ^ byte) & 255] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}
// Streaming standard ZIP with deflate and data descriptors; no third-party dependencies.
export async function makeZip(destination, files) {
  const out = createWriteStream(destination);
  let failure, offset = 0;
  out.on('error', e => { failure = e; });
  const put = async data => {
    if (failure) throw failure;
    offset += data.length;
    if (offset > 0xffffffff) throw new Error('Export exceeds ZIP32 size limit; session.json remains available');
    if (!out.write(data)) await once(out, 'drain');
  };
  const central = [];
  try {
    for (const file of files) {
      const name = Buffer.from(path.basename(file));
      const start = offset;
      const header = Buffer.alloc(30);
      header.writeUInt32LE(0x04034b50); header.writeUInt16LE(20, 4); header.writeUInt16LE(0x808, 6);
      header.writeUInt16LE(8, 8); header.writeUInt16LE(33, 12); header.writeUInt16LE(name.length, 26);
      await put(header); await put(name);
      let crc = 0, size = 0;
      const meter = new Transform({ transform(chunk, _, callback) { crc = crc32(chunk, crc); size += chunk.length; callback(null, chunk); } });
      const source = createReadStream(file), compressor = createDeflateRaw();
      source.on('error', error => compressor.destroy(error)); meter.on('error', error => compressor.destroy(error));
      const dataStart = offset;
      source.pipe(meter).pipe(compressor);
      for await (const chunk of compressor) await put(chunk);
      const compressed = offset - dataStart;
      if (size > 0xffffffff) throw new Error('File exceeds ZIP32 size limit');
      const descriptor = Buffer.alloc(16);
      descriptor.writeUInt32LE(0x08074b50); descriptor.writeUInt32LE(crc, 4);
      descriptor.writeUInt32LE(compressed, 8); descriptor.writeUInt32LE(size, 12); await put(descriptor);
      const entry = Buffer.alloc(46);
      entry.writeUInt32LE(0x02014b50); entry.writeUInt16LE(20, 4); entry.writeUInt16LE(20, 6);
      entry.writeUInt16LE(0x808, 8); entry.writeUInt16LE(8, 10); entry.writeUInt16LE(33, 14);
      entry.writeUInt32LE(crc, 16); entry.writeUInt32LE(compressed, 20); entry.writeUInt32LE(size, 24);
      entry.writeUInt16LE(name.length, 28); entry.writeUInt32LE(start, 42);
      central.push(Buffer.concat([entry, name]));
    }
    const start = offset;
    for (const entry of central) await put(entry);
    const end = Buffer.alloc(22);
    end.writeUInt32LE(0x06054b50); end.writeUInt16LE(files.length, 8); end.writeUInt16LE(files.length, 10);
    end.writeUInt32LE(offset - start, 12); end.writeUInt32LE(start, 16); await put(end);
    const done = once(out, 'finish'); out.end(); await done;
  } catch (error) { out.destroy(); throw error; }
}
