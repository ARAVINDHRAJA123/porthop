'use strict';
// Runs the bundled device tools. Nothing here talks to the network.
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const WIN = process.platform === 'win32';

function run(cmd, args, opts = {}) {
  return new Promise((resolve) => {
    let child;
    try { child = spawn(cmd, args, { windowsHide: true, env: opts.env ? { ...process.env, ...opts.env } : process.env }); }
    catch { return resolve({ ok: false, code: -1, output: '' }); }
    const chunks = [];
    let done = false, timer = null;
    const finish = (code) => {
      if (done) return;
      done = true;
      if (timer) clearTimeout(timer);
      resolve({ ok: code === 0, code, output: Buffer.concat(chunks).toString('utf8') });
    };
    child.stdout.on('data', (d) => { chunks.push(d); if (opts.onOutput) opts.onOutput(d.toString('utf8')); });
    child.stderr.on('data', (d) => { chunks.push(d); if (opts.onOutput) opts.onOutput(d.toString('utf8')); });
    child.on('error', () => finish(-1));
    child.on('close', (code) => finish(code ?? -1));
    child.stdin.on('error', () => {});
    if (opts.stdin != null) child.stdin.write(opts.stdin);
    child.stdin.end();
    if (opts.onStart) opts.onStart(child);
    if (opts.timeout) timer = setTimeout(() => { try { child.kill(); } catch {} finish(-2); }, opts.timeout * 1000);
  });
}

/// A cancellable piece of work: remembers the tool processes it started so Stop can end them.
class Job {
  constructor() { this.cancelled = false; this.children = new Set(); }
  track(child) {
    this.children.add(child);
    child.on('close', () => this.children.delete(child));
    if (this.cancelled) this.killAll();
  }
  killAll() { for (const c of this.children) { try { c.kill(); } catch {} } }
  cancel() { this.cancelled = true; this.killAll(); }
}

function exe(name) { return WIN ? name + '.exe' : name; }

function supportDir() {
  const base = WIN ? (process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'))
    : path.join(os.homedir(), 'Library', 'Application Support');
  return path.join(base, 'PortHop');
}
/// Where versions before 2.1 kept the Android tools; still looked in.
function legacySupportDir() { return path.join(path.dirname(supportDir()), 'PhoneAlbumExtractor'); }

function locateTools(resourcesDir, allowOverride = true) {
  const dirs = [];
  if (allowOverride && process.env.PHONE_TOOLS_DIR) dirs.push(process.env.PHONE_TOOLS_DIR);
  if (resourcesDir) dirs.push(path.join(resourcesDir, 'tools'));
  dirs.push(path.join(__dirname, '..', 'tools'));
  dirs.push(path.join(supportDir(), 'platform-tools'), path.join(legacySupportDir(), 'platform-tools'));
  if (!WIN) dirs.push('/opt/homebrew/bin', '/usr/local/bin');
  for (const d of (process.env.PATH || '').split(path.delimiter)) if (d) dirs.push(d);
  const find = (name) => {
    for (const d of dirs) {
      const p = path.join(d, exe(name));
      try { fs.accessSync(p, fs.constants.X_OK); return p; } catch {}
    }
    return null;
  };
  return {
    ideviceId: find('idevice_id'), ideviceInfo: find('ideviceinfo'), afc: find('afcclient'),
    applist: find('applist'), installer: find('ideviceinstaller'), backup: find('idevicebackup2'),
    diagnostics: find('idevicediagnostics'), adb: find('adb'),
    get hasApple() { return !!(this.ideviceId && this.ideviceInfo && this.afc); },
  };
}

function fileSize(p) { try { return fs.statSync(p).size; } catch { return 0; } }

/// A name that does not exist yet: "name (2).ext", "name (3).ext"…
function uniquePath(preferred, reserved = new Set()) {
  if (!fs.existsSync(preferred) && !reserved.has(preferred)) return preferred;
  const dir = path.dirname(preferred), ext = path.extname(preferred), base = path.basename(preferred, ext);
  for (let i = 2; ; i++) {
    const c = path.join(dir, `${base} (${i})${ext}`);
    if (!fs.existsSync(c) && !reserved.has(c)) return c;
  }
}

function bytes(n) {
  if (!(n > 0)) return '—';
  const u = ['bytes', 'KB', 'MB', 'GB', 'TB'];
  let i = 0, v = n;
  while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
  return (i === 0 ? String(v) : v.toFixed(v >= 100 ? 0 : v >= 10 ? 1 : 2)) + ' ' + u[i];
}

module.exports = { run, Job, exe, WIN, supportDir, locateTools, fileSize, uniquePath, bytes };
