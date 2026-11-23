'use strict';
const { app, BrowserWindow, ipcMain, dialog, shell, Menu, powerSaveBlocker, nativeTheme, Notification } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { run, Job, locateTools, fileSize, uniquePath, bytes, WIN } = require('./core/shell');
const ios = require('./core/ios');
const android = require('./core/android');
const { loadCatalog, view } = require('./core/catalog');
const updates = require('./core/updates');
const net = require('node:net');
const { exportAssets } = require('./core/exporter');
const bk = require('./core/backup');

// Test switches: PORTHOP_<name>, or PAE_<name> as versions before 2.1 called them.
const env = new Proxy(process.env, { get: (e, k) => (typeof k === 'string' && k.startsWith('PORTHOP_') ? (e[k] ?? e['PAE_' + k.slice(8)]) : e[k]) });
// Test-only switches work only when running from source, never in the packaged app.
const TEST = !app.isPackaged;
process.on('unhandledRejection', (e) => console.error('Unhandled', e));
let win = null;
let tools = null;
const S = {
  phase: 'searching', message: '', devices: [], names: {}, device: null, details: null,
  smart: [], user: [], people: [], warnings: [], apps: [], busy: false, preferred: null, restartingSince: 0, restartingName: '', exportDest: null,
};
const jobs = { export: null, transfer: null, backup: null };
let blocker = null;
// Keeps the computer from sleeping while a copy, backup or restore runs.
function startJob(kind) {
  const job = jobs[kind] = new Job();
  if (blocker == null) blocker = powerSaveBlocker.start('prevent-app-suspension');
  return job;
}
function endJob(kind) {
  jobs[kind] = null;
  if (!Object.values(jobs).some(Boolean) && blocker != null) { powerSaveBlocker.stop(blocker); blocker = null; }
}
const browser = { app: null, root: '/', path: '/', entries: [] };
let data = { reader: null, kind: null, result: null, password: (TEST && env.PORTHOP_BACKUP_PASSWORD) || null, source: '' };
const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'PortHop-'));

// MARK: settings

const settingsFile = () => path.join(app.getPath('userData'), 'settings.json');
let settings = {};
function loadSettings() { try { settings = JSON.parse(fs.readFileSync(settingsFile(), 'utf8')); } catch { settings = {}; } }
function saveSettings() { try { fs.mkdirSync(path.dirname(settingsFile()), { recursive: true }); fs.writeFileSync(settingsFile(), JSON.stringify(settings)); } catch {} }
const backupFolder = () => (TEST && env.PORTHOP_BACKUP_DIR) || settings.backupFolder || path.join(app.getPath('documents'), 'Phone Backups');

// MARK: connection

const isAndroid = () => S.device && S.device.kind === 'android';
const working = () => !!(jobs.export || jobs.transfer || jobs.backup);
const albums = () => [...S.smart, ...S.user, ...S.people];
// Photo by ID, rebuilt only when a new library is loaded, so each thumbnail request is one lookup.
let byIdFor = null, byId = new Map();
const assetById = (id) => {
  if (byIdFor !== S.smart) { byIdFor = S.smart; byId = new Map(); for (const al of albums()) for (const a of al.assets) byId.set(a.id, a); }
  return byId.get(id);
};
const album = (id) => albums().find((a) => a.id === id);

function snapshot() {
  const al = (a) => ({ id: a.id, title: a.title, smart: a.smart, count: a.assets.length, bytes: a.assets.reduce((n, x) => n + Math.max(0, x.fileSize), 0),
    thumbs: a.assets.filter((x) => !x.isVideo).slice(0, 3).map((x) => x.id) });
  return {
    phase: S.phase, message: S.message, device: S.device, devices: S.devices.map((d) => ({ ...d, name: S.names[d.udid] || 'Device' })),
    details: S.details, smart: S.smart.map(al), user: S.user.map(al), people: S.people.map(al), warnings: S.warnings, apps: S.apps,
    hasAdb: !!(tools && tools.adb), hasApple: !!(tools && tools.hasApple), canPower: !!(tools && (isAndroid() ? tools.adb : tools.diagnostics)),
    canBackup: !!(tools && tools.backup), isWindows: WIN, backupFolder: backupFolder(),
    restarting: !!S.restartingSince && Date.now() - S.restartingSince < 600000, restartingName: S.restartingName,
    lastHop: settings.lastHop || '', exportDest: S.exportDest || null, update: S.update || null, appleDriverMissing: !!S.appleDriverMissing, androidAlbums: isAndroid() ? (S.androidAlbums || []).slice(0, 12) : [],
  };
}
function push() { if (win && !win.isDestroyed()) win.webContents.send('state', snapshot()); }
function send(channel, payload) { if (win && !win.isDestroyed()) win.webContents.send(channel, payload); }

function reset(phase, message = '') { S.androidAlbums = [];
  S.device = null; S.details = null; S.smart = []; S.user = []; S.people = []; S.warnings = []; S.apps = [];
  S.phase = phase; S.message = message;
  push();
}

