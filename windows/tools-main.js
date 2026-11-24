'use strict';
// The phone tools, main-process side: spyware check, apps, music and ringtones, the phone's screen (Android), sending a group
// straight to an Android phone, removing copied files from an Android phone, Wi-Fi backups, the phone report and updates.
const { app, dialog, shell, BrowserWindow, Notification } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { run } = require('./core/shell');
const android = require('./core/android');
const bk = require('./core/backup');
const spyware = require('./core/spyware');
const apps = require('./core/apps');
const music = require('./core/music');
const cleanup = require('./core/cleanup');
const report = require('./core/report');
const updates = require('./core/updates');
const { exportAssets } = require('./core/exporter');

module.exports = function phoneTools(ctx) {
  const { S, send, push, startJob, endJob, working, isAndroid, backupFolder, tempRoot, jobs } = ctx;
  const tools = () => ctx.tools();
  const settings = () => ctx.settings();
  const peer = () => S.devices.find((d) => d.kind === 'android' && !d.unauthorized && (!S.device || d.udid !== S.device.udid)) || null;
  const pad = (n) => String(n).padStart(2, '0');
  const stamp = () => { const d = new Date(); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} at ${pad(d.getHours())}.${pad(d.getMinutes())}.${pad(d.getSeconds())}`; };
  const safe = (s) => String(s || '').replace(/[\\/:*?"<>|\u0000-\u001f]/g, '-').trim().replace(/[. ]+$/, '');

  /// Saves a web page as a PDF (or as the page itself when the name ends in .html).
  async function savePage(html, defaultName) {
    const r = await dialog.showSaveDialog(ctx.win(), { defaultPath: path.join(app.getPath('documents'), defaultName),
      filters: [{ name: 'PDF', extensions: ['pdf'] }, { name: 'Web page', extensions: ['html'] }] });
    if (r.canceled || !r.filePath) return null;
    if (r.filePath.toLowerCase().endsWith('.html')) fs.writeFileSync(r.filePath, html);
    else {
      const page = path.join(fs.mkdtempSync(path.join(tempRoot, 'page-')), 'page.html');
      fs.writeFileSync(page, html);
      const w = new BrowserWindow({ show: false, webPreferences: { sandbox: true, javascript: false } });
      try { await w.loadFile(page); fs.writeFileSync(r.filePath, await w.webContents.printToPDF({ printBackground: true, margins: { marginType: 'default' } })); }
      finally { w.destroy(); fs.rmSync(path.dirname(page), { recursive: true, force: true }); }
    }
    shell.showItemInFolder(r.filePath);
    return r.filePath;
  }

  async function pickFile(name, extensions) {
    const r = await dialog.showOpenDialog(ctx.win(), { properties: ['openFile'], filters: [{ name, extensions }] });
    return r.canceled ? null : r.filePaths[0] || null;
  }
  async function pickFolder(title) {
    const r = await dialog.showOpenDialog(ctx.win(), { title, properties: ['openDirectory', 'createDirectory'] });
    return r.canceled ? null : r.filePaths[0] || null;
  }

  // MARK: spyware check
  let lastSpy = null;
  const newestBackup = () => {
    if (!S.device) return null;
    return bk.existing(backupFolder()).filter((b) => path.basename(b.path) === S.device.udid && b.date && !b.isSnapshot)
      .sort((a, b) => new Date(b.date) - new Date(a.date))[0] || null;
  };

  // MARK: the phone's screen (Android): adb streams H.264 from the phone's own encoder; the page decodes and shows it.
  let screen = null;
  async function smallerSize() {
    const m = String((await android.shell('wm size', S.device, tools())) || '').match(/(\d+)x(\d+)/);
    if (!m) return '720x1280';
    const w = Number(m[1]), h = Number(m[2]), scale = Math.min(1, 1280 / Math.max(w, h));
    return `${Math.floor(w * scale / 2) * 2}x${Math.floor(h * scale / 2) * 2}`;
  }
  function launch() {
    const s = screen;
    if (!s || s.stopped) return;
    const child = spawn(tools().adb, [...android.args(S.device), 'exec-out', 'screenrecord', '--output-format=h264', '--bit-rate', '8000000',
      ...(s.size ? ['--size', s.size] : []), '-'], { windowsHide: true });
    const r = { child, frames: false, started: Date.now() };
    s.run = r;
    child.stdout.on('data', (d) => { r.frames = true; send('screen:data', d); });
    child.on('error', () => {});
    child.on('close', async () => {
      if (screen !== s || s.stopped || s.run !== r) return;
      if (r.frames) return launch();   // screenrecord stops by itself after three minutes; carry on seamlessly
      if (!s.size && Date.now() - r.started < 8000) { s.size = await smallerSize(); return launch(); }   // some phones refuse full resolution
      s.stopped = true;
      send('screen:end', 'The phone did not send its screen. Unlock it and try again; Android 10 or later is needed.');
    });
  }
  const sizes = new Map();
  async function point(x, y, w, h) {
    let real = sizes.get(S.device.udid);
    if (!real) {
      const text = String((await android.shell('wm size', S.device, tools())) || '');
      const line = text.split('\n').reverse().find((l) => l.includes('Override')) || text.split('\n').find((l) => l.includes('Physical')) || '';
      const m = line.match(/(\d+)x(\d+)/);
      real = m ? { w: Number(m[1]), h: Number(m[2]) } : { w, h };
      sizes.set(S.device.udid, real);
    }
    if ((w > h) !== (real.w > real.h)) real = { w: real.h, h: real.w };
    const c = (v) => Math.min(Math.max(Number(v) || 0, 0), 1);
    return [Math.round(c(x) * real.w), Math.round(c(y) * real.h)];
  }

  // MARK: Wi-Fi backups: every ten minutes while the setting is on, an iPhone that was backed up here before, now on the same
  // Wi-Fi and not on USB, gets its daily backup over Wi-Fi. The window keeps showing whatever it showed.
  let wifiTimer = null;
  const wifiTried = new Map();   // when each iPhone was last tried, so a backup that can't finish isn't retried every ten minutes
  function startWiFiWatch() {
    if (wifiTimer) clearInterval(wifiTimer);
    wifiTimer = null;
    if (!settings().wifiBackup || ctx.test) return;
    wifiTimer = setInterval(checkWiFiBackups, 10 * 60 * 1000);
  }
  async function checkWiFiBackups() {
    const t = tools();
    if (!t || !t.backup || !t.ideviceId || working()) return;
    const online = ((await run(t.ideviceId, ['-n'], { timeout: 10 })).output || '').split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.includes(' '));
    const usb = new Set(S.devices.filter((d) => !d.isNetwork).map((d) => d.udid));
    const known = bk.existing(backupFolder());
    for (const udid of online) {
      if (usb.has(udid)) continue;
      const last = Math.max(0, ...known.filter((b) => path.basename(b.path) === udid && b.date).map((b) => new Date(b.date).getTime()));
      if (!last || Date.now() - last < 20 * 3600 * 1000) continue;
      if (Date.now() - (wifiTried.get(udid) || 0) < 6 * 3600 * 1000) continue;
      wifiTried.set(udid, Date.now());
      const job = startJob('backup');
      try {
        const problem = await bk.runBackup({ udid, isNetwork: true, kind: 'ios' }, t, backupFolder(), job, () => {});
        if (Notification.isSupported()) new Notification({ title: problem ? "The Wi-Fi backup didn't finish" : 'Backed up over Wi-Fi', body: problem || `${S.names[udid] || 'Your iPhone'} is backed up.` }).show();
      } finally { endJob('backup'); push(); }
      return;
    }
  }
  startWiFiWatch();

  let songs = [];

  return {
    handlers: {
      // Spyware check
      'spy:sources': () => spyware.sources(),
      'spy:download': async () => ({ problem: await spyware.download(), sources: spyware.sources() }),
      'spy:add': async () => {
        const file = await pickFile('Indicator files (STIX2)', ['stix2', 'json']);
        return file ? { problem: spyware.addFile(file), sources: spyware.sources() } : null;
      },
      'spy:backup': () => { const b = newestBackup(); return b ? { date: b.date, encrypted: !!b.encrypted } : null; },
      'spy:check': async ({ password } = {}) => {
        const set = spyware.load();
        if (set.isEmpty) return { message: 'Download the indicators first.' };
        if (!S.device || !S.details) return { message: 'Connect a phone first.' };
        if (isAndroid()) {
          lastSpy = { report: await spyware.scanAndroid(S.device, tools(), set), device: S.details.name, source: 'checked live over USB' };
          return lastSpy;
        }
        const entry = newestBackup();
        if (!entry) return { message: `Make a backup of ${S.details.name} first: the check reads the backup, so nothing on the iPhone changes.` };
        const o = await bk.BackupReader.open(entry.path, password || null);
        if (o.needsPassword) return { needsPassword: true, message: 'This backup is encrypted. Enter its password to check it.' };
        if (o.wrongPassword) return { needsPassword: true, message: "That password didn't open the backup." };
        if (!o.reader) return { message: 'The backup could not be opened. Make a new one and try again.' };
        try {
          lastSpy = { report: await spyware.scanBackup(o.reader, set), device: S.details.name, source: `from the backup made ${new Date(entry.date).toLocaleString()}` };
          return lastSpy;
        } finally { o.reader.close(); }
      },
      'spy:save': async () => (lastSpy ? savePage(spyware.html(lastSpy.report, lastSpy.device, lastSpy.source), `Spyware check ${safe(lastSpy.device)}.pdf`) : null),
      'report:phone': async () => (S.details ? savePage(report.phoneReport(S.details, isAndroid()), `${safe(S.details.name)} report.pdf`) : null),

      // Apps
      'apps:list': async () => (S.device ? apps.list(S.device, tools()) : null),
      'apps:install': async () => {
        if (!S.device || working()) return null;
        const file = await pickFile(isAndroid() ? 'Android app' : 'iPhone app signed for this iPhone', [isAndroid() ? 'apk' : 'ipa']);
        if (!file) return null;
        const job = startJob('transfer');
        try {
          const problem = await apps.install(file, S.device, tools(), (p) => send('apps:progress', p));
          return { problem, name: path.basename(file, path.extname(file)), list: await apps.list(S.device, tools()) };
        } finally { endJob('transfer'); }
      },
      'apps:remove': async (id) => (S.device && !working() ? { problem: await apps.uninstall(String(id), S.device, tools()) } : null),

      // Music and ringtones (iPhone)
      'music:list': async () => {
        if (!S.device || isAndroid()) return null;
        const r = await music.load(S.device, tools());
        songs = r.songs;
        return r;
      },
      'music:copy': async ({ ids } = {}) => {
        if (!S.device || isAndroid() || working()) return null;
        const folder = await pickFolder('Choose where the songs go (Artist › Album folders)');
        if (!folder) return null;
        const chosen = ids ? songs.filter((s) => ids.includes(s.id)) : songs;
        const job = startJob('transfer');
        try {
          const o = await music.copy(chosen, folder, S.device, tools(), job, (n, total, title) => send('music:progress', `Copying ${n + 1} of ${total}: ${title}`));
          if (o.copied) shell.openPath(folder);
          return o;
        } finally { endJob('transfer'); }
      },
      'music:send': async ({ ids } = {}) => {
        const phone = peer();
        if (!S.device || isAndroid() || !phone || working()) return null;
        const chosen = ids ? songs.filter((s) => ids.includes(s.id)) : songs;
        const job = startJob('transfer');
        try { return { ...(await music.send(chosen, S.device, phone, tools(), job, (n, total, title) => send('music:progress', `Sending ${n + 1} of ${total}: ${title}`))), to: S.names[phone.udid] || 'the Android phone' }; }
        finally { endJob('transfer'); }
      },
      'music:stop': () => { if (jobs.transfer) jobs.transfer.cancel(); },
      // A ringtone made in the window (AAC, .m4r): saved where the user says, and put on the Android phone when asked.
      'music:saveTone': async ({ data, name, toAndroid }) => {
        const r = await dialog.showSaveDialog(ctx.win(), { defaultPath: path.join(app.getPath('music'), `${safe(name) || 'Ringtone'}.m4r`), filters: [{ name: 'Ringtone', extensions: ['m4r'] }] });
        if (r.canceled || !r.filePath) return null;
        fs.writeFileSync(r.filePath, Buffer.from(data));
        let sent = null;
        const phone = toAndroid ? (isAndroid() ? S.device : peer()) : null;
        if (phone) {
          const dir = android.ROOT + '/Ringtones', existing = new Set((await android.list(dir, phone, tools())).map((e) => e.name));
          sent = await android.mkdirs(dir, phone, tools()) && await android.push(r.filePath, dir, existing, phone, tools(), null);
          if (sent) await android.scan([`${dir}/${path.basename(r.filePath)}`], phone, tools());
        }
        shell.showItemInFolder(r.filePath);
        return { path: r.filePath, sent };
      },

      // The phone's screen
      'screen:start': (session) => {
        if (screen) { screen.stopped = true; if (screen.run) screen.run.child.kill(); }
        screen = null;
        if (!S.device || !isAndroid() || !tools().adb) return { error: "Seeing an iPhone's screen needs a Mac (macOS shows it like a camera). On Windows this works with Android phones." };
        screen = { stopped: false, size: null, session };
        launch();
        return { ok: true };
      },
      // Restarting the stream makes it begin with a whole picture at once, so a recording can start without waiting.
      'screen:restart': () => { if (screen && screen.run) screen.run.child.kill(); },
      // Only the page that started this stream can stop it (a page being replaced must not stop its successor's).
      'screen:stop': (session) => { if (screen && screen.session === session) { screen.stopped = true; if (screen.run) screen.run.child.kill(); screen = null; } },
      'screen:shot': async () => {
        if (!S.device || !isAndroid() || !tools().adb) return null;
        const dir = path.join(app.getPath('pictures'), 'PortHop');
        fs.mkdirSync(dir, { recursive: true });
        const out = path.join(dir, `Screenshot ${stamp()}.png`);
        const ok = await new Promise((resolve) => {
          const child = spawn(tools().adb, [...android.args(S.device), 'exec-out', 'screencap', '-p'], { windowsHide: true });
          const file = fs.createWriteStream(out);
          child.stdout.pipe(file);
          child.on('error', () => resolve(false));
          child.on('close', (code) => file.end(() => resolve(code === 0)));
        });
        let png = false;
        try { png = fs.readFileSync(out).subarray(0, 4).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47])); } catch {}
        if (!ok || !png) { fs.rmSync(out, { force: true }); return null; }
        shell.showItemInFolder(out);
        return out;
      },
      'screen:tap': async ({ x, y, w, h }) => { if (isAndroid()) { const [a, b] = await point(x, y, w, h); await android.shell(`input tap ${a} ${b}`, S.device, tools()); } },
      'screen:swipe': async ({ x1, y1, x2, y2, w, h }) => {
        if (!isAndroid()) return;
        const [a, b] = await point(x1, y1, w, h), [c, d] = await point(x2, y2, w, h);
        await android.shell(`input swipe ${a} ${b} ${c} ${d} 250`, S.device, tools());
      },
      'screen:key': async (code) => { if (isAndroid() && [3, 4, 187].includes(Number(code))) await android.shell(`input keyevent ${Number(code)}`, S.device, tools()); },
      'screen:save': ({ data, ext }) => {
        const dir = path.join(app.getPath('videos'), 'PortHop');
        fs.mkdirSync(dir, { recursive: true });
        const out = path.join(dir, `Screen Recording ${stamp()}.${ext === 'mp4' ? 'mp4' : 'webm'}`);
        fs.writeFileSync(out, Buffer.from(data));
        shell.showItemInFolder(out);
        return out;
      },

      // A group from the iPhone straight to the Android phone plugged in next to it.
      'hop:android': async ({ query, ids, options, albumName }) => {
        const phone = peer();
        if (!phone || working() || !S.device || isAndroid()) return null;
        let assets = ctx.rowsFor(query);
        if (ids) { const set = new Set(ids); assets = assets.filter((a) => set.has(a.id)); }
        const job = startJob('export');
        const staging = fs.mkdtempSync(path.join(tempRoot, 'hop-'));
        let last = 0;
        try {
          const summary = await exportAssets({ assets, dest: staging, options: { ...options, saveReport: false, skipExisting: false, albumName, deviceName: S.details ? S.details.name : '' },
            device: S.device, tools: tools(), job, onProgress: (p) => { const now = Date.now(); if (now - last > 200) { last = now; send('export:progress', p); } } });
          const folderName = safe(albumName) || 'From iPhone';
          const sent = await android.sendFolder(staging, `${android.ROOT}/DCIM/PortHop/${folderName}`, phone, tools(), job,
            (done, total) => send('export:progress', { total, copied: done, skipped: 0, failed: 0, inFlight: 1, bytesDone: 0, bytesTotal: 0, sending: true }));
          Object.assign(summary, { sentTo: `${S.names[phone.udid] || 'Android phone'} › DCIM/PortHop/${folderName}`, sentCount: sent.sent, sentAlready: sent.already,
            sendFailures: sent.failed, failedIds: summary.failures.map((f) => f.id), cancelled: summary.cancelled || job.cancelled });
          return summary;
        } finally { endJob('export'); fs.rmSync(staging, { recursive: true, force: true }); push(); }
      },

      // After Android folders were copied: removes from the phone the files whose copy matches.
      'android:removeCopied': async () => {
        if (!isAndroid() || !(S.androidCopied || []).length || working()) return null;
        const job = startJob('transfer');
        try {
          const sure = await cleanup.androidConfirmed(S.androidCopied, S.device, tools());
          const gone = await android.remove(sure.map((e) => e.path), S.device, tools());
          S.androidCopied = [];
          push();
          return { removed: gone.length };
        } finally { endJob('transfer'); }
      },

      // Wi-Fi backups: PortHop's daily check and the iPhone's own "Show this iPhone when on Wi-Fi" setting.
      'backup:wifi': async (v) => {
        if (typeof v === 'boolean') {
          settings().wifiBackup = v;
          ctx.saveSettings();
          if (v && S.device && !isAndroid()) await apps.wifiSync(S.device, tools(), true);
          startWiFiWatch();
        }
        return { on: !!settings().wifiBackup, phone: S.device && !isAndroid() ? await apps.wifiSync(S.device, tools()) : null };
      },

      // Installs the update found by update:check, after checking its signature; PortHop then closes so it can finish.
      'update:install': async () => {
        if (!S.update) return null;
        if (working()) return { error: 'PortHop restarts to install the update. Wait for the current copy or backup to finish, or stop it, then try again.' };
        const r = await updates.install(S.update, path.dirname(process.execPath), (s) => send('update:status', s));
        if (r.restart) setTimeout(() => app.quit(), 400);
        return r;
      },
    },
    peer,
    canInstallUpdate: () => !!(S.update && process.platform === 'win32' && updates.publicKey(path.dirname(process.execPath))
      && (fs.existsSync(path.join(path.dirname(process.execPath), 'unins000.exe')) ? updates.windowsAssets(S.update).setup : updates.windowsAssets(S.update).zip)),
  };
};
