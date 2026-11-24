'use strict';
// Android phones and tablets over USB, through Google's adb. USB debugging must be on.
const fs = require('node:fs');
const path = require('node:path');
const { run } = require('./shell');
const { sortEntries, freeName } = require('./ios');

const ROOT = '/sdcard';
const args = (d) => ['-s', d.udid];
const sh = (s) => "'" + s.replace(/'/g, "'\\''") + "'";

async function findDevices(tools) {
  if (!tools.adb) return [];
  const r = await run(tools.adb, ['devices'], { timeout: 15 });
  if (!r.ok) return [];
  const out = [];
  for (const line of r.output.split(/\r?\n/)) {
    const p = line.trim().split(/\s+/);
    if (p.length === 2 && ['device', 'unauthorized'].includes(p[1])) out.push({ udid: p[0], isNetwork: p[0].includes(':'), kind: 'android', unauthorized: p[1] === 'unauthorized' });
  }
  return out;
}

/// Wireless debugging (Android 11 and later). Pairing, needed once per computer, uses the address and six-digit code from
/// "Pair device with pairing code"; connecting uses the address on the Wireless debugging screen. Returns null or a reason.
async function wireless({ pair = '', code = '', address = '' }, tools) {
  if (!tools.adb) return 'Set up Android support first.';
  const valid = (a) => /^[A-Za-z0-9.\-\[\]:%]+:\d{2,5}$/.test(a);
  const p = String(pair).trim(), c = String(code).replace(/\D/g, ''), a = String(address).trim();
  if (p || String(code).trim()) {
    if (!valid(p) || c.length !== 6) return 'Enter the pairing address (like 192.168.1.20:37001) and the six-digit code the phone shows.';
    const r = await run(tools.adb, ['pair', p, c], { timeout: 30 });
    if (!(r.output || '').includes('Successfully paired')) return 'Pairing didn’t work. Check the code: it changes every time the phone shows it.';
  }
  if (!valid(a)) return 'Enter the address shown on the phone’s Wireless debugging screen (like 192.168.1.20:41235).';
  const out = ((await run(tools.adb, ['connect', a], { timeout: 30 })).output || '').toLowerCase();
  if (!out.includes('connected to') || out.includes('failed') || out.includes('unable')) return `The phone didn’t answer at ${a}. Keep Wireless debugging on, with the phone and this computer on the same Wi-Fi.`;
  return null;
}

async function shell(cmd, device, tools, timeout = 20) {
  const r = await run(tools.adb, [...args(device), 'shell', cmd], { timeout });
  return r.ok ? r.output.replace(/\r\n/g, '\n') : null;
}

async function name(device, tools) {
  if (device.unauthorized) return 'Android (waiting for Allow)';
  const n = ((await shell('getprop ro.product.model', device, tools, 8)) || '').trim();
  return n || `Android ${device.udid.slice(-4)}`;
}

async function details(device, tools) {
  const raw = await shell('getprop', device, tools);
  if (raw == null) return null;
  const p = {};
  for (const line of raw.split('\n')) { const m = line.match(/^\[([^\]]+)\]: \[(.*)\]$/); if (m) p[m[1]] = m[2]; }
  const model = p['ro.product.model'];
  if (!model) return null;
  const maker = (p['ro.product.manufacturer'] || '').replace(/^./, (c) => c.toUpperCase());
  const d = {
    platform: 'android', name: model, productType: p['ro.product.device'] || '—',
    modelName: !maker || model.toLowerCase().startsWith(maker.toLowerCase()) ? model : `${maker} ${model}`,
    osVersion: p['ro.build.version.release'] || '—', osName: 'Android', kindWord: 'Android device',
    serial: p['ro.serialno'] || device.udid, totalBytes: 0, freeBytes: 0, battery: null, charging: null, cycles: null, health: null, info: [],
  };
  const df = await shell(`df -k ${ROOT}/`, device, tools);
  if (df) {
    const f = df.trim().split('\n').pop().trim().split(/\s+/);
    if (f.length >= 4 && Number(f[1]) > 0) { d.totalBytes = Number(f[1]) * 1024; d.freeBytes = Number(f[3]) * 1024; }
  }
  const bat = await shell('dumpsys battery', device, tools);
  if (bat) {
    const value = (key) => { const m = bat.match(new RegExp(`^\\s*${key}:\\s*(.+)$`, 'm')); return m ? m[1].trim() : null; };
    const level = Number(value('level')), scale = Number(value('scale') || 100);
    if (Number.isFinite(level) && scale > 0 && value('level') != null) d.battery = Math.floor((level * 100) / scale);
    const status = Number(value('status'));
    if (value('status') != null) d.charging = status === 2 || status === 5;
    const cycles = Number(value('Charging cycle count') || value('cycle count'));
    if (cycles > 0) d.cycles = cycles;
  }
  const row = (label, key) => { if (p[key]) d.info.push([label, p[key]]); };
  d.info.push(['Model', d.modelName]); row('Device code name', 'ro.product.device'); d.info.push(['Serial number', d.serial]);
  d.info.push(['Software', `Android ${d.osVersion} (${p['ro.build.id'] || ''})`]); row('Security patch', 'ro.build.version.security_patch');
  row('Processor', 'ro.product.cpu.abi'); row('Chipset', 'ro.soc.model'); row('Modem firmware', 'gsm.version.baseband');
  row('Carrier', 'gsm.sim.operator.alpha'); row('Time zone', 'persist.sys.timezone');
  return d;
}

