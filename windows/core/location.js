'use strict';
// Removes where a photo or video was taken, in place: the GPS block of a photo's EXIF data (JPEG, HEIC/HEIF,
// DNG/TIFF) and the location entries of a video's QuickTime metadata (MOV/MP4). Nothing is re-encoded and the file
// keeps its exact size. Same logic as the Mac's LocationScrubber.swift; both are checked against Tests/golden/location.
const fs = require('node:fs');
const path = require('node:path');

function open(file) {
  const fd = fs.openSync(file, 'r+');
  const size = fs.fstatSync(fd).size;
  return {
    size,
    read(offset, count) {
      if (!(count > 0) || offset + count > size) return null;
      const b = Buffer.alloc(count);
      return fs.readSync(fd, b, 0, count, offset) === count ? b : null;
    },
    write(offset, buf) { try { fs.writeSync(fd, buf, 0, buf.length, offset); return true; } catch { return false; } },
    close() { fs.closeSync(fd); },
  };
}

// MARK: EXIF (TIFF structure)

/// Empties the GPS directory of a TIFF/EXIF block (a Buffer, changed in place). True when there was one.
function wipeGPS(t) {
  if (t.length < 8) return false;
  let little;
  if (t[0] === 0x49 && t[1] === 0x49) little = true; else if (t[0] === 0x4d && t[1] === 0x4d) little = false; else return false;
  const u16 = (o) => (o >= 0 && o + 2 <= t.length ? (little ? t.readUInt16LE(o) : t.readUInt16BE(o)) : null);
  const u32 = (o) => (o >= 0 && o + 4 <= t.length ? (little ? t.readUInt32LE(o) : t.readUInt32BE(o)) : null);
  const zero = (o, len) => { if (o >= 0 && len > 0 && o + len <= t.length) t.fill(0, o, o + len); };
  const ifd0 = u32(4), n0 = ifd0 == null ? null : u16(ifd0);
  if (u16(2) !== 42 || n0 == null || n0 >= 1000) return false;
  let g = null;
  for (let i = 0; i < n0; i++) if (u16(ifd0 + 2 + 12 * i) === 0x8825) g = u32(ifd0 + 2 + 12 * i + 8);
  const n = g == null ? null : u16(g);
  if (!n || n >= 1000 || g + 2 + 12 * n > t.length) return false;
  const typeSize = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8];
  for (let i = 0; i < n; i++) {
    const e = g + 2 + 12 * i, type = u16(e + 2), count = u32(e + 4);
    if (type == null || count == null) continue;
    const len = (type < typeSize.length ? typeSize[type] : 1) * count;
    if (len > 4) { const off = u32(e + 8); if (off != null) zero(off, len); }
  }
  zero(g, 2 + 12 * n);
  return true;
}

function tiffFile(f) {
  const t = f.read(0, Math.min(f.size, 4000000));
  return !!t && wipeGPS(t) && f.write(0, t);
}

// MARK: JPEG

function jpeg(f) {
  const soi = f.read(0, 2);
  if (!soi || soi[0] !== 0xff || soi[1] !== 0xd8) return false;
  let o = 2, changed = false;
  while (o + 4 <= f.size) {
    const m = f.read(o, 4);
    if (!m || m[0] !== 0xff) break;
    const marker = m[1];
    if (marker === 0xff) { o += 1; continue; }
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) { o += 2; continue; }
    if (marker === 0xda || marker === 0xd9) break;
    const len = m.readUInt16BE(2);
    if (len < 2) break;
    if (marker === 0xe1 && len > 8) {
      const seg = f.read(o + 4, len - 2);
      if (seg && seg.subarray(0, 6).equals(Buffer.from('Exif\0\0', 'latin1'))) {
        const t = Buffer.from(seg.subarray(6));
        if (wipeGPS(t) && f.write(o + 4 + 6, t)) changed = true;
      }
    }
    o += 2 + len;
  }
  return changed;
}

// MARK: HEIF (ISO base media boxes)

const be = (d, o, n) => { if (!(n > 0) || o < 0 || o + n > d.length) return 0; let v = 0; for (let i = 0; i < n; i++) v = v * 256 + d[o + i]; return v; };
const fourCC = (d, o) => (o >= 0 && o + 4 <= d.length ? d.toString('latin1', o, o + 4) : '');