/// Apple's device service (from the Apple Devices app or iTunes) listens on this port; without it Windows cannot see iPhones.
function appleServiceRunning() {
  return new Promise((resolve) => {
    const s = net.connect({ host: '127.0.0.1', port: 27015 });
    const done = (v) => { s.destroy(); resolve(v); };
    s.once('connect', () => done(true)); s.once('error', () => done(false)); s.setTimeout(800, () => done(false));
  });
}

async function allDevices() { return [...await ios.findDevices(tools, { wifi: !!settings.includeWiFi }), ...await android.findDevices(tools)]; }
const label = (d) => (d.kind === 'android' ? android.name(d, tools) : ios.name(d, tools));

async function connect(silent) {
  if (S.busy || working()) return;
  S.busy = true;
  try {
    if (!silent) { S.phase = 'searching'; push(); }
    tools = locateTools(process.resourcesPath, TEST);
    if (!tools.hasApple && !tools.adb) return reset('toolsMissing');
    const found = await allDevices();
    S.devices = found;
    const device = found.find((d) => d.udid === S.preferred) || found[0];
    // On Windows the iPhone needs Apple's device service; when it is not running, say so plainly.
    S.appleDriverMissing = !device && WIN && tools.hasApple ? !(await appleServiceRunning()) : false;
    if (!device) return reset('noDevice');
    if (found.length > 1) for (const d of found) S.names[d.udid] = await label(d);
    if (device.kind === 'android') {
      const info = device.unauthorized ? null : await android.details(device, tools);
      if (!info) return reset('needsTrust', device.unauthorized ? 'Unlock the Android device and tap Allow on the “Allow USB debugging?” message.'
        : 'The Android device is connected but did not answer. Unlock it and keep it plugged in.');
      S.device = device; S.details = info; S.names[device.udid] = info.name;
      android.mediaAlbums(device, tools).then((al) => { if (S.device && S.device.udid === device.udid) { S.androidAlbums = al; push(); } });
      S.smart = []; S.user = []; S.people = []; S.warnings = []; S.apps = [];
      S.restartingSince = 0; S.phase = 'ready'; push();
      return;
    }
    const info = await ios.details(device, tools);
    if (!info) return reset('needsTrust', 'Unlock your iPhone or iPad and tap Trust when it asks.'
      + (WIN ? ' If it never asks, install “Apple Devices” from the Microsoft Store, which provides the iPhone driver.' : ''));
    S.details = info; S.phase = 'loading'; S.message = `Reading the photo library from ${info.name}…`; push();
    const dir = path.join(tempRoot, 'catalog');
    fs.rmSync(dir, { recursive: true, force: true });
    const db = await ios.fetchCatalog(device, tools, dir);
    if (!db) return reset('needsTrust', `${info.name} is connected, but its photo library could not be read. Keep it unlocked and tap Trust if asked.`);
    S.message = 'Organising albums…'; push();
    let cat = loadCatalog(db);
    if (cat.error) {
      // A journal caught half-written while the phone was busy can make the copy unreadable: read it without the journal.
      for (const f of [db + '-wal', db + '-shm']) fs.rmSync(f, { force: true });
      const retry = loadCatalog(db);
      if (!retry.error) cat = { ...retry, warnings: [...retry.warnings, 'The last few minutes of changes on the phone could not be read. Choose Refresh to read them.'] };
    }
    fs.rmSync(dir, { recursive: true, force: true });
    if (cat.error) {
      S.phase = 'catalogError';
      S.message = cat.error === 'unreadable' ? 'The photo database was copied from the device but could not be opened. Try Refresh with the device unlocked.'
        : `${info.osName} ${info.osVersion} stores its photo library in a format this app does not understand yet. ${cat.why}`;
      return push();
    }
    S.device = device; S.names[device.udid] = info.name;
    S.smart = cat.smart; S.user = cat.user; S.people = cat.people || []; S.warnings = cat.warnings;
    S.restartingSince = 0; S.phase = 'ready'; push();
    ios.apps(device, tools).then((list) => { if (S.device === device) { S.apps = list; push(); } });
  } finally { S.busy = false; }
}

let polling = false;
async function poll() {
  // A slow device check must finish before the next one starts, or checks pile up.
  if (polling || S.busy || working()) return;
  polling = true;
  try {
    if (['noDevice', 'needsTrust', 'toolsMissing'].includes(S.phase)) return await connect(true);
    if (S.phase !== 'ready' || !S.device) return;
    const device = S.device;
    const found = await allDevices();
    if (S.device !== device || working()) return;
    if (found.some((d) => d.udid === device.udid && !d.unauthorized)) {
      if (found.length !== S.devices.length) {
        for (const d of found) if (!S.names[d.udid]) S.names[d.udid] = await label(d);
        S.devices = found; push();
      }
    } else if (!found.length) { S.devices = []; reset('noDevice'); }
    else { S.preferred = null; connect(false); }
  } catch (e) { console.error('poll', e); }
  finally { polling = false; }
}

// MARK: helpers

