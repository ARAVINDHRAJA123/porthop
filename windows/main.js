'use strict';
const { app, BrowserWindow, ipcMain, dialog, shell, Menu } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { run, Job, locateTools, fileSize, uniquePath, bytes, WIN } = require('./core/shell');
const ios = require('./core/ios');
const android = require('./core/android');
const { loadCatalog, view } = require('./core/catalog');
const { exportAssets } = require('./core/exporter');
const bk = require('./core/backup');

const env = process.env;
let win = null;
let tools = null;
const S = {
  phase: 'searching', message: '', devices: [], names: {}, device: null, details: null,
  smart: [], user: [], warnings: [], apps: [], busy: false, preferred: null,
};
const jobs = { export: null, transfer: null, backup: null };
const browser = { app: null, root: '/', path: '/', entries: [] };
let data = { reader: null, kind: null, result: null, password: env.PAE_BACKUP_PASSWORD || null, source: '' };
const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'PhoneAlbumExtractor-'));

// MARK: settings

const settingsFile = () => path.join(app.getPath('userData'), 'settings.json');
let settings = {};
function loadSettings() { try { settings = JSON.parse(fs.readFileSync(settingsFile(), 'utf8')); } catch { settings = {}; } }
function saveSettings() { try { fs.mkdirSync(path.dirname(settingsFile()), { recursive: true }); fs.writeFileSync(settingsFile(), JSON.stringify(settings)); } catch {} }
const backupFolder = () => env.PAE_BACKUP_DIR || settings.backupFolder || path.join(app.getPath('documents'), 'Phone Backups');

// MARK: connection

const isAndroid = () => S.device && S.device.kind === 'android';
const working = () => !!(jobs.export || jobs.transfer || jobs.backup);
const albums = () => [...S.smart, ...S.user];
const album = (id) => albums().find((a) => a.id === id);

function snapshot() {
  const al = (a) => ({ id: a.id, title: a.title, smart: a.smart, count: a.assets.length, bytes: a.assets.reduce((n, x) => n + Math.max(0, x.fileSize), 0) });
  return {
    phase: S.phase, message: S.message, device: S.device, devices: S.devices.map((d) => ({ ...d, name: S.names[d.udid] || 'Device' })),
    details: S.details, smart: S.smart.map(al), user: S.user.map(al), warnings: S.warnings, apps: S.apps,
    hasAdb: !!(tools && tools.adb), hasApple: !!(tools && tools.hasApple), canPower: !!(tools && (isAndroid() ? tools.adb : tools.diagnostics)),
    canBackup: !!(tools && tools.backup), isWindows: WIN, backupFolder: backupFolder(),
  };
}
function push() { if (win && !win.isDestroyed()) win.webContents.send('state', snapshot()); }
function send(channel, payload) { if (win && !win.isDestroyed()) win.webContents.send(channel, payload); }

function reset(phase, message = '') {
  S.device = null; S.details = null; S.smart = []; S.user = []; S.warnings = []; S.apps = [];
  S.phase = phase; S.message = message;
  push();
}

async function allDevices() { return [...await ios.findDevices(tools), ...await android.findDevices(tools)]; }
const label = (d) => (d.kind === 'android' ? android.name(d, tools) : ios.name(d, tools));

