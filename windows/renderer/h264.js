'use strict';
// Splits an H.264 byte stream (Annex B: NAL units after 00 00 01 start codes) into whole frames, as an Android phone's
// `screenrecord --output-format=h264` sends them. Used by the screen view (with the browser's own decoder) and by the tests.
class AnnexB {
  constructor() { this.buffer = new Uint8Array(0); this.pending = []; this.hasSlice = false; this.sps = null; this.pps = null; }

  static starts(b) {
    const out = [];
    for (let i = 0; i + 2 < b.length; i++) {
      if (b[i] === 0 && b[i + 1] === 0 && b[i + 2] === 1) { out.push({ at: i > 0 && b[i - 1] === 0 ? i - 1 : i, payload: i + 3 }); i += 2; }
    }
    return out;
  }
  static trim(n) { let end = n.length; while (end > 0 && n[end - 1] === 0) end--; return n.subarray(0, end); }

  /// Feeds bytes as they arrive; returns the frames now complete ({ nals, isKey, data } with data in Annex B form).
  append(bytes) {
    const joined = new Uint8Array(this.buffer.length + bytes.length);
    joined.set(this.buffer); joined.set(bytes, this.buffer.length);
    const s = AnnexB.starts(joined), out = [];
    if (s.length < 2) { this.buffer = joined; return out; }
    for (let k = 0; k < s.length - 1; k++) out.push(...this.take(AnnexB.trim(joined.slice(s[k].payload, s[k + 1].at))));
    this.buffer = joined.slice(s[s.length - 1].at);
    return out;
  }

  finish() {
    const out = [], s = AnnexB.starts(this.buffer);
    if (s.length) out.push(...this.take(AnnexB.trim(this.buffer.slice(s[0].payload))));
    this.buffer = new Uint8Array(0);
    if (this.hasSlice) out.push(this.frame());
    this.pending = []; this.hasSlice = false;
    return out;
  }

  frame() {
    const nals = this.pending;
    this.pending = []; this.hasSlice = false;
    let size = 0;
    for (const n of nals) size += n.length + 4;
    const data = new Uint8Array(size);
    let at = 0;
    for (const n of nals) { data.set([0, 0, 0, 1], at); data.set(n, at + 4); at += n.length + 4; }
    return { nals, isKey: nals.some((n) => (n[0] & 0x1f) === 5), data };
  }

  take(nal) {
    if (!nal.length) return [];
    const out = [], type = nal[0] & 0x1f;
    if (type === 9) { if (this.hasSlice) out.push(this.frame()); return out; }
    if (type === 6 || type === 7 || type === 8) {
      if (this.hasSlice) out.push(this.frame());
      if (type === 7) this.sps = nal; else if (type === 8) this.pps = nal;
      this.pending.push(nal);
    } else if (type === 1 || type === 5) {
      if (nal.length > 1 && (nal[1] & 0x80) && this.hasSlice) out.push(this.frame());
      this.pending.push(nal); this.hasSlice = true;
    } else this.pending.push(nal);
    return out;
  }

  /// The codec name a decoder is configured with, from the sequence parameter set: "avc1.PPCCLL".
  static codec(sps) {
    if (!sps || sps.length < 4) return 'avc1.42E01E';
    const h = (v) => v.toString(16).toUpperCase().padStart(2, '0');
    return `avc1.${h(sps[1])}${h(sps[2])}${h(sps[3])}`;
  }
}
if (typeof module !== 'undefined') module.exports = { AnnexB };