function rowsFor(q) {
  const a = album(q.album);
  if (!a) return [];
  return view(a.assets, q);
}
const kindText = (a) => (a.isVideo ? 'Video' : a.isLivePhoto ? 'Live Photo' : a.isScreenshot ? 'Screenshot' : 'Photo');
function duration(s) {
  s = Math.round(s);
  const p = (n) => String(n).padStart(2, '0');
  return s >= 3600 ? `${Math.floor(s / 3600)}:${p(Math.floor((s % 3600) / 60))}:${p(s % 60)}` : `${Math.floor(s / 60)}:${p(s % 60)}`;
}

async function drives() {
  const out = [];
  if (WIN) {
    const r = await run('powershell.exe', ['-NoProfile', '-Command',
      'Get-CimInstance Win32_LogicalDisk | Select-Object DeviceID,DriveType,FileSystem,VolumeName,FreeSpace,Size | ConvertTo-Json -Compress'], { timeout: 15 });
    try {
      let list = JSON.parse(r.output.trim());
      if (!Array.isArray(list)) list = [list];
      const system = (env.SystemDrive || 'C:').toUpperCase();
      for (const d of list) {
        if (![2, 3].includes(d.DriveType) || !d.Size || String(d.DeviceID).toUpperCase() === system) continue;
        out.push({ path: d.DeviceID + '\\', name: d.VolumeName ? `${d.VolumeName} (${d.DeviceID})` : `Drive ${d.DeviceID}`, free: Number(d.FreeSpace) || 0, format: d.FileSystem || '', removable: d.DriveType === 2 });
      }
    } catch {}
  } else {
    try {
      for (const n of fs.readdirSync('/Volumes')) {
        const p = path.join('/Volumes', n);
        if (n.startsWith('.') || /^(Recovery|Preboot|VM|Update|xarts|iSCPreboot|Hardware)$/.test(n)) continue;
        try { if (fs.realpathSync(p) === '/') continue; const st = fs.statfsSync(p); out.push({ path: p, name: n, free: Number(st.bavail) * Number(st.bsize), format: '', removable: true }); } catch {}
      }
    } catch {}
  }
  return out;
}

function freeSpace(p) {
  let dir = p;
  while (dir && !fs.existsSync(dir)) { const up = path.dirname(dir); if (up === dir) break; dir = up; }
  try { const st = fs.statfsSync(dir); return Number(st.bavail) * Number(st.bsize); } catch { return null; }
}

// MARK: IPC

