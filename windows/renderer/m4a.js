'use strict';
// Writes AAC audio frames into an MPEG-4 audio file (.m4a, or .m4r for an iPhone ringtone): one track, one chunk.
// The frames come from the browser's own AAC encoder (WebCodecs), so making a ringtone needs nothing downloaded.
function muxM4A(frames, config, sampleRate, channels) {
  const u32 = (v) => [(v >>> 24) & 255, (v >>> 16) & 255, (v >>> 8) & 255, v & 255];
  const u16 = (v) => [(v >>> 8) & 255, v & 255];
  const str = (s) => [...s].map((c) => c.charCodeAt(0));
  const box = (type, ...parts) => {
    const body = parts.flat(Infinity);
    return [...u32(body.length + 8), ...str(type), ...body];
  };
  const full = (type, version, flags, ...parts) => box(type, version, (flags >> 16) & 255, (flags >> 8) & 255, flags & 255, ...parts);
  // An MPEG-4 descriptor with a four-byte length, as most writers use.
  const desc = (tag, ...parts) => { const body = parts.flat(Infinity); return [tag, 0x80, 0x80, 0x80, body.length & 127, ...body]; };
  if (!config || !config.length) {
    // AAC-LC's two-byte AudioSpecificConfig when the encoder did not hand one over.
    const rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];
    const i = Math.max(0, rates.indexOf(sampleRate));
    config = [(2 << 3) | (i >> 1), ((i & 1) << 7) | (channels << 3)];
  }
  const total = frames.length * 1024;
  const sizes = frames.map((f) => f.length);
  const maxFrame = Math.max(0, ...sizes);
  const matrix = [...u32(0x10000), ...u32(0), ...u32(0), ...u32(0), ...u32(0x10000), ...u32(0), ...u32(0), ...u32(0), ...u32(0x40000000)];
  const moov = (offset) => box('moov',
    full('mvhd', 0, 0, u32(0), u32(0), u32(sampleRate), u32(total), u32(0x10000), u16(0x100), u16(0), u32(0), u32(0), matrix, new Array(24).fill(0), u32(2)),
    box('trak',
      full('tkhd', 0, 7, u32(0), u32(0), u32(1), u32(0), u32(total), u32(0), u32(0), u16(0), u16(0), u16(0x100), u16(0), matrix, u32(0), u32(0)),
      box('mdia',
        full('mdhd', 0, 0, u32(0), u32(0), u32(sampleRate), u32(total), u16(0x55c4), u16(0)),
        full('hdlr', 0, 0, u32(0), str('soun'), u32(0), u32(0), u32(0), str('SoundHandler'), 0),
        box('minf',
          full('smhd', 0, 0, u16(0), u16(0)),
          box('dinf', full('dref', 0, 0, u32(1), full('url ', 0, 1))),
          box('stbl',
            full('stsd', 0, 0, u32(1),
              box('mp4a', new Array(6).fill(0), u16(1), u16(0), u16(0), u32(0), u16(channels), u16(16), u16(0), u16(0), u32(sampleRate * 65536),
                full('esds', 0, 0, desc(3, u16(0), 0,
                  desc(4, 0x40, 0x15, (maxFrame >> 16) & 255, (maxFrame >> 8) & 255, maxFrame & 255, u32(0), u32(0), desc(5, [...config])),
                  desc(6, 2))))),
            full('stts', 0, 0, u32(1), u32(frames.length), u32(1024)),
            full('stsc', 0, 0, u32(1), u32(1), u32(frames.length), u32(1)),
            full('stsz', 0, 0, u32(0), u32(frames.length), sizes.map(u32)),
            full('stco', 0, 0, u32(1), u32(offset)))))));
  const ftyp = box('ftyp', str('M4A '), u32(0), str('M4A '), str('mp42'), str('isom'));
  const head = moov(0).length;
  const offset = ftyp.length + head + 8;
  const media = sizes.reduce((a, b) => a + b, 0);
  const out = new Uint8Array(ftyp.length + head + 8 + media);
  out.set(ftyp, 0);
  out.set(moov(offset), ftyp.length);
  out.set([...u32(media + 8), ...str('mdat')], ftyp.length + head);
  let at = offset;
  for (const f of frames) { out.set(f, at); at += f.length; }
  return out;
}

/// Cuts `seconds` from `start` out of any sound or video file the browser can play and encodes it as AAC. Returns an .m4r file's bytes.
async function makeRingtoneBytes(arrayBuffer, start, seconds) {
  const rate = 44100, decoded = await new AudioContext().decodeAudioData(arrayBuffer);
  const length = Math.max(1, Math.round(Math.min(seconds, Math.max(0, decoded.duration - start)) * rate));
  const ctx = new OfflineAudioContext(2, length, rate);
  const src = ctx.createBufferSource();
  src.buffer = decoded; src.connect(ctx.destination); src.start(0, start, length / rate);
  const pcm = await ctx.startRendering();
  const frames = [];
  let config = null, failed = null;
  const enc = new AudioEncoder({
    output: (chunk, meta) => {
      const b = new Uint8Array(chunk.byteLength); chunk.copyTo(b); frames.push(b);
      if (meta && meta.decoderConfig && meta.decoderConfig.description) config = new Uint8Array(meta.decoderConfig.description);
    },
    error: (e) => { failed = e; },
  });
  enc.configure({ codec: 'mp4a.40.2', sampleRate: rate, numberOfChannels: 2, bitrate: 160000 });
  for (let i = 0; i < pcm.length; i += 4096) {
    const n = Math.min(4096, pcm.length - i), planar = new Float32Array(n * 2);
    planar.set(pcm.getChannelData(0).subarray(i, i + n), 0); planar.set(pcm.getChannelData(1).subarray(i, i + n), n);
    enc.encode(new AudioData({ format: 'f32-planar', sampleRate: rate, numberOfFrames: n, numberOfChannels: 2, timestamp: Math.round((i / rate) * 1e6), data: planar }));
  }
  await enc.flush(); enc.close();
  if (failed || !frames.length) throw failed || new Error('nothing encoded');
  return muxM4A(frames, config, rate, 2);
}
if (typeof module !== 'undefined') module.exports = { muxM4A };
