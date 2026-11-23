'use strict';
// Copies photos and videos off an iPhone or iPad. Files land in a hidden staging folder first and are moved
// into place only after their size is confirmed, so a stopped or unplugged copy never leaves a broken file.
// Nothing in the destination is ever overwritten, and nothing on the device is changed.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { run, fileSize } = require('./shell');
const ios = require('./ios');
const { APPLE_EPOCH, dateText } = require('./catalog');
const location = require('./location');

const MANIFEST = '.porthop-manifest.json';
const STAGING = '.porthop-staging-';
// What versions before 2.1 used; the old record is still read (never written) and old staging folders are cleared.
const LEGACY_MANIFEST = '.iPhoneAlbumExtractor-manifest.json', LEGACY_STAGING = '.iPhoneAlbumExtractor-staging-';
const CHUNK = 60, STREAMS = 3;

const os = require('node:os');

// Folder and file-name patterns, the same tokens and rules as the Mac (Tests/golden/patterns.json checks both).
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const TOKENS = '{year} {month} {monthName} {day} {hour} {minute} {second} {album} {folder} {device} {kind} {name}';
/// One folder or file name, safe on Windows, Mac and exFAT drives alike.
const safePart = (s) => String(s).replace(/[\\/:*?"<>|\x00-\x1f]/g, '-').trim().replace(/[. ]+$/, '');
function render(pattern, a, album, device, name) {
  const d = a.ts ? new Date((a.ts + APPLE_EPOCH) * 1000) : null;
  const two = (n) => String(n).padStart(2, '0');
  const values = { '{year}': d ? String(d.getFullYear()) : 'Unknown', '{month}': d ? two(d.getMonth() + 1) : 'Unknown',
    '{monthName}': d ? MONTHS[d.getMonth()] : 'Unknown', '{day}': d ? two(d.getDate()) : 'Unknown',
    '{hour}': d ? two(d.getHours()) : 'Unknown', '{minute}': d ? two(d.getMinutes()) : 'Unknown', '{second}': d ? two(d.getSeconds()) : 'Unknown',
    '{album}': album || 'Photos', '{folder}': path.posix.basename(a.directory || '') || 'DCIM', '{device}': device || 'iPhone',
    '{kind}': a.isVideo ? 'Videos' : a.isScreenshot ? 'Screenshots' : 'Photos', '{name}': name || '' };
  let out = String(pattern || '');
  for (const [k, v] of Object.entries(values)) if (out.includes(k)) out = out.split(k).join(String(v).replace(/[\\/]/g, '-'));
  return out;
}
/// The folder a pattern gives for one item, e.g. "{album}/{year}/{month} {monthName}"; "/" (or "\\") makes a folder inside a folder.
function patternFolder(pattern, a, album, device = '') {
  return render(pattern, a, album, device, String(a.filename || '').replace(/\.[^.]*$/, ''))
    .split(/[\\/]/).map(safePart).filter((p) => p && p !== '.' && p !== '..').join(path.sep);
}
/// The new name (without extension) a file-name pattern gives one item; null keeps the device's name.
function fileStem(pattern, a, album, device, original) {
  const p = String(pattern || '').trim();
  if (!p) return null;
  const s = safePart(render(p, a, album, device, String(original).replace(/\.[^.]*$/, '')).replace(/[\\/]/g, '-'));
  return !s || s === '.' || s === '..' ? null : s;
}

/// Swaps each edited item for its rendered edit (PhotoData/Mutations/.../Adjustments/FullSizeRender.*) when it is on the device.
async function withEdits(assets, device, tools) {
  const out = [];
  for (const a of assets) {
    if (!a.isEdited) { out.push(a); continue; }
    const dir = a.directory.startsWith('/') ? a.directory.slice(1) : a.directory;
    const base = `PhotoData/Mutations/${dir}/${a.filename.replace(/\.[^.]*$/, '')}/Adjustments/FullSizeRender`;
    let swapped = a;
    for (const remote of a.isVideo ? [base + '.mov'] : [base + '.heic', base + '.jpg']) {
      const size = await ios.remoteSize(remote, device, tools);
      if (size > 0) {
        const ext = remote.split('.').pop(), rename = (n) => n.replace(/\.[^.]*$/, '') + '.' + ext;
        swapped = { ...a, remotePath: remote, originalRemote: a.remotePath, fileSize: size, filename: rename(a.filename),
          originalFilename: rename(a.originalFilename), ext: ext.toUpperCase(), isHEIC: ext === 'heic' };
        break;
      }
    }
    out.push(swapped);
  }
  return out;
}

/// HEIC → JPEG for a batch, in one PowerShell run with Windows' own imaging codecs (needs Microsoft's free
/// "HEIF Image Extensions", which Windows 11 usually has). Keeps the photo's metadata when the codec allows it.
async function convertHEICs(pairs) {
  if (!pairs.length) return;
  if (process.platform !== 'win32') {   // development on a Mac: same result through sips
    for (const [src, dst] of pairs) await run('/usr/bin/sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '90', src, '--out', dst], { timeout: 120 });
    return;
  }
  const list = path.join(os.tmpdir(), `porthop-heic-${crypto.randomUUID()}.json`);
  fs.writeFileSync(list, JSON.stringify(pairs.map(([src, dst]) => ({ src, dst }))));
  const script = `Add-Type -AssemblyName PresentationCore
foreach ($p in (Get-Content -Raw -LiteralPath '${list.replace(/'/g, "''")}' | ConvertFrom-Json)) {
  try {
    $in = [IO.File]::OpenRead($p.src)
    $dec = [Windows.Media.Imaging.BitmapDecoder]::Create($in, 'PreservePixelFormat', 'OnLoad')
    $f = $dec.Frames[0]
    try { $frame = [Windows.Media.Imaging.BitmapFrame]::Create($f, $null, $f.Metadata, $f.ColorContexts) } catch { $frame = [Windows.Media.Imaging.BitmapFrame]::Create($f) }
    $enc = New-Object Windows.Media.Imaging.JpegBitmapEncoder; $enc.QualityLevel = 90; $enc.Frames.Add($frame)
    $out = [IO.File]::Create($p.dst); $enc.Save($out); $out.Close(); $in.Close()
  } catch { if ($out) { $out.Close() }; Remove-Item -LiteralPath $p.dst -ErrorAction SilentlyContinue }
}`;
  try { await run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], { timeout: 60 + pairs.length * 10 }); }
  finally { fs.rmSync(list, { force: true }); }
}

const safeName = (s) => s.replace(/[\\/:*?"<>|\x00-\x1f]/g, '-').replace(/[. ]+$/, '') || 'file';

/// The sizes of the files arriving in the staging folder, read without blocking the app (the window stays responsive).
async function stagedSizes(dir) {
  const sizes = new Map();
  let names = [];
  try { names = await fs.promises.readdir(dir); } catch { return sizes; }
  await Promise.all(names.map(async (n) => { try { sizes.set(path.join(dir, n), (await fs.promises.stat(path.join(dir, n))).size); } catch {} }));
  return sizes;
}

async function exportAssets({ assets, dest, options = {}, device, tools, job, onProgress = () => {}, stallLimit = 75 }) {
  const started = Date.now();
  const summary = { destination: dest, total: assets.length, copied: 0, skipped: 0, liveVideos: 0, failures: [], notAttempted: 0,
    cancelled: false, disconnected: false, stalled: false, fatalError: null, bytesCopied: 0, elapsed: 0 };
  try { fs.mkdirSync(dest, { recursive: true }); fs.accessSync(dest, fs.constants.W_OK); }
  catch (e) { summary.fatalError = `The destination folder cannot be written to (${e.code || e.message}).`; return summary; }

  const manifestPath = path.join(dest, MANIFEST);
  const manifest = new Map();
  // Shared with the Mac edition: an object keyed by the file's path on the device. Older copies of either app wrote
  // a list (Windows) or keyed by photo ID (Mac); both still load, and the file is rewritten in the shared shape.
  for (const file of [path.join(dest, LEGACY_MANIFEST), manifestPath]) {
    try {
      const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
      for (const e of Array.isArray(raw) ? raw : Object.values(raw)) if (e && e.sourceRemotePath) manifest.set(e.sourceRemotePath, e);
    } catch {}
  }
  try { for (const n of fs.readdirSync(dest)) if (n.startsWith(STAGING) || n.startsWith(LEGACY_STAGING)) fs.rmSync(path.join(dest, n), { recursive: true, force: true }); } catch {}
  const saveManifest = () => {
    try {
      const tmp = manifestPath + '.tmp';
      fs.writeFileSync(tmp, JSON.stringify(Object.fromEntries(manifest)));
      fs.renameSync(tmp, manifestPath);
    } catch {}
  };
  const staging = path.join(dest, STAGING + crypto.randomUUID());
  fs.mkdirSync(staging, { recursive: true });

  const reserved = new Set();
  const key = (p) => (process.platform === 'win32' ? p.toLowerCase() : p);
  const unique = (preferred) => {
    const ext = path.extname(preferred), stem = preferred.slice(0, preferred.length - ext.length);
    let c = preferred;
    for (let i = 2; fs.existsSync(c) || reserved.has(key(c)); i++) c = `${stem} (${i})${ext}`;
    reserved.add(key(c));
    return c;
  };

  const queue = [];
  const report = new Map();   // photo ID → its line in the copy report
  let bytesTotal = 0, bytesDone = 0;
  const record = (item, finalPath) => {
    const rel = (p) => path.relative(dest, p).split(path.sep).join('/');   // '/' on both systems, so the Mac reads it too
    manifest.set(item.remote, { preferredPath: rel(item.preferred), exportedPath: rel(finalPath),
      sourceRemotePath: item.remote, sourceSize: item.size, exportedSize: fileSize(finalPath) });
  };
  if (options.editedVersions) assets = await withEdits(assets, device, tools);
  for (const a of assets) {
    const sub = options.subfolder === 'yearMonth' ? a.yearMonth : options.subfolder === 'iphoneFolder' ? safeName(path.posix.basename(a.directory))
      : options.subfolder === 'custom' ? patternFolder(options.folderPattern, a, options.albumName, options.deviceName) : '';
    let baseName = safeName(options.useOriginalNames ? a.originalFilename : a.filename);
    const renamed = fileStem(options.namePattern, a, options.albumName, options.deviceName, baseName);
    if (renamed) baseName = renamed + path.extname(baseName);
    const convert = !!options.convertHEIC && a.isHEIC;
    if (convert) baseName = baseName.replace(/\.[^.]*$/, '') + '.jpg';
    const items = [{ asset: a, remote: a.remotePath, size: a.fileSize, live: false, convert, preferred: path.join(dest, sub, baseName) }];
    if (options.includeLiveVideo && a.isLivePhoto) {
      const stem = (s) => s.replace(/\.[^.]*$/, '');
      items.push({ asset: a, remote: stem(a.originalRemote || a.remotePath) + '.MOV', size: 0, live: true, preferred: path.join(dest, sub, stem(baseName) + '.MOV') });
    }
    for (const item of items) {
      const known = options.skipExisting !== false && manifest.get(item.remote);
      if (known && fileSize(path.join(dest, known.exportedPath)) === known.exportedSize && known.exportedSize > 0) {
        if (!item.live) { summary.skipped++; report.set(a.id, { status: 'skipped', asset: a, savedAs: known.exportedPath, note: '' }); }
        continue;
      }
      if (options.skipExisting !== false && item.size > 0 && fileSize(item.preferred) === item.size) {
        record(item, item.preferred);
        if (!item.live) { summary.skipped++; report.set(a.id, { status: 'skipped', asset: a, savedAs: path.relative(dest, item.preferred).split(path.sep).join('/'), note: '' }); }
        continue;
      }
      item.final = unique(item.preferred);
      item.staged = path.join(staging, `${queue.length}${path.extname(item.preferred)}`);
      item.state = 'waiting';
      queue.push(item);
      bytesTotal += Math.max(0, item.size);
    }
  }

  // Files in the batches being copied right now; the ones already complete count as landed in the progress.
  const active = new Set();
  let staged = new Map(), measuring = false;
  const measure = async () => {
    if (measuring) return;
    measuring = true;
    try { staged = await stagedSizes(staging); } finally { measuring = false; }
  };
  const emit = () => {
    let inFlight = 0;
    for (const n of staged.values()) inFlight += n;
    let landed = 0;
    for (const it of active) if (it.size > 0 && staged.get(it.staged) === it.size) landed++;
    const secs = (Date.now() - started) / 1000;
    onProgress({ total: summary.total, copied: summary.copied, skipped: summary.skipped, failed: summary.failures.length, inFlight: landed,
      bytesDone: bytesDone + inFlight, bytesTotal, bytesPerSecond: secs > 0.5 ? (bytesDone + inFlight) / secs : 0 });
  };

  // Confirms one staged file is complete, then moves it into place.
  const settle = async (item, interrupted) => {
    const got = fileSize(item.staged);
    let good = got > 0 && item.size > 0 && got === item.size;
    if (!good && got > 0) {
      const remote = await ios.remoteSize(item.remote, device, tools);
      good = remote != null ? remote === got : (!interrupted && item.size <= 0);
    }
    if (!good) { try { fs.rmSync(item.staged, { force: true }); } catch {} item.state = 'missed'; return; }
    if (item.convert) {
      const jpg = item.staged + '.jpg';
      fs.rmSync(item.staged, { force: true });
      if (fileSize(jpg) <= 0) { item.state = 'missed'; item.convertFailed = true; return; }
      item.staged = jpg;
    }
    try {
      fs.mkdirSync(path.dirname(item.final), { recursive: true });
      if (fs.existsSync(item.final)) item.final = unique(item.final);
      if (options.removeLocation) location.scrub(item.staged);   // before it lands, so no copy ever carries the position
      fs.renameSync(item.staged, item.final);
      if (options.setDates !== false && item.asset.ts) { const t = new Date((item.asset.ts + APPLE_EPOCH) * 1000); fs.utimesSync(item.final, t, t); }
    } catch { item.state = 'missed'; return; }
    item.state = 'done';
    record(item, item.final);
    bytesDone += got;
    summary.bytesCopied += got;
    if (item.live) summary.liveVideos++;
    else { summary.copied++; report.set(item.asset.id, { status: 'copied', asset: item.asset, savedAs: path.relative(dest, item.final).split(path.sep).join('/'), note: '' }); }
  };

  const copyBatch = async (batch) => {
    let cmds = '';
    for (const item of batch) {
      const r = ios.quote(item.remote), l = ios.quote(item.staged);
      if (r && l) cmds += `get ${r} ${l}\n`;
      item.state = 'tried';
      if (!item.live) active.add(item);
    }
    await run(tools.afc, ios.base(device), { stdin: cmds + 'quit\n', onStart: (c) => job.track(c) });
    const interrupted = job.cancelled || summary.stalled;
    await convertHEICs(batch.filter((i) => i.convert && i.size > 0 && fileSize(i.staged) === i.size).map((i) => [i.staged, i.staged + '.jpg']));
    for (const item of batch) { await settle(item, interrupted); active.delete(item); }
    saveManifest();   // after every batch, so a crash or power cut keeps the record of what already landed
  };

  let lastSeen = -1, lastChange = Date.now();
  const watchdog = setInterval(async () => {
    await measure();
    let inFlight = 0;
    for (const n of staged.values()) inFlight += n;
    const now = bytesDone + inFlight + summary.copied;
    if (now !== lastSeen) { lastSeen = now; lastChange = Date.now(); }
    else if ((Date.now() - lastChange) / 1000 > stallLimit && !summary.stalled) { summary.stalled = true; job.killAll(); }
    emit();
  }, 500);

  try {
    const chunks = [];
    for (let i = 0; i < queue.length; i += CHUNK) chunks.push(queue.slice(i, i + CHUNK));
    let next = 0;
    const worker = async () => {
      while (next < chunks.length && !job.cancelled && !summary.stalled) await copyBatch(chunks[next++]);
    };
    await Promise.all(Array.from({ length: Math.min(STREAMS, chunks.length) }, worker));

    let missed = queue.filter((i) => i.state === 'missed');
    if (missed.length && !job.cancelled && !summary.stalled) {
      if (!(await ios.isConnected(device, tools))) summary.disconnected = true;
      else {
        lastChange = Date.now();
        await copyBatch(missed);
        missed = queue.filter((i) => i.state === 'missed');
        if (missed.length && !(await ios.isConnected(device, tools))) summary.disconnected = true;
      }
    }
    summary.cancelled = job.cancelled;
    for (const item of queue) {
      if (item.live) continue;
      if (item.state === 'waiting') summary.notAttempted++;
      else if (item.state === 'missed' || item.state === 'tried') {
        if (summary.cancelled || summary.stalled) { summary.notAttempted++; continue; }
        const failed = (reason) => {
          summary.failures.push({ id: item.asset.id, filename: item.asset.filename, reason });
          report.set(item.asset.id, item.asset.isCloudOnly ? { status: 'cloud', asset: item.asset, savedAs: '', note: 'Stored only in iCloud. Turn off Optimise Storage on the device to copy it.' }
            : { status: 'failed', asset: item.asset, savedAs: '', note: reason });
        };
        let reason = 'The copy did not complete.';
        if (item.convertFailed) { failed('HEIC to JPEG conversion failed. Install Microsoft\'s free "HEIF Image Extensions" from the Microsoft Store, or copy without converting.'); continue; }
        if (summary.disconnected) reason = 'The device was disconnected.';
        else if ((await ios.remoteSize(item.remote, device, tools)) == null) reason = 'The original is not on the device. It may be stored only in iCloud.';
        failed(reason);
      }
    }
  } finally {
    clearInterval(watchdog);
    saveManifest();
    try { fs.rmSync(staging, { recursive: true, force: true }); } catch {}
    summary.elapsed = (Date.now() - started) / 1000;
    staged = new Map();
    emit();
  }
  if (options.saveReport !== false && summary.copied + summary.failures.length + summary.notAttempted > 0) {
    summary.reportPath = writeReport(summary, assets, report, dest, options.albumName);
  }
  return summary;
}

/// "PortHop Reports/2026-11-23 14.05.09 Favourites.csv": a line for every item copied, failed or left out, with counts
/// at the top. Items already in the folder are counted, not listed, so repeat hops stay small. Same format as the Mac.
function writeReport(summary, assets, report, dest, album) {
  try {
    const folder = path.join(dest, 'PortHop Reports');
    fs.mkdirSync(folder, { recursive: true });
    const why = summary.stalled ? 'The device stopped responding.' : summary.disconnected ? 'The device was disconnected.' : 'The copy was stopped first.';
    const lines = [...report.values()].filter((l) => l.status !== 'skipped');
    for (const a of assets) if (!report.has(a.id)) lines.push({ status: 'notCopied', asset: a, savedAs: '', note: why });
    const words = { copied: 'Copied', failed: 'Failed', cloud: 'Only in iCloud', notCopied: 'Not copied' };
    const n = (st) => lines.filter((l) => l.status === st).length;
    const q = (v) => (/[",\n\r]/.test(String(v)) ? `"${String(v).replace(/"/g, '""')}"` : String(v));
    const two = (x) => String(x).padStart(2, '0');
    const now = new Date();
    const stamp = `${now.getFullYear()}-${two(now.getMonth() + 1)}-${two(now.getDate())} ${two(now.getHours())}:${two(now.getMinutes())}:${two(now.getSeconds())}`;
    const taken = (a) => { if (!a.ts) return ''; const d = new Date((a.ts + APPLE_EPOCH) * 1000); return `${dateText(d)}:${two(d.getSeconds())}`; };
    const kind = (a) => (a.isVideo ? 'Video' : a.isLivePhoto ? 'Live Photo' : a.isScreenshot ? 'Screenshot' : 'Photo');
    let csv = `\uFEFFPortHop copy report,${q(album || 'Photos')},${q(stamp)}\n`;
    csv += `Copied,${n('copied')}\nAlready in the folder,${summary.skipped}\nFailed,${n('failed')}\nOnly in iCloud,${n('cloud')}\nNot copied,${n('notCopied')}\n\n`;
    csv += 'Status,Name on device,Saved as,Size (bytes),Date taken,Kind,Note\n';
    for (const l of lines) csv += [words[l.status], l.asset.filename, l.savedAs, Math.max(0, l.asset.fileSize || 0), taken(l.asset), kind(l.asset), l.note].map(q).join(',') + '\n';
    let file = path.join(folder, safePart(`${stamp.replace(/:/g, '.')} ${album || 'Photos'}`) + '.csv');
    for (let i = 2; fs.existsSync(file); i++) file = file.replace(/( \(\d+\))?\.csv$/, ` (${i}).csv`);
    fs.writeFileSync(file, csv);
    return file;
  } catch { return null; }
}

module.exports = { exportAssets, patternFolder, fileStem, TOKENS, MANIFEST, STAGING };
