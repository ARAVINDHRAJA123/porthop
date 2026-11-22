'use strict';
// iPhone and iPad over USB, through the libimobiledevice tools.
const fs = require('node:fs');
const path = require('node:path');
const { run, fileSize } = require('./shell');

const base = (d) => (d.isNetwork ? ['-u', d.udid, '-n'] : ['-u', d.udid]);
const container = (app) => (app ? ['--documents', app] : []);
const strip = (p) => (p.startsWith('/') ? p.slice(1) : p);

/// Quotes one argument for afcclient's own command reader. Returns null for names it cannot represent.
function quote(s) {
  if (/[\n\r\0]/.test(s)) return null;
  return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

async function findDevices(tools, { wifi = false } = {}) {
  if (!tools.hasApple) return [];
  const all = async (flag) => {
    const r = await run(tools.ideviceId, [flag], { timeout: 8 });
    if (!r.ok) return [];
    return r.output.split(/\r?\n/).map((s) => s.trim()).filter((s) => s && !s.includes('ERROR') && !s.includes(' '));
  };
  const seen = new Set(), out = [];
  for (const u of await all('-l')) if (!seen.has(u)) { seen.add(u); out.push({ udid: u, isNetwork: false, kind: 'apple' }); }
  // USB by default: reading a whole library over Wi-Fi crawls. Wi-Fi phones are added only when the user opts in.
  if (wifi) for (const u of await all('-n')) if (!seen.has(u)) { seen.add(u); out.push({ udid: u, isNetwork: true, kind: 'apple' }); }
  return out;
}

async function name(device, tools) {
  const r = await run(tools.ideviceInfo, [...base(device), '-k', 'DeviceName'], { timeout: 8 });
  const n = r.output.trim();
  return r.ok && n && !n.includes('ERROR') ? n : `Device ${device.udid.slice(-4)}`;
}

async function isConnected(device, tools) {
  const r = await run(tools.ideviceId, [device.isNetwork ? '-n' : '-l'], { timeout: 8 });
  return r.output.includes(device.udid);
}

async function details(device, tools) {
  const kv = async (extra) => {
    const r = await run(tools.ideviceInfo, [...base(device), ...extra], { timeout: 12 });
    if (!r.ok || r.output.startsWith('ERROR')) return null;
    const d = {};
    for (const line of r.output.split(/\r?\n/)) {
      if (line.startsWith(' ') || line.startsWith('\t')) continue;
      const i = line.indexOf(':');
      if (i > 0) d[line.slice(0, i).trim()] = line.slice(i + 1).trim();
    }
    return d;
  };
  const main = await kv([]);
  if (!main || !(main.ProductType || main.DeviceName)) return null;
  const d = {
    platform: 'apple', name: main.DeviceName || 'iPhone', productType: main.ProductType || '—',
    modelName: main.MarketName || main.DeviceClass || 'iPhone', osVersion: main.ProductVersion || '—',
    osName: (main.ProductType || '').startsWith('iPad') ? 'iPadOS' : 'iOS',
    kindWord: (main.ProductType || '').startsWith('iPad') ? 'iPad' : 'iPhone',
    serial: main.SerialNumber || '—', totalBytes: 0, freeBytes: 0, battery: null, charging: null, cycles: null, health: null, info: [],
  };
  const disk = await kv(['-q', 'com.apple.disk_usage']);
  if (disk) { d.totalBytes = Number(disk.TotalDiskCapacity) || 0; d.freeBytes = Number(disk.AmountDataAvailable) || 0; }
  const bat = await kv(['-q', 'com.apple.mobile.battery']);
  if (bat) {
    if (bat.BatteryCurrentCapacity != null && bat.BatteryCurrentCapacity !== '') d.battery = Number(bat.BatteryCurrentCapacity);
    if (bat.BatteryIsCharging != null) d.charging = bat.BatteryIsCharging === 'true';
  }
  if (tools.diagnostics) {
    const r = await run(tools.diagnostics, [...base(device), 'ioregentry', 'AppleSmartBattery'], { timeout: 12 });
    if (r.ok) {
      const int = (key) => { const m = r.output.match(new RegExp(`<key>${key}</key>\\s*<integer>(\\d+)</integer>`)); return m ? Number(m[1]) : null; };
      d.cycles = int('CycleCount');
      const design = int('DesignCapacity'), now = int('AppleRawMaxCapacity') ?? int('NominalChargeCapacity');
      if (design > 0 && now != null) d.health = Math.min(100, Math.round((now / design) * 100));
    }
  }
  const row = (label, key, map) => { if (main[key]) d.info.push([label, map ? map(main[key]) : main[key]]); };
  row('Model', 'ProductType'); row('Model number', 'ModelNumber'); row('Serial number', 'SerialNumber');
  row('Software', 'ProductVersion', (v) => `${main.ProductName || 'iOS'} ${v} (${main.BuildVersion || ''})`);
  row('Identifier (UDID)', 'UniqueDeviceID'); row('Phone number', 'PhoneNumber'); row('IMEI', 'InternationalMobileEquipmentIdentity');
  row('Wi-Fi address', 'WiFiAddress'); row('Bluetooth address', 'BluetoothAddress'); row('Processor', 'CPUArchitecture');
  row('Modem firmware', 'BasebandVersion'); row('Activation', 'ActivationState');
  row('Passcode', 'PasswordProtected', (v) => (v === 'true' ? 'Set' : 'None')); row('Time zone', 'TimeZone');
  return d;
}

/// Copies the photo database off the device into `dir`. Returns its path, or null when the device refused.
async function fetchCatalog(device, tools, dir) {
  fs.mkdirSync(dir, { recursive: true });
  let cmds = '';
  for (const f of ['Photos.sqlite', 'Photos.sqlite-wal', 'Photos.sqlite-shm']) {
    const l = quote(path.join(dir, f));
    if (l) cmds += `get "PhotoData/${f}" ${l}\n`;
  }
  await run(tools.afc, base(device), { stdin: cmds + 'quit\n', timeout: 600 });
  const db = path.join(dir, 'Photos.sqlite');
  return fileSize(db) > 0 ? db : null;
}

async function remoteSize(remote, device, tools) {
  const r = await run(tools.afc, [...base(device), '--', 'info', remote], { timeout: 20 });
  const m = r.output.match(/st_size"?\s*[:=]\s*(\d+)/);
  return m ? Number(m[1]) : null;
}

async function list(dirPath, app, device, tools) {
  const clean = dirPath === '/' ? '.' : strip(dirPath);
  // "--" stops afcclient's own option reader from swallowing "-l".
  const r = await run(tools.afc, [...base(device), ...container(app), '--', 'ls', '-l', clean], { timeout: 60 });
  if (!r.ok) return [];
  const out = [];
  for (const raw of r.output.split(/\r?\n/)) {
    // drwxr-xr-x    2 mobile mobile      27264 10 Nov 2026 18:34:48 109APPLE
    const m = raw.match(/^([dl-][rwxsStT-]{9})\s+\S+\s+\S+\s+\S+\s+(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s(.+)$/);
    if (!m) continue;
    const nm = m[7].trim();
    if (!nm || nm === '.' || nm === '..') continue;
    out.push({ name: nm, path: dirPath === '/' ? `/${nm}` : `${dirPath}/${nm}`, isDirectory: m[1][0] === 'd', size: Number(m[2]) || 0, modified: `${m[3]} ${m[4]} ${m[5]}` });
  }
  return sortEntries(out);
}

const natural = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });
function sortEntries(list) {
  return list.sort((a, b) => (a.isDirectory !== b.isDirectory ? (a.isDirectory ? -1 : 1) : natural.compare(a.name, b.name)));
}

function freeName(nm, existing) {
  if (!existing.has(nm)) return nm;
  const ext = path.extname(nm), stem = path.basename(nm, ext);
  for (let i = 2; ; i++) { const c = `${stem} (${i})${ext}`; if (!existing.has(c)) return c; }
}

/// Copies one PC file or folder into a device folder. Never overwrites: an existing name gets " (2)" etc.
async function put(local, dir, existing, app, device, tools, job) {
  let st;
  try { st = fs.statSync(local); } catch { return false; }
  const nm = freeName(path.basename(local), existing);
  const clean = strip(dir);
  const remote = clean ? `${clean}/${nm}` : nm;
  const r = await run(tools.afc, [...base(device), ...container(app), '--', 'put', ...(st.isDirectory() ? ['-r'] : []), local, remote],
    { onStart: (c) => job && job.track(c) });
  const ok = r.ok && !r.output.includes('Error:');
  if (ok) existing.add(nm);
  return ok;
}

async function mkdir(p, app, device, tools) {
  const r = await run(tools.afc, [...base(device), ...container(app), '--', 'mkdir', strip(p)], { timeout: 20 });
  return r.ok && !r.output.includes('Error:');
}

/// Device → PC for one file or folder. `dest` must not exist yet.
async function pull(entry, dest, app, device, tools, job) {
  await run(tools.afc, [...base(device), ...container(app), '--', 'get', ...(entry.isDirectory ? ['-r'] : []), strip(entry.path), dest],
    { onStart: (c) => job && job.track(c) });
  return fs.existsSync(dest) && (entry.isDirectory || entry.size <= 0 || fileSize(dest) === entry.size);
}

/// Apps that share a folder with computers (video players, document readers…).
async function apps(device, tools) {
  let out = [];
  if (tools.applist) {
    const r = await run(tools.applist, [device.udid], { timeout: 30 });
    if (r.ok) out = r.output.split(/\r?\n/).map((l) => l.split('\t')).filter((p) => p.length === 2 && p[0]).map((p) => ({ id: p[0], name: p[1] }));
  } else if (tools.installer) {
    // Two spellings exist across versions of this tool; try the newer one first.
    let r = await run(tools.installer, [...base(device), 'list', '--user', '--xml'], { timeout: 60 });
    if (!r.ok || !r.output.includes('<plist')) r = await run(tools.installer, [...base(device), '-l', '-o', 'list_user', '-o', 'xml'], { timeout: 60 });
    if (r.ok) out = parseAppList(r.output);
  }
  return out.sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }));
}