const handlers = {
  state: () => snapshot(),
  refresh: () => { connect(false); },
  switch: (udid) => { if (!working() && S.device && udid !== S.device.udid) { S.preferred = udid; connect(false); } },

  'album:rows': (q) => {
    const list = rowsFor(q);
    let total = 0, videos = 0;
    const rows = list.map((a) => {
      total += Math.max(0, a.fileSize); if (a.isVideo) videos++;
      return [a.id, a.filename, a.isVideo && a.duration > 0 ? `${kindText(a)} · ${duration(a.duration)}` : kindText(a), a.fileSize,
        a.width > 0 && a.height > 0 ? `${a.width} × ${a.height}` : '—', a.dateText, a.originalFilename, a.directory, a.isFavorite ? 1 : 0, a.isVideo ? 1 : 0];
    });
    return { rows, bytes: total, videos };
  },

  'pick:folder': async (title) => {
    const r = await dialog.showOpenDialog(win, { title: title || 'Choose a folder', properties: ['openDirectory', 'createDirectory'] });
    return r.canceled ? null : r.filePaths[0];
  },
  'pick:files': async () => {
    const r = await dialog.showOpenDialog(win, { title: 'Choose files to add', properties: ['openFile', 'multiSelections'] });
    return r.canceled ? [] : r.filePaths;
  },
  drives,
  space: (p) => freeSpace(p),
  defaults: () => ({ pictures: path.join(app.getPath('pictures'), 'Phone Export'), downloads: app.getPath('downloads') }),
  reveal: (p) => {
    // A folder that does not exist yet (nothing copied there so far) opens its nearest existing parent.
    let t = p;
    while (t && !fs.existsSync(t)) { const up = path.dirname(t); if (up === t) return; t = up; }
    if (fs.statSync(t).isDirectory()) shell.openPath(t); else shell.showItemInFolder(t);
  },
  copy: (text) => { require('electron').clipboard.writeText(String(text)); },

  // What the copy dialog needs to know about a set before copying: edits, iCloud-only items, HEIC photos.
  'export:facts': ({ query, ids }) => {
    let assets = rowsFor(query);
    if (ids) { const set = new Set(ids); assets = assets.filter((a) => set.has(a.id)); }
    return { edited: assets.filter((a) => a.isEdited).length, cloud: assets.filter((a) => a.isCloudOnly).length, heic: assets.filter((a) => a.isHEIC).length };
  },
  // Saved hops: a whole group to a folder with its options; running one copies only what's new.
  'presets:list': () => (settings.presets || []).map((p) => {
    const al = album(p.albumID);
    let parent = path.dirname(p.dest);
    return { ...p, auto: !!p.auto, count: al ? al.assets.length : 0, title: al ? al.title : '', onDevice: !!al, reachable: fs.existsSync(parent) };
  }),
  'presets:save': (p) => {
    settings.presets = (settings.presets || []).filter((x) => !(x.albumID === p.albumID && x.dest === p.dest));
    settings.presets.push({ id: require('node:crypto').randomUUID(), name: String(p.name), albumID: String(p.albumID), dest: String(p.dest), options: p.options || {},
      auto: !!p.auto, deviceID: S.device ? S.device.udid : null });
    saveSettings();
  },
  // "Run by itself when plugged in" belongs to the device connected when it is turned on, never to another phone.
  'presets:setAuto': ({ id, on }) => {
    const p = (settings.presets || []).find((x) => x.id === id);
    if (p) { p.auto = !!on; if (on && S.device) p.deviceID = S.device.udid; saveSettings(); }
  },
  'presets:auto': () => (settings.presets || []).filter((p) => p.auto && S.device && p.deviceID === S.device.udid && album(p.albumID)
    && album(p.albumID).assets.length && fs.existsSync(path.dirname(p.dest))).map((p) => ({ ...p, title: album(p.albumID).title })),
  notify: ({ title, body }) => { if (Notification.isSupported()) new Notification({ title: String(title), body: String(body || '') }).show(); },
  'presets:delete': (id) => { settings.presets = (settings.presets || []).filter((x) => x.id !== id); saveSettings(); },

  'export:start': async ({ query, ids, dest, options }) => {
    if (working() || !S.device || isAndroid()) return null;
    options = { ...options, deviceName: S.details ? S.details.name : '' };
    let assets = rowsFor(query);
    if (ids) { const set = new Set(ids); assets = assets.filter((a) => set.has(a.id)); }
    const job = startJob('export');
    rememberDestination(dest);
    S.exportDest = dest; push();
    let last = 0;
    try {
      const summary = await exportAssets({ assets, dest, options, device: S.device, tools, job,
        onProgress: (p) => { const now = Date.now(); if (now - last > 200) { last = now; send('export:progress', p); } } });
      summary.failedIds = summary.failures.map((f) => f.id);
      if (summary.copied > 0) {
        settings.lastHop = `${summary.copied.toLocaleString()} item${summary.copied === 1 ? '' : 's'} to ${path.basename(dest)} · ${new Date().toLocaleString()}`;
        saveSettings();
      }
      return summary;
    } finally { endJob('export'); S.exportDest = null; push(); }
  },
  'export:stop': () => { if (jobs.export) jobs.export.cancel(); },

  'files:open': async (appId) => {
    if (!S.device) return null;
    browser.app = appId || null;
    browser.root = isAndroid() ? android.ROOT : '/';
    let entries = await listDir(browser.root);
    // An app's shared area is a "Documents" folder inside its container; start there.
    if (browser.app && entries.some((e) => e.isDirectory && e.name === 'Documents')) { browser.root = '/Documents'; entries = await listDir(browser.root); }
    browser.path = browser.root; browser.entries = entries;
    return { root: browser.root, path: browser.path, entries, canAdd: !!browser.app || isAndroid() };
  },
  'files:list': async (p) => {
    if (!S.device) return null;
    browser.entries = await listDir(p); browser.path = p;
    return { root: browser.root, path: p, entries: browser.entries, canAdd: !!browser.app || isAndroid() };
  },
  'files:upload': async (paths) => {
    if (working() || !S.device || !(browser.app || isAndroid()) || !paths.length) return null;
    const job = startJob('transfer'), dir = browser.path, existing = new Set(browser.entries.map((e) => e.name));
    let added = 0;
    try {
      for (let i = 0; i < paths.length && !job.cancelled; i++) {
        send('files:progress', `Adding ${i + 1} of ${paths.length}: ${path.basename(paths[i])}`);
        const ok = isAndroid() ? await android.push(paths[i], dir, existing, S.device, tools, job) : await ios.put(paths[i], dir, existing, browser.app, S.device, tools, job);
        if (ok) added++;
      }
      browser.entries = await listDir(dir);
      return { added, total: paths.length, cancelled: job.cancelled, entries: browser.entries };
    } finally { endJob('transfer'); }
  },
  'files:download': ({ paths, folder }) => download(browser.entries.filter((e) => paths.includes(e.path)), folder),
  'folders:copy': ({ paths, folder }) => {
    rememberDestination(folder);
    return download(paths.map((p) => ({ name: path.posix.basename(p), path: p, isDirectory: true, size: 0 })), folder);
  },
  'album:months': (id) => months(id),
  destinations: () => destinations(),
  'dest:remember': (p) => { rememberDestination(p); return destinations(); },
  'files:mkdir': async (name) => {
    const clean = String(name).trim().replace(/[\\/]/g, '-');
    if (!S.device || !clean || !(browser.app || isAndroid())) return null;
    const p = browser.path === '/' ? `/${clean}` : `${browser.path}/${clean}`;
    const ok = isAndroid() ? await android.mkdir(p, S.device, tools) : await ios.mkdir(p, browser.app, S.device, tools);
    browser.entries = await listDir(browser.path);
    return { ok, entries: browser.entries };
  },
  'files:stop': () => { if (jobs.transfer) jobs.transfer.cancel(); },

  power: async (action) => {
    if (!S.device || working()) return false;
    const ok = await (isAndroid() ? android.power(action, S.device, tools) : ios.power(action, S.device, tools));
    if (ok && action === 'restart') { S.restartingSince = Date.now(); S.restartingName = S.details ? S.details.name : ''; }
    return ok;
  },

  'backup:list': () => bk.existing(backupFolder()),
  // "Back up when plugged in, once a day": off until turned on. Due when this device has no backup from the last 20 hours.
  'backup:auto': (v) => { if (typeof v === 'boolean') { settings.autoBackup = v; saveSettings(); } return !!settings.autoBackup; },
  'backup:autoDue': () => {
    if (!settings.autoBackup || !S.device || isAndroid() || !tools || !tools.backup || working()) return false;
    const mine = bk.existing(backupFolder()).filter((b) => path.basename(b.path) === S.device.udid && b.date);
    const latest = Math.max(0, ...mine.map((b) => new Date(b.date).getTime()));
    return Date.now() - latest > 20 * 3600 * 1000;
  },
  'backup:folder': (p) => { settings.backupFolder = p; saveSettings(); push(); return bk.existing(p); },
  'backup:start': async () => {
    if (working() || !S.device || isAndroid()) return 'Connect an iPhone or iPad first.';
    const job = startJob('backup');
    let last = 0;
    try {
      return await bk.runBackup(S.device, tools, backupFolder(), job, (percent, phase) => {
        const now = Date.now(); if (now - last > 250) { last = now; send('backup:progress', { percent, phase }); }
      });
    } finally { endJob('backup'); }
  },
  'backup:restore': async ({ path: folder, password }) => {
    if (working() || !S.device || isAndroid()) return 'Connect an iPhone or iPad first.';
    const entry = bk.existing(backupFolder()).find((b) => b.path === folder);
    if (!entry) return 'That backup is no longer in the folder.';
    const job = startJob('backup');
    let last = 0;
    try {
      const problem = await bk.runRestore(entry, S.device, tools, password || null, job, (percent, phase) => {
        const now = Date.now(); if (now - last > 250) { last = now; send('backup:progress', { percent, phase }); }
      });
      if (problem === null) { S.restartingSince = Date.now(); S.restartingName = S.details ? S.details.name : ''; }
      return problem;
    } finally { endJob('backup'); }
  },
  'backup:stop': () => { if (jobs.backup) jobs.backup.cancel(); },

  'data:open': async ({ kind, password }) => {
    if (password) data.password = password;
    const list = bk.existing(backupFolder());
    const entry = list[0];
    if (!entry) return { note: 'There is no backup yet. Make one on the Backups screen, then come back here.', groups: [] };
    const source = `From the ${entry.encrypted ? 'encrypted ' : ''}backup of ${entry.deviceName}` + (entry.date ? ` made ${new Date(entry.date).toLocaleString()}` : '');
    if (!data.reader || data.reader.folder !== entry.path) {
      if (data.reader) { data.reader.close(); data.reader = null; }
      const r = await bk.BackupReader.open(entry.path, data.password);
      if (r.needsPassword || r.wrongPassword) { data.password = null; return { needsPassword: true, wrongPassword: !!r.wrongPassword, source, groups: [] }; }
      if (!r.reader) return { note: 'This backup could not be opened. It may be unfinished: run the backup again.', source, groups: [] };
      data.reader = r.reader;
    }
    data.kind = kind;
    data.result = await data.reader.load(kind);
    return { source, note: data.result.note, groups: data.result.groups.map((g) => ({ id: g.id, title: g.title, subtitle: g.subtitle, count: g.rows.length })) };
  },
  'data:rows': (id) => {
    const g = data.result && data.result.groups.find((x) => x.id === id);
    return g ? { columns: g.columns, rows: g.rows } : { columns: [], rows: [] };
  },
  'data:save': ({ id, all, folder }) => {
    if (!data.result) return null;
    const groups = all ? data.result.groups : data.result.groups.filter((g) => g.id === id);
    const title = bk.KINDS[data.kind].title, safe = (s) => (String(s).replace(/[\\/:*?"<>|\r\n]/g, '-').trim().slice(0, 80) || 'Untitled');
    let target = folder;
    if (groups.length > 1) { target = uniquePath(path.join(folder, title)); fs.mkdirSync(target, { recursive: true }); }
    const reserved = new Set();
    let written = 0, first = null;
    for (const g of groups) {
      const file = uniquePath(path.join(target, (groups.length > 1 ? safe(g.title) : `${title} - ${safe(g.title)}`) + '.csv'), reserved);
      reserved.add(file);
      // The leading mark makes spreadsheet apps read accents and emoji correctly.
      try { fs.writeFileSync(file, '﻿' + bk.csv(g), { flag: 'wx' }); written++; first = first || file; } catch {}
    }
    if (first) { if (groups.length > 1) shell.openPath(target); else shell.showItemInFolder(first); }
    return { written, total: groups.length };
  },
  'data:page': async ({ id, folder }) => {
    const g = data.result && data.result.groups.find((x) => x.id === id);
    if (!g || !data.reader) return null;
    const page = await data.reader.webPage(g, bk.KINDS[data.kind].title, folder);
    if (page) shell.showItemInFolder(page);
    return { page, attachments: Object.values(g.media || {}).reduce((n, l) => n + l.length, 0) };
  },
  // The open chat as a paginated PDF: its web page printed by a hidden window (text stays searchable).
  'data:pdf': async ({ id, folder }) => {
    const g = data.result && data.result.groups.find((x) => x.id === id);
    if (!g || !data.reader) return null;
    const temp = fs.mkdtempSync(path.join(tempRoot, 'pdf-'));
    try {
      const page = await data.reader.webPage(g, bk.KINDS[data.kind].title, temp);
      if (!page) return null;
      const pdfWin = new BrowserWindow({ show: false, webPreferences: { sandbox: true, javascript: false } });
      try {
        await pdfWin.loadFile(path.join(page, 'index.html'));
        const pdf = await pdfWin.webContents.printToPDF({ printBackground: true, margins: { marginType: 'default' } });
        const { uniquePath } = require('./core/shell');
        const out = uniquePath(path.join(folder, `${g.title} (${bk.KINDS[data.kind].title})`.replace(/[\\/:*?"<>|]/g, '-') + '.pdf'), new Set());
        fs.writeFileSync(out, pdf);
        shell.showItemInFolder(out);
        return out;
      } finally { pdfWin.destroy(); }
    } catch { return null; } finally { fs.rmSync(temp, { recursive: true, force: true }); }
  },
  // Every chat as its own web page, plus an index page linking them all.
  'data:allChats': async ({ folder }) => {
    if (!data.result || !data.reader) return null;
    const title = bk.KINDS[data.kind].title, { uniquePath } = require('./core/shell');
    const root = uniquePath(path.join(folder, `${title} chats`), new Set());
    fs.mkdirSync(root, { recursive: true });
    const links = [];
    for (const g of data.result.groups) {
      const page = await data.reader.webPage(g, title, root);
      if (page) links.push([g.title, path.basename(page), g.rows.length]);
    }
    const esc = (t) => String(t).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    const items = links.map(([t, dir, n]) => `<li><a href="${encodeURI(dir)}/index.html">${esc(t)}</a> <span>${n} messages</span></li>`).join('');
    const index = path.join(root, 'index.html');
    fs.writeFileSync(index, `<!doctype html><meta charset=utf-8><title>${esc(title)} chats</title><style>body{font:15px -apple-system,Segoe UI,sans-serif;max-width:760px;margin:40px auto;padding:0 16px}li{margin:8px 0}span{color:#888;font-size:13px}</style><h1>${esc(title)} chats</h1><ul>${items}</ul>`);
    shell.showItemInFolder(index);
    return { saved: links.length, index };
  },
  // Contacts as a vCard file or calendars as an .ics file, ready to import anywhere.
  'data:standard': async ({ folder }) => {
    if (!data.reader || !['contacts', 'calendar'].includes(data.kind)) return null;
    const text = data.kind === 'contacts' ? await data.reader.vCard() : await data.reader.iCalendar();
    if (!text) return null;
    const out = require('./core/shell').uniquePath(path.join(folder, data.kind === 'contacts' ? 'Contacts.vcf' : 'Calendar.ics'), new Set());
    fs.writeFileSync(out, text);
    shell.showItemInFolder(out);
    return out;
  },
  // Every listed file (all folders) copied out of the backup.
  'data:extractAll': async ({ folder }) => {
    if (!data.result || !data.reader) return null;
    const groups = data.result.groups;
    let written = [], total = 0;
    for (const g of groups) {
      const target = groups.length > 1 ? path.join(folder, g.title.replace(/[\\/:*?"<>|]/g, '-')) : folder;
      fs.mkdirSync(target, { recursive: true });
      written = written.concat(await data.reader.extract(g, g.rows.map((_, i) => i), target));
      total += g.rows.length;
    }
    if (written.length) shell.showItemInFolder(written[0]);
    return { written: written.length, total };
  },
  'data:extract': async ({ id, rows, folder }) => {
    const g = data.result && data.result.groups.find((x) => x.id === id);
    if (!g || !data.reader) return null;
    const written = await data.reader.extract(g, rows, folder);
    if (written.length) shell.showItemInFolder(written[0]);
    return { written: written.length, total: rows.length };
  },

  // Android over Wi-Fi: pair once with the phone's code, then connect; the phone then shows up like a plugged-in one.
  'adb:wireless': async (args) => {
    const problem = await android.wireless(args || {}, tools || {});
    if (!problem) connect(true);
    return problem;
  },
  // Google does not allow its Android tool (adb) to be shipped inside other apps, so it is fetched from Google on request.
  'adb:setup': async () => {
    const name = WIN ? 'windows' : (process.platform === 'darwin' ? 'darwin' : 'linux');
    const dir = require('./core/shell').supportDir();
    const zip = path.join(dir, 'platform-tools.zip');
    try {
      fs.mkdirSync(dir, { recursive: true });
      const res = await fetch(`https://dl.google.com/android/repository/platform-tools-latest-${name}.zip`);
      if (!res.ok) return `Google's server answered with an error (${res.status}). Try again later.`;
      fs.writeFileSync(zip, Buffer.from(await res.arrayBuffer()));
      const r = WIN ? await run('powershell.exe', ['-NoProfile', '-Command', `Expand-Archive -LiteralPath '${zip.replace(/'/g, "''")}' -DestinationPath '${dir.replace(/'/g, "''")}' -Force`], { timeout: 180 })
        : await run('unzip', ['-o', '-q', zip, '-d', dir], { timeout: 180 });
      fs.rmSync(zip, { force: true });
      if (!r.ok) return 'The download finished but could not be unpacked.';
      if (WIN) {
        // Only keep the tools if adb.exe carries a valid Authenticode signature from Google (the Mac edition checks
        // Google's Apple signature the same way).
        const exe = path.join(dir, 'platform-tools', 'adb.exe');
        const sig = await run('powershell.exe', ['-NoProfile', '-Command',
          `$s = Get-AuthenticodeSignature -LiteralPath '${exe.replace(/'/g, "''")}'; "$($s.Status)|$($s.SignerCertificate.Subject)"`], { timeout: 60 });
        const [status, subject = ''] = (sig.output || '').trim().split('|');
        if (!sig.ok || status !== 'Valid' || !/O=Google LLC/i.test(subject)) {
          fs.rmSync(path.join(dir, 'platform-tools'), { recursive: true, force: true });
          return 'The download could not be confirmed as Google\'s own Android tools, so it was removed. Try again later.';
        }
      }
      tools = locateTools(process.resourcesPath, TEST);
      push();
      connect(true);
      return tools.adb ? null : 'The download finished but the Android tool was not found inside it.';
    } catch (e) { return `The download did not finish (${e.message}). Check the internet connection and try again.`; }
  },

  licences: () => {
    const packaged = path.join(process.resourcesPath, 'tools', 'licenses'), source = path.join(__dirname, 'tools-win', 'licenses');
    const p = fs.existsSync(packaged) ? packaged : source;
    if (fs.existsSync(p)) shell.openPath(p);
  },
  github: () => shell.openExternal('https://github.com/ARAVINDHRAJA123/porthop'),
  // The Apple Devices app in the Microsoft Store, which installs Apple's iPhone driver.
  store: () => shell.openExternal('ms-windows-store://pdp/?productid=9NP83LWLPZ9K'),

  // Updates: asks GitHub for the latest release (nothing else is sent) and offers its page when it is newer.
  'update:check': async () => {
    try {
      const r = await updates.latest();
      settings.lastUpdateCheck = Date.now(); saveSettings();
      S.update = !r.none && updates.isNewer(r.version, app.getVersion()) ? { version: r.version, url: r.url, notes: r.notes } : null;
      push();
      return S.update ? { ...S.update, current: app.getVersion() } : { upToDate: true, current: app.getVersion(), none: !!r.none };
    } catch (e) { return { error: e.message, current: app.getVersion() }; }
  },
  'update:auto': (v) => { if (typeof v === 'boolean') { settings.autoUpdateCheck = v; saveSettings(); } return settings.autoUpdateCheck !== false; },
  'update:open': () => { if (S.update) shell.openExternal(S.update.url); },
  wifi: (v) => { if (typeof v === 'boolean') { settings.includeWiFi = v; saveSettings(); connect(true); } return !!settings.includeWiFi; },
  // Light, dark or following Windows ('system'). The page's colours switch with it through prefers-color-scheme.
  appearance: (v) => {
    if (['system', 'light', 'dark'].includes(v)) { settings.appearance = v; saveSettings(); nativeTheme.themeSource = v; }
    return settings.appearance || 'system';
  },

  thumb: async (id) => {
    if (!S.device || isAndroid()) return null;
    const a = assetById(id);
    return a ? ios.thumbnail(a, S.device, tools, path.join(tempRoot, 'thumbs')) : null;
  },
};

function listDir(p) { return isAndroid() ? android.list(p, S.device, tools) : ios.list(p, browser.app, S.device, tools); }

// Device → computer for files and folders, never overwriting.
async function download(chosen, folder) {
  if (working() || !S.device || !chosen.length) return null;
  try { fs.mkdirSync(folder, { recursive: true }); } catch {}
  const job = startJob('transfer'), saved = [], reserved = new Set();
  try {
    for (let i = 0; i < chosen.length && !job.cancelled; i++) {
      const e = chosen[i];
      send('files:progress', `Copying ${i + 1} of ${chosen.length}: ${e.name}`);
      const dest = uniquePath(path.join(folder, e.name.replace(/[\\/:*?"<>|]/g, '-')), reserved);
      reserved.add(dest);
      const ok = isAndroid() ? await android.pull(e, dest, S.device, tools, job) : await ios.pull(e, dest, browser.app, S.device, tools, job);
      if (ok && !job.cancelled) saved.push(dest); else if (!e.isDirectory) fs.rmSync(dest, { force: true });
    }
    if (saved.length) shell.showItemInFolder(saved[0]);
    return { saved: saved.length, total: chosen.length, cancelled: job.cancelled };
  } finally { endJob('transfer'); }
}

// Months of a group, oldest to newest including empty ones, for the timeline strip. ts is in the catalog's own units.
function months(id) {
  const a = album(id);
  if (!a) return [];
  const counts = new Map();
  let lo = Infinity, hi = -Infinity;
  for (const x of a.assets) {
    if (!x.ts) continue;
    const d = new Date((x.ts + 978307200) * 1000), key = d.getFullYear() * 12 + d.getMonth();
    lo = Math.min(lo, key); hi = Math.max(hi, key);
    const v = counts.get(key) || [0, 0];
    v[x.isVideo ? 1 : 0]++;
    counts.set(key, v);
  }
  if (!(lo <= hi) || hi - lo > 1200) return [];
  const out = [];
  for (let k = lo; k <= hi; k++) {
    const s = new Date(Math.floor(k / 12), k % 12, 1), e = new Date(Math.floor(k / 12), k % 12 + 1, 1);
    const v = counts.get(k) || [0, 0];
    out.push({ key: k, label: s.toLocaleString(undefined, { month: 'short', year: 'numeric' }), photos: v[0], videos: v[1],
      from: s.getTime() / 1000 - 978307200, to: e.getTime() / 1000 - 978307200 - 1 });
  }
  return out;
}

// Places copies can go: the Pictures folder, each drive, and folders used before.
let driveCache = { at: 0, list: [] };
async function destinations() {
  if (Date.now() - driveCache.at > 10000) driveCache = { at: Date.now(), list: await drives() };
  const folder = `${(S.details && S.details.name) || 'Phone'} Photos`.replace(/[\\/:*?"<>|]/g, '-');
  const pictures = app.getPath('pictures');
  const out = [{ id: 'pictures', kind: 'pictures', name: 'Pictures', detail: 'This computer', path: path.join(pictures, folder), free: freeSpace(pictures) }];
  for (const d of driveCache.list) {
    out.push({ id: d.path, kind: 'drive', name: d.name, detail: d.format || 'Drive', path: path.join(d.path, folder), free: d.free,
      isFAT: /^FAT/i.test(d.format || '') });
  }
  for (const r of settings.recents || []) {
    if (out.filter((x) => x.kind === 'recent').length >= 3) break;
    if (!fs.existsSync(r) || out.some((x) => x.path === r)) continue;
    out.push({ id: 'recent:' + r, kind: 'recent', name: path.basename(r), detail: path.dirname(r), path: r });
  }
  return out;
}

function rememberDestination(p) {
  settings.recents = [p, ...(settings.recents || []).filter((x) => x !== p)].slice(0, 6);
  saveSettings();
}

// MARK: app

function createWindow() {
  win = new BrowserWindow({
    width: 1200, height: 780, minWidth: 940, minHeight: 600, backgroundColor: nativeTheme.shouldUseDarkColors ? '#070e1b' : '#f9f9ff', title: 'PortHop',
    autoHideMenuBar: true, show: false,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, sandbox: false,
      additionalArguments: TEST && env.PORTHOP_UI_TEST ? ['--porthop-ui-test=' + env.PORTHOP_UI_TEST] : [] },
  });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  win.once('ready-to-show', () => win.show());
  if (TEST && env.PORTHOP_SHOT) win.webContents.on('console-message', (e) => console.log('[page]', e.message, e.lineNumber));
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (e) => e.preventDefault());
}

app.whenReady().then(() => {
  loadSettings();
  nativeTheme.themeSource = (TEST && env.PORTHOP_APPEARANCE) || settings.appearance || 'system';
  bk.purgeTemp();
  if (WIN) { Menu.setApplicationMenu(null); app.setAppUserModelId('io.github.aravindhraja123.porthop'); }   // the ID lets notifications show
  for (const [name, fn] of Object.entries(handlers)) {
    ipcMain.handle(name, async (_e, arg) => {
      try { return await fn(arg); }
      catch (err) { console.error(name, err); throw new Error(err && err.message ? err.message : String(err)); }
    });
  }
  createWindow();
  connect(false);
  setInterval(poll, 3000);
  // At most once a week, and never in development runs.
  if (!TEST && settings.autoUpdateCheck !== false && Date.now() - (settings.lastUpdateCheck || 0) > 7 * 864e5) setTimeout(() => handlers['update:check'](), 20000);
  if (TEST && env.PORTHOP_SHOT) {
    setTimeout(async () => {
      if (env.PORTHOP_EVAL) { try { await win.webContents.executeJavaScript(env.PORTHOP_EVAL); } catch (e) { console.log('[page] eval', e.message); } await new Promise((r) => setTimeout(r, 1200)); }
      // Move the pointer off the page so no card shows its hover state in the picture.
      win.webContents.sendInputEvent({ type: 'mouseMove', x: 1, y: 1 });
      await new Promise((r) => setTimeout(r, 600));
      const img = await win.webContents.capturePage();
      fs.writeFileSync(env.PORTHOP_SHOT, img.toPNG());
      app.quit();
    }, Number(env.PORTHOP_SHOT_AFTER || 6) * 1000);
  }
});

app.on('window-all-closed', () => app.quit());
app.on('will-quit', () => {
  for (const j of Object.values(jobs)) if (j) j.cancel();
  if (data.reader) data.reader.close();
  bk.purgeTemp();
  fs.rmSync(tempRoot, { recursive: true, force: true });
});