async function connect(silent) {
  if (S.busy || working()) return;
  S.busy = true;
  try {
    if (!silent) { S.phase = 'searching'; push(); }
    tools = locateTools(process.resourcesPath);
    if (!tools.hasApple && !tools.adb) return reset('toolsMissing');
    const found = await allDevices();
    S.devices = found;
    const device = found.find((d) => d.udid === S.preferred) || found[0];
    if (!device) return reset('noDevice');
    if (found.length > 1) for (const d of found) S.names[d.udid] = await label(d);
    if (device.kind === 'android') {
      const info = device.unauthorized ? null : await android.details(device, tools);
      if (!info) return reset('needsTrust', device.unauthorized ? 'Unlock the Android device and tap Allow on the “Allow USB debugging?” message.'
        : 'The Android device is connected but did not answer. Unlock it and keep it plugged in.');
      S.device = device; S.details = info; S.names[device.udid] = info.name;
      S.smart = []; S.user = []; S.warnings = []; S.apps = [];
      S.phase = 'ready'; push();
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
    const cat = loadCatalog(db);
    fs.rmSync(dir, { recursive: true, force: true });
    if (cat.error) {
      S.phase = 'catalogError';
      S.message = cat.error === 'unreadable' ? 'The photo database was copied from the device but could not be opened. Try Refresh with the device unlocked.'
        : `${info.osName} ${info.osVersion} stores its photo library in a format this app does not understand yet. ${cat.why}`;
      return push();
    }
    S.device = device; S.names[device.udid] = info.name;
    S.smart = cat.smart; S.user = cat.user; S.warnings = cat.warnings;
    S.phase = 'ready'; push();
    ios.apps(device, tools).then((list) => { if (S.device === device) { S.apps = list; push(); } });
  } finally { S.busy = false; }
}

async function poll() {
  if (S.busy || working()) return;
  if (['noDevice', 'needsTrust', 'toolsMissing'].includes(S.phase)) return connect(true);
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
  reveal: (p) => { if (fs.existsSync(p)) { if (fs.statSync(p).isDirectory()) shell.openPath(p); else shell.showItemInFolder(p); } },
  copy: (text) => { require('electron').clipboard.writeText(String(text)); },

  'export:start': async ({ query, ids, dest, options }) => {
    if (working() || !S.device || isAndroid()) return null;
    let assets = rowsFor(query);
    if (ids) { const set = new Set(ids); assets = assets.filter((a) => set.has(a.id)); }
    const job = jobs.export = new Job();
    let last = 0;
    try {
      const summary = await exportAssets({ assets, dest, options, device: S.device, tools, job,
        onProgress: (p) => { const now = Date.now(); if (now - last > 200) { last = now; send('export:progress', p); } } });
      summary.failedIds = summary.failures.map((f) => f.id);
      return summary;
    } finally { jobs.export = null; }
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
    const job = jobs.transfer = new Job(), dir = browser.path, existing = new Set(browser.entries.map((e) => e.name));
    let added = 0;
    try {
      for (let i = 0; i < paths.length && !job.cancelled; i++) {
        send('files:progress', `Adding ${i + 1} of ${paths.length}: ${path.basename(paths[i])}`);
        const ok = isAndroid() ? await android.push(paths[i], dir, existing, S.device, tools, job) : await ios.put(paths[i], dir, existing, browser.app, S.device, tools, job);
        if (ok) added++;
      }
      browser.entries = await listDir(dir);
      return { added, total: paths.length, cancelled: job.cancelled, entries: browser.entries };
    } finally { jobs.transfer = null; }
  },
  'files:download': async ({ paths, folder }) => {
    const chosen = browser.entries.filter((e) => paths.includes(e.path));
    if (working() || !S.device || !chosen.length) return null;
    const job = jobs.transfer = new Job(), saved = [], reserved = new Set();
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
    } finally { jobs.transfer = null; }
  },
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
    return isAndroid() ? android.power(action, S.device, tools) : ios.power(action, S.device, tools);
  },

  'backup:list': () => bk.existing(backupFolder()),
  'backup:folder': (p) => { settings.backupFolder = p; saveSettings(); push(); return bk.existing(p); },
  'backup:start': async () => {
    if (working() || !S.device || isAndroid()) return 'Connect an iPhone or iPad first.';
    const job = jobs.backup = new Job();
    let last = 0;
    try {
      return await bk.runBackup(S.device, tools, backupFolder(), job, (percent, phase) => {
        const now = Date.now(); if (now - last > 250) { last = now; send('backup:progress', { percent, phase }); }
      });
    } finally { jobs.backup = null; }
  },
  'backup:restore': async ({ path: folder, password }) => {
    if (working() || !S.device || isAndroid()) return 'Connect an iPhone or iPad first.';
    const entry = bk.existing(backupFolder()).find((b) => b.path === folder);
    if (!entry) return 'That backup is no longer in the folder.';
    const job = jobs.backup = new Job();
    let last = 0;
    try {
      return await bk.runRestore(entry, S.device, tools, password || null, job, (percent, phase) => {
        const now = Date.now(); if (now - last > 250) { last = now; send('backup:progress', { percent, phase }); }
      });
    } finally { jobs.backup = null; }
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
  'data:extract': async ({ id, rows, folder }) => {
    const g = data.result && data.result.groups.find((x) => x.id === id);
    if (!g || !data.reader) return null;
    const written = await data.reader.extract(g, rows, folder);
    if (written.length) shell.showItemInFolder(written[0]);
    return { written: written.length, total: rows.length };
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
      tools = locateTools(process.resourcesPath);
      push();
      connect(true);
      return tools.adb ? null : 'The download finished but the Android tool was not found inside it.';
    } catch (e) { return `The download did not finish (${e.message}). Check the internet connection and try again.`; }
  },

  thumb: async (id) => {
    if (!S.device || isAndroid()) return null;
    const a = albums().flatMap((x) => x.assets).find((x) => x.id === id);
    return a ? ios.thumbnail(a, S.device, tools, path.join(tempRoot, 'thumbs')) : null;
  },
};

function listDir(p) { return isAndroid() ? android.list(p, S.device, tools) : ios.list(p, browser.app, S.device, tools); }

// MARK: app

function createWindow() {
  win = new BrowserWindow({
    width: 1200, height: 780, minWidth: 940, minHeight: 600, backgroundColor: '#17161b', title: 'Phone Album Extractor',
    autoHideMenuBar: true, show: false,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, sandbox: false },
  });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  win.once('ready-to-show', () => win.show());
  if (env.PAE_SHOT) win.webContents.on('console-message', (e) => console.log('[page]', e.message, e.lineNumber));
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (e) => e.preventDefault());
}

app.whenReady().then(() => {
  loadSettings();
  bk.purgeTemp();
  if (WIN) Menu.setApplicationMenu(null);
  for (const [name, fn] of Object.entries(handlers)) ipcMain.handle(name, (_e, arg) => fn(arg));
  createWindow();
  connect(false);
  setInterval(poll, 3000);
  if (env.PAE_SHOT) {
    setTimeout(async () => {
      if (env.PAE_EVAL) { try { await win.webContents.executeJavaScript(env.PAE_EVAL); } catch (e) { console.log('[page] eval', e.message); } await new Promise((r) => setTimeout(r, 1200)); }
      const img = await win.webContents.capturePage();
      fs.writeFileSync(env.PAE_SHOT, img.toPNG());
      app.quit();
    }, Number(env.PAE_SHOT_AFTER || 6) * 1000);
  }
});

app.on('window-all-closed', () => app.quit());
app.on('will-quit', () => {
  for (const j of Object.values(jobs)) if (j) j.cancel();
  if (data.reader) data.reader.close();
  bk.purgeTemp();
  fs.rmSync(tempRoot, { recursive: true, force: true });
});