async function list(dir, device, tools) {
  // The trailing slash makes ls follow /sdcard, which is a link on most phones.
  const out = await shell(`ls -la ${sh(dir.endsWith('/') ? dir : dir + '/')}`, device, tools, 60);
  if (out == null) return [];
  const entries = [];
  for (const raw of out.split('\n')) {
    // drwxrwx--x 3 root sdcard_rw 4096 2026-11-10 18:34 Camera
    const m = raw.match(/^([dl-][rwxsStT-]{9}\S*)\s+\S+\s+\S+\s+\S+\s+(\d+)\s+(\S+)\s+(\S+)\s(.+)$/);
    if (!m) continue;
    let nm = m[5];
    if (m[1][0] === 'l' && nm.includes(' -> ')) nm = nm.slice(0, nm.indexOf(' -> '));
    if (!nm || nm === '.' || nm === '..') continue;
    entries.push({ name: nm, path: dir === '/' ? `/${nm}` : `${dir}/${nm}`, isDirectory: m[1][0] !== '-', size: Number(m[2]) || 0, modified: `${m[3]} ${m[4]}` });
  }
  return sortEntries(entries);
}

/// Phone → PC. Folders are copied whole. `dest` must not exist yet.
async function pull(entry, dest, device, tools, job) {
  if (fs.existsSync(dest)) return false;
  const r = await run(tools.adb, [...args(device), 'pull', '-a', entry.path, dest], { onStart: (c) => job && job.track(c) });
  return r.ok && fs.existsSync(dest);
}

/// PC → phone. Never overwrites: an existing name gets " (2)" etc.
async function push(local, dir, existing, device, tools, job) {
  if (!fs.existsSync(local)) return false;
  const nm = freeName(path.basename(local), existing);
  const r = await run(tools.adb, [...args(device), 'push', local, `${dir}/${nm}`], { onStart: (c) => job && job.track(c) });
  if (r.ok) existing.add(nm);
  return r.ok;
}

async function mkdir(p, device, tools) {
  return ((await shell(`mkdir ${sh(p)} && echo made`, device, tools)) || '').includes('made');
}

async function mkdirs(p, device, tools) {
  return ((await shell(`mkdir -p ${sh(p)} && echo made`, device, tools)) || '').includes('made');
}

const chunks = (list, n) => { const out = []; for (let i = 0; i < list.length; i += n) out.push(list.slice(i, i + n)); return out; };

/// Asks the phone's media index to pick up new or removed files, so the Gallery and music apps show the change.
/// Android 11 and later notice files themselves; older versions need this.
async function scan(paths, device, tools) {
  for (const c of chunks(paths, 40)) {
    await shell(c.map((p) => `am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d ${sh('file://' + p)} >/dev/null`).join('; '), device, tools, 60);
  }
}

