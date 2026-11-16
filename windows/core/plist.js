'use strict';
// Minimal readers for Apple property lists (binary and XML). Read-only.

function parseBinary(buf) {
  if (buf.length < 40 || buf.toString('latin1', 0, 6) !== 'bplist') return null;
  const t = buf.length - 32;
  const offSize = buf[t + 6], refSize = buf[t + 7];
  const count = Number(buf.readBigUInt64BE(t + 8)), top = Number(buf.readBigUInt64BE(t + 16)), table = Number(buf.readBigUInt64BE(t + 24));
  const uint = (pos, n) => { let v = 0; for (let i = 0; i < n; i++) v = v * 256 + buf[pos + i]; return v; };
  const cache = new Map();
  const read = (index) => {
    if (cache.has(index)) return cache.get(index);
    if (index >= count) return null;
    let pos = uint(table + index * offSize, offSize);
    const marker = buf[pos++], hi = marker >> 4;
    let lo = marker & 15;
    const length = () => { if (lo !== 15) return lo; const n = 1 << (buf[pos++] & 15); const v = uint(pos, n); pos += n; return v; };
    let value;
    switch (hi) {
      case 0: value = lo === 9 ? true : lo === 8 ? false : null; break;
      case 1: { const n = 1 << lo; value = n === 8 ? Number(buf.readBigInt64BE(pos)) : uint(pos, n); break; }
      case 2: value = lo === 2 ? buf.readFloatBE(pos) : buf.readDoubleBE(pos); break;
      case 3: value = new Date((buf.readDoubleBE(pos) + 978307200) * 1000); break;
      case 4: { const n = length(); value = Buffer.from(buf.subarray(pos, pos + n)); break; }
      case 5: { const n = length(); value = buf.toString('latin1', pos, pos + n); break; }
      case 6: { const n = length(); value = Buffer.from(buf.subarray(pos, pos + n * 2)).swap16().toString('utf16le'); break; }
      case 8: value = { UID: uint(pos, lo + 1) }; break;
      case 10: { const n = length(); value = []; cache.set(index, value); for (let i = 0; i < n; i++) value.push(read(uint(pos + i * refSize, refSize))); break; }
      case 13: {
        const n = length(); value = {}; cache.set(index, value);
        for (let i = 0; i < n; i++) value[read(uint(pos + i * refSize, refSize))] = read(uint(pos + (n + i) * refSize, refSize));
        break;
      }
      default: value = null;
    }
    cache.set(index, value);
    return value;
  };
  try { return read(top); } catch { return null; }
}

/// Top-level keys of a simple XML property list (strings, dates, booleans, data).
function parseXML(text) {
  const out = {};
  const re = /<key>([^<]*)<\/key>\s*(?:<string>([^<]*)<\/string>|<date>([^<]*)<\/date>|<(true|false)\/>|<data>([^<]*)<\/data>|<integer>([^<]*)<\/integer>)/g;
  let m;
  while ((m = re.exec(text))) {
    if (m[2] != null) out[m[1]] = m[2].replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>');
    else if (m[3] != null) out[m[1]] = new Date(m[3]);
    else if (m[4] != null) out[m[1]] = m[4] === 'true';
    else if (m[5] != null) out[m[1]] = Buffer.from(m[5].replace(/\s+/g, ''), 'base64');
    else if (m[6] != null) out[m[1]] = Number(m[6]);
  }
  return out;
}

function parse(buf) {
  if (!buf || !buf.length) return null;
  return buf.toString('latin1', 0, 6) === 'bplist' ? parseBinary(buf) : parseXML(buf.toString('utf8'));
}

module.exports = { parse, parseBinary, parseXML };