function parseAppList(xml) {
  const out = [];
  // Each app is a <dict> directly inside the top-level <array>; nested dicts are skipped by tracking depth.
  const re = /<(\/?)(dict|array)>|<key>([^<]*)<\/key>\s*(?:<string>([^<]*)<\/string>|<(true|false)\/>)?/g;
  let depth = 0, cur = null, m;
  while ((m = re.exec(xml))) {
    if (m[2]) {
      if (!m[1]) { depth++; if (m[2] === 'dict' && depth === 2) cur = {}; }
      else { if (m[2] === 'dict' && depth === 2 && cur) { if (cur.id && cur.sharing) out.push({ id: cur.id, name: cur.name || cur.id }); cur = null; } depth--; }
    } else if (cur && depth === 2) {
      if (m[3] === 'CFBundleIdentifier') cur.id = m[4];
      else if (m[3] === 'CFBundleDisplayName' || (m[3] === 'CFBundleName' && !cur.name)) cur.name = decode(m[4] || '');
      else if (m[3] === 'UIFileSharingEnabled') cur.sharing = m[5] === 'true';
    }
  }
  return out;
}
const decode = (s) => s.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'");

async function power(action, device, tools) {
  if (!tools.diagnostics || !['restart', 'sleep'].includes(action)) return false;
  return (await run(tools.diagnostics, [...base(device), action], { timeout: 20 })).ok;
}