/// Deletes files from the phone. Resolves to the paths that are gone afterwards.
async function remove(paths, device, tools) {
  const gone = [];
  for (const c of chunks(paths, 40)) {
    const out = (await shell(c.map((p) => `rm -f -- ${sh(p)} && [ ! -e ${sh(p)} ] && echo ${sh('GONE ' + p)}`).join('; '), device, tools, 120)) || '';
    for (const line of out.split('\n')) if (line.startsWith('GONE ')) gone.push(line.slice(5));
  }
  await scan(gone, device, tools);
  return gone;
}

/// Every file in a phone folder and the folders inside it, with sizes (for checking copies before deleting).
async function filesBelow(dir, device, tools) {
  const out = [], todo = [dir];
  while (todo.length && out.length < 200000) {
    for (const e of await list(todo.pop(), device, tools)) { if (e.isDirectory) todo.push(e.path); else out.push(e); }
  }
  return out;
}

/// Sends every file in a computer folder to a phone folder, keeping the layout inside it. A file already there with the same
/// name and size is left alone; a different file with the same name gets " (2)". The Gallery is told about new files.
async function sendFolder(local, remoteRoot, phone, tools, job, progress = () => {}) {
  const files = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      if (e.name.startsWith('.')) continue;
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p); else if (e.isFile()) files.push(p);
    }
  };
  walk(local);
  files.sort();
  let sent = 0, already = 0;
  const failed = [], scanned = [], listed = new Map();
  for (let i = 0; i < files.length; i++) {
    if (job && job.cancelled) break;
    progress(i, files.length);
    const file = files[i];
    const rel = path.relative(local, path.dirname(file)).split(path.sep).join('/');
    const dir = rel ? `${remoteRoot}/${rel}` : remoteRoot;
    if (!listed.has(dir)) {
      await mkdirs(dir, phone, tools);
      listed.set(dir, new Map((await list(dir, phone, tools)).map((e) => [e.name, e.size])));
    }
    const here = listed.get(dir), size = fs.statSync(file).size, name = path.basename(file);
    if (here.get(name) === size) { already++; continue; }
    const before = new Set(here.keys()), existing = new Set(before);
    if (await push(file, dir, existing, phone, tools, job)) {
      const used = [...existing].find((n) => !before.has(n)) || name;
      sent++;
      scanned.push(`${dir}/${used}`);
      here.set(used, size);
    } else failed.push(name);
  }
  progress(files.length, files.length);
  await scan(scanned, phone, tools);
  return { sent, already, failed };
}

async function power(action, device, tools) {
  if (action === 'restart') return (await run(tools.adb, [...args(device), 'reboot'], { timeout: 20 })).ok;
  if (action === 'sleep') return (await shell('input keyevent 223', device, tools)) != null;
  return false;
}

/// Folders of photos and videos from Android's media index (MediaStore), biggest first: Camera, Screenshots, WhatsApp Images…
async function mediaAlbums(device, tools) {
  const out = await shell("content query --uri content://media/external/file --projection _data:_size --where 'media_type=1 OR media_type=3'", device, tools, 60);
  return out ? parseMediaAlbums(out) : [];
}
function parseMediaAlbums(out) {
  const byDir = new Map();
  for (const line of out.split('\n')) {
    const m = line.match(/^Row: \d+ _data=(.*?)(?:, _size=(\d+))?\s*$/);
    if (!m) continue;
    let p = m[1];
    for (const pre of ['/storage/emulated/0', '/sdcard']) if (p.startsWith(pre + '/')) p = ROOT + p.slice(pre.length);
    if (!p.startsWith(ROOT + '/')) continue;   // SD cards and other volumes are not browsed here
    const dir = p.slice(0, p.lastIndexOf('/'));
    const cur = byDir.get(dir) || { count: 0, bytes: 0 };
    cur.count++; cur.bytes += Number(m[2] || 0);
    byDir.set(dir, cur);
  }
  return [...byDir].map(([path, v]) => ({ name: path.split('/').pop(), path, ...v }))
    .sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
}

module.exports = { ROOT, args, sh, shell, mediaAlbums, parseMediaAlbums, findDevices, name, details, list, pull, push, mkdir, mkdirs, scan, remove, filesBelow, sendFolder, power, wireless };
