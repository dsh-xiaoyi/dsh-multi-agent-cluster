// dsh-zstd-extract.js
// DSH session log is a concatenation of independent zstd frames (one per append).
// One-shot and streaming APIs both stop at the first frame, so split on the frame
// magic (28 B5 2F FD) and decompress each frame separately, then concatenate.
// Usage: node dsh-zstd-extract.js <input.zstd> <output.jsonl>
const fs = require('fs');
const zlib = require('zlib');

const src = process.argv[2];
const dst = process.argv[3];
if (!src || !dst) {
  console.error('usage: node dsh-zstd-extract.js <input.zstd> <output.jsonl>');
  process.exit(2);
}

const buf = fs.readFileSync(src);
const offs = [];
for (let i = 0; i < buf.length - 3; i++) {
  if (buf[i] === 0x28 && buf[i + 1] === 0xB5 && buf[i + 2] === 0x2F && buf[i + 3] === 0xFD) offs.push(i);
}

const parts = [];
let okFrames = 0, badFrames = 0;
for (let i = 0; i < offs.length; i++) {
  const s = offs[i];
  const e = (i + 1 < offs.length) ? offs[i + 1] : buf.length;
  try {
    parts.push(zlib.zstdDecompressSync(buf.subarray(s, e)));
    okFrames++;
  } catch (err) {
    badFrames++; // last frame may be mid-append; also tolerate stray magic bytes
  }
}

const all = Buffer.concat(parts);
fs.writeFileSync(dst, all);
console.log(JSON.stringify({
  inputBytes: buf.length,
  frames: offs.length,
  okFrames,
  badFrames,
  outputBytes: all.length,
  outputPath: dst
}));