function box(f, o) {
  const h = f.read(o, 8);
  if (!h) return null;
  let size = h.readUInt32BE(0), header = 8;
  if (size === 1) { const l = f.read(o + 8, 8); if (!l) return null; size = Number(l.readBigUInt64BE(0)); header = 16; }
  else if (size === 0) size = f.size - o;
  if (size < header || o + size > f.size) return null;
  return { size, type: fourCC(h, 4), header };
}

function children(d, start, end) {
  const out = [];
  let o = start;
  while (o + 8 <= end) {
    let size = be(d, o, 4), header = 8;
    if (size === 1) { if (o + 16 > end) break; size = be(d, o + 8, 8); header = 16; }
    else if (size === 0) size = end - o;
    if (size < header || o + size > end) break;
    out.push({ offset: o, size, type: fourCC(d, o + 4), header });
    o += size;
  }
  return out;
}

const isTIFF = (d, o) => o >= 0 && o + 4 <= d.length
  && ((d[o] === 0x49 && d[o + 1] === 0x49 && d[o + 2] === 0x2a && d[o + 3] === 0) || (d[o] === 0x4d && d[o + 1] === 0x4d && d[o + 2] === 0 && d[o + 3] === 0x2a));

function heif(f) {
  for (let o = 0, b; o + 8 <= f.size && (b = box(f, o)); o += b.size) {
    if (b.type !== 'meta') continue;
    const meta = b.size <= 16000000 ? f.read(o, b.size) : null;
    return !!meta && heifExif(f, meta, o, b.header);
  }
  return false;
}

/// Finds the 'Exif' item through iinf (its ID) and iloc (where its bytes are), then wipes its GPS block.
function heifExif(f, meta, metaStart, header) {
  const kids = children(meta, header + 4, meta.length);
  const exifIDs = new Set();
  const iinf = kids.find((k) => k.type === 'iinf');
  if (iinf) {
    const p = iinf.offset + iinf.header, version = be(meta, p, 1);
    for (const e of children(meta, p + 4 + (version === 0 ? 2 : 4), iinf.offset + iinf.size)) {
      if (e.type !== 'infe') continue;
      const q = e.offset + e.header, v = be(meta, q, 1);
      if (v < 2) continue;
      const idLen = v === 2 ? 2 : 4;
      if (fourCC(meta, q + 4 + idLen + 2) === 'Exif') exifIDs.add(be(meta, q + 4, idLen));
    }
  }
  const iloc = kids.find((k) => k.type === 'iloc');
  if (!exifIDs.size || !iloc) return false;
  const idatBox = kids.find((k) => k.type === 'idat');
  const idat = idatBox ? metaStart + idatBox.offset + idatBox.header : null;
  let p = iloc.offset + iloc.header;
  const version = be(meta, p, 1); p += 4;
  const offsetSize = be(meta, p, 1) >> 4, lengthSize = be(meta, p, 1) & 15;
  const baseSize = be(meta, p + 1, 1) >> 4, indexSize = version >= 1 ? be(meta, p + 1, 1) & 15 : 0;
  p += 2;
  let count;
  if (version < 2) { count = be(meta, p, 2); p += 2; } else { count = be(meta, p, 4); p += 4; }
  let changed = false;
  for (let i = 0; i < count && p < meta.length; i++) {
    let id;
    if (version < 2) { id = be(meta, p, 2); p += 2; } else { id = be(meta, p, 4); p += 4; }
    let method = 0;
    if (version >= 1) { method = be(meta, p, 2) & 15; p += 2; }
    p += 2;
    const base = be(meta, p, baseSize); p += baseSize;
    const extents = be(meta, p, 2); p += 2;
    let firstOffset = 0, firstLength = 0;
    for (let x = 0; x < extents; x++) {
      p += indexSize;
      const off = be(meta, p, offsetSize); p += offsetSize;
      const len = be(meta, p, lengthSize); p += lengthSize;
      if (x === 0) { firstOffset = off; firstLength = len; }
    }
    if (!exifIDs.has(id) || firstLength <= 8) continue;
    let start;
    if (method === 0) start = base + firstOffset; else if (method === 1 && idat != null) start = idat + base + firstOffset; else continue;
    const payload = f.read(start, Math.min(firstLength, 4000000));
    if (!payload) continue;
    let tiffAt = 4 + be(payload, 0, 4);
    if (!isTIFF(payload, tiffAt)) { for (let k = 0; k < Math.min(64, payload.length - 4); k++) if (isTIFF(payload, k)) { tiffAt = k; break; } }
    if (!isTIFF(payload, tiffAt)) continue;
    const t = Buffer.from(payload.subarray(tiffAt));
    if (wipeGPS(t) && f.write(start + tiffAt, t)) changed = true;
  }
  return changed;
}

