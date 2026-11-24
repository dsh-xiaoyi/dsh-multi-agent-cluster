// dsh-zstd-extract.js
// DSH session log is a concatenation of independent zstd frames (one per append).
// One-shot and streaming APIs both stop at the first frame, so split on the frame
// magic (28 B5 2F FD) and decompress each frame separately, then concatenate.
//
// [INCREMENTAL-20261118] optional --from <byteOffset> resumes from a previous run:
//   only frames whose start offset is >= <byteOffset> are decompressed. The trailing
//   mid-append frame is NOT consumed (we break on the first bad frame), and `endOffset`
//   reports the start offset of the last frame that decompressed cleanly, so the caller
//   can pass it back as --from next time. Without --from the behaviour is unchanged.
//
// Usage:
//   node dsh-zstd-extract.js <input.zstd> <output.jsonl>
//   node dsh-zstd-extract.js <input.zstd> <output.jsonl> --from <byteOffset>
const fs = require('fs');
const zlib = require('zlib');

const src = process.argv[2];
const dst = process.argv[3];
if (!src || !dst) {
  console.error('usage: node dsh-zstd-extract.js <input.zstd> <output.jsonl> [--from <byteOffset>]');
  process.exit(2);
}

let fromOffset = 0;
const fromIdx = process.argv.indexOf('--from');
if (fromIdx >= 0 && fromIdx + 1 < process.argv.length) {
  fromOffset = Math.max(0, parseInt(process.argv[fromIdx + 1], 10) || 0);
}
const incremental = fromOffset > 0;

const buf = fs.readFileSync(src);
const offs = [];
for (let i = 0; i < buf.length - 3; i++) {
  if (buf[i] === 0x28 && buf[i + 1] === 0xB5 && buf[i + 2] === 0x2F && buf[i + 3] === 0xFD) offs.push(i);
}

const parts = [];
let okFrames = 0, badFrames = 0;
let lastOkStart = -1;
let processed = 0;

for (let i = 0; i < offs.length; i++) {
  const s = offs[i];
  if (s < fromOffset) continue;
  processed++;
  const e = (i + 1 < offs.length) ? offs[i + 1] : buf.length;
  try {
    parts.push(zlib.zstdDecompressSync(buf.subarray(s, e)));
    okFrames++;
    lastOkStart = s;
  } catch (err) {
    badFrames++;
    // Trailing mid-append frame, or stray magic. In incremental mode stop here so
    // endOffset never advances past an un-decodable frame (resume point stays safe).
    // In full mode keep going exactly like the previous implementation did.
    if (incremental) break;
  }
}

const all = Buffer.concat(parts);
fs.writeFileSync(dst, all);
console.log(JSON.stringify({
  inputBytes: buf.length,
  fromOffset,
  endOffset: lastOkStart,
  frames: offs.length,
  processedFrames: processed,
  okFrames,
  badFrames,
  outputBytes: all.length,
  outputPath: dst
}));