// Thumbnails asked for together (a screenful) share one device connection: requests wait 40 ms to gather,
// then up to 24 photos' small JPEGs are fetched in one afcclient session, with at most two sessions at a time.
const waiting = new Map();   // udid -> [{ cmds, done }]
let sessions = 0;
function fetchSmall(asset, device, tools, small, smaller) {
  const r1 = quote(`PhotoData/Thumbnails/V2/${asset.remotePath}/5005.JPG`), r2 = quote(`PhotoData/Thumbnails/V2/${asset.remotePath}/5003.JPG`);
  if (!r1 || !r2) return Promise.resolve();
  return new Promise((done) => {
    const q = waiting.get(device.udid) || [];
    q.push({ cmds: `get ${r1} ${quote(small)}\nget ${r2} ${quote(smaller)}\n`, done });
    if (!waiting.has(device.udid)) { waiting.set(device.udid, q); setTimeout(() => flush(device, tools), 40); }
  });
}
async function flush(device, tools) {
  const q = waiting.get(device.udid) || [];
  if (sessions >= 2) { setTimeout(() => flush(device, tools), 30); return; }
  const batch = q.splice(0, 24);
  if (!q.length) waiting.delete(device.udid); else setTimeout(() => flush(device, tools), 0);
  if (!batch.length) return;
  sessions++;
  try { await run(tools.afc, base(device), { stdin: batch.map((b) => b.cmds).join('') + 'quit\n', timeout: 60 }); }
  finally { sessions--; for (const b of batch) b.done(); }
}

/// A small preview picture the device keeps for each photo. Returns a local path or null.
async function thumbnail(asset, device, tools, cacheDir) {
  fs.mkdirSync(cacheDir, { recursive: true });
  // Photo IDs repeat across devices, so the cached files are named per device.
  const tag = `${String(device.udid).slice(-12)}-${asset.uuid || asset.id}`;
  const small = path.join(cacheDir, `${tag}_a.jpg`), smaller = path.join(cacheDir, `${tag}_b.jpg`);
  for (const f of [small, smaller]) if (fileSize(f) > 0) return f;
  // iOS keeps small pre-rendered JPEGs beside the library; the original is only fetched when they are missing.
  await fetchSmall(asset, device, tools, small, smaller);
  for (const f of [small, smaller]) if (fileSize(f) > 0) return f;
  // The browser window can show JPEG, PNG and GIF originals, but not HEIC.
  if (asset.isVideo || !/^(JPG|JPEG|PNG|GIF)$/.test(asset.ext) || asset.fileSize > 30_000_000) return null;
  const full = path.join(cacheDir, `${tag}_full.${asset.ext.toLowerCase()}`);
  if (fileSize(full) <= 0) await run(tools.afc, [...base(device), '--', 'get', asset.remotePath, full], { timeout: 60 });
  return fileSize(full) > 0 ? full : null;
}

module.exports = { base, quote, findDevices, name, isConnected, details, fetchCatalog, remoteSize, list, put, mkdir, pull, apps, parseAppList, power, thumbnail, sortEntries, freeName, strip };