// MARK: QuickTime / MP4

function quickTime(f) {
  let changed = false;
  for (let o = 0, b; o + 8 <= f.size && (b = box(f, o)); o += b.size) {
    if (b.type !== 'moov' || b.size > 256000000) continue;
    const moov = f.read(o, b.size);
    if (moov && patchAtoms(moov, b.header, moov.length) && f.write(o, moov)) changed = true;
  }
  return changed;
}

const plausibleAtom = (d, o, end) => {
  const size = be(d, o, 4);
  if (size < 8 || o + size > end) return false;
  for (let i = o + 4; i < o + 8; i++) if (!((d[i] >= 0x20 && d[i] <= 0x7e) || d[i] === 0xa9)) return false;
  return true;
};

/// Location atoms (©xyz, loci) become 'free' space with their contents zeroed; metadata keys about location are
/// renamed and their values zeroed. Everything keeps its size and place.
function patchAtoms(d, start, end) {
  let changed = false;
  const kids = children(d, start, end);
  const locationKeys = new Set();
  for (const k of kids) if (k.type === 'keys') for (const n of renameLocationKeys(d, k.offset + k.header, k.offset + k.size)) locationKeys.add(n);
  for (const k of kids) {
    switch (k.type) {
      case '©xyz': case 'loci':
        d.write('free', k.offset + 4, 'latin1');
        d.fill(0, k.offset + k.header, k.offset + k.size);
        changed = true;
        break;
      case 'ilst':
        if (!locationKeys.size) break;
        for (const item of children(d, k.offset + k.header, k.offset + k.size)) {
          if (!locationKeys.has(be(d, item.offset + 4, 4))) continue;
          for (const v of children(d, item.offset + item.header, item.offset + item.size)) {
            if (v.type !== 'data' || v.size <= v.header + 8) continue;
            d.fill(0, v.offset + v.header + 8, v.offset + v.size);
            changed = true;
          }
        }
        break;
      case 'moov': case 'trak': case 'mdia': case 'minf': case 'udta': case 'edts': case 'dinf':
        if (patchAtoms(d, k.offset + k.header, k.offset + k.size)) changed = true;
        break;
      case 'meta': {
        const inner = k.offset + k.header;
        const iso = !plausibleAtom(d, inner, k.offset + k.size);
        if (patchAtoms(d, inner + (iso ? 4 : 0), k.offset + k.size)) changed = true;
        break;
      }
      default: break;
    }
  }
  return changed || locationKeys.size > 0;
}

function renameLocationKeys(d, start, end) {
  const found = [];
  const count = be(d, start + 4, 4);
  let o = start + 8;
  for (let i = 1; i <= count && o + 8 <= end; i++) {
    const size = be(d, o, 4);
    if (size < 8 || o + size > end) break;
    const at = d.subarray(o + 8, o + size).indexOf('location', 0, 'latin1');
    if (at >= 0) { d.write('redacted', o + 8 + at, 'latin1'); found.push(i); }
    o += size;
  }
  return found;
}

/// True when location data was found and removed.
function scrub(file) {
  const ext = path.extname(file).slice(1).toLowerCase();
  const kind = ['jpg', 'jpeg'].includes(ext) ? jpeg : ['heic', 'heif', 'hif', 'avif'].includes(ext) ? heif
    : ['dng', 'tif', 'tiff'].includes(ext) ? tiffFile : ['mov', 'mp4', 'm4v', '3gp'].includes(ext) ? quickTime : null;
  if (!kind) return false;
  let f;
  try { f = open(file); } catch { return false; }
  try { return kind(f); } catch { return false; } finally { f.close(); }
}

module.exports = { scrub, wipeGPS };
