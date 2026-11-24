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

/// An XML property list: dictionaries, arrays, strings, numbers, dates, data and booleans, nested to any depth.
function parseXML(text) {
  let pos = 0;
  const tag = /<(\/?)([a-zA-Z]+)\s*(\/?)>/g;
  const next = () => {
    tag.lastIndex = pos;
    let m;
    while ((m = tag.exec(text))) {
      pos = tag.lastIndex;
      if (m[2] !== 'plist') return { close: m[1] === '/', name: m[2], empty: m[3] === '/' };
    }
    return null;
  };
  const decode = (s) => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');
  const until = (name) => {
    const end = text.indexOf(`</${name}>`, pos);
    if (end < 0) { pos = text.length; return ''; }
    const body = text.slice(pos, end);
    pos = end + name.length + 3;
    return body;
  };
  const value = (t) => {
    if (t.empty) return { dict: {}, array: [], true: true, false: false, string: '', data: Buffer.alloc(0) }[t.name] ?? null;
    switch (t.name) {
      case 'dict': {
        const o = {};
        for (;;) {
          const k = next();
          if (!k || (k.close && k.name === 'dict')) return o;
          if (k.name !== 'key' || k.close) continue;
          const key = decode(until('key'));
          const v = next();
          if (!v || v.close) return o;
          o[key] = value(v);
        }
      }
      case 'array': {
        const a = [];
        for (;;) {
          const v = next();
          if (!v || (v.close && v.name === 'array')) return a;
          if (!v.close) a.push(value(v));
        }
      }
      case 'string': return decode(until('string'));
      case 'integer': return Number(until('integer').trim());
      case 'real': return Number(until('real').trim());
      case 'date': return new Date(until('date').trim());
      case 'data': return Buffer.from(until('data').replace(/\s+/g, ''), 'base64');
      case 'true': return true;
      case 'false': return false;
      default: return null;
    }
  };
  const first = next();
  return first && !first.close ? value(first) : null;
}

function parse(buf) {
  if (!buf || !buf.length) return null;
  return buf.toString('latin1', 0, 6) === 'bplist' ? parseBinary(buf) : parseXML(buf.toString('utf8'));
}

module.exports = { parse, parseBinary, parseXML };
