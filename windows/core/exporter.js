'use strict';
// Copies photos and videos off an iPhone or iPad. Files land in a hidden staging folder first and are moved
// into place only after their size is confirmed, so a stopped or unplugged copy never leaves a broken file.
// Nothing in the destination is ever overwritten, and nothing on the device is changed.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { run, fileSize } = require('./shell');
const ios = require('./ios');
const { APPLE_EPOCH } = require('./catalog');

const MANIFEST = '.iPhoneAlbumExtractor-manifest.json';
const STAGING = '.iPhoneAlbumExtractor-staging-';
const CHUNK = 60, STREAMS = 3;

const os = require('node:os');

/// The folder a custom pattern gives for one item, e.g. "{album}/{year}/{month} {monthName}" (same tokens as the Mac).
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
function patternFolder(pattern, a, album) {
  const d = a.ts ? new Date((a.ts + APPLE_EPOCH) * 1000) : null;
  const two = (n) => String(n).padStart(2, '0');
  const values = { '{year}': d ? String(d.getFullYear()) : 'Unknown', '{month}': d ? two(d.getMonth() + 1) : 'Unknown',
    '{monthName}': d ? MONTHS[d.getMonth()] : 'Unknown', '{day}': d ? two(d.getDate()) : 'Unknown',
    '{album}': album || 'Photos', '{folder}': path.posix.basename(a.directory) || 'DCIM' };
  let out = String(pattern || '');
  for (const [k, v] of Object.entries(values)) out = out.split(k).join(v.replace(/[\\/]/g, '-'));
  return out.split('/').map((p) => safeName(p.trim())).filter((p) => p && p !== '.' && p !== '..' && p !== 'file').join(path.sep);
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

function dirSize(dir) {
  let total = 0;
  try { for (const f of fs.readdirSync(dir)) total += fileSize(path.join(dir, f)); } catch {}
  return total;
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
  try {
    const raw = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    for (const e of Array.isArray(raw) ? raw : Object.values(raw)) if (e && e.sourceRemotePath) manifest.set(e.sourceRemotePath, e);
  } catch {}
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
  let bytesTotal = 0, bytesDone = 0;
  const record = (item, finalPath) => {
    const rel = (p) => path.relative(dest, p).split(path.sep).join('/');   // '/' on both systems, so the Mac reads it too
    manifest.set(item.remote, { preferredPath: rel(item.preferred), exportedPath: rel(finalPath),
      sourceRemotePath: item.remote, sourceSize: item.size, exportedSize: fileSize(finalPath) });
  };
  if (options.editedVersions) assets = await withEdits(assets, device, tools);
  for (const a of assets) {
    const sub = options.subfolder === 'yearMonth' ? a.yearMonth : options.subfolder === 'iphoneFolder' ? safeName(path.posix.basename(a.directory))
      : options.subfolder === 'custom' ? patternFolder(options.folderPattern, a, options.albumName) : '';
    let baseName = safeName(options.useOriginalNames ? a.originalFilename : a.filename);
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
        if (!item.live) summary.skipped++;
        continue;
      }
      if (options.skipExisting !== false && item.size > 0 && fileSize(item.preferred) === item.size) {
        record(item, item.preferred);
        if (!item.live) summary.skipped++;
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
  const emit = () => {
    const inFlight = dirSize(staging);
    let landed = 0;
    for (const it of active) if (it.size > 0 && fileSize(it.staged) === it.size) landed++;
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
      fs.renameSync(item.staged, item.final);
      if (options.setDates !== false && item.asset.ts) { const t = new Date((item.asset.ts + APPLE_EPOCH) * 1000); fs.utimesSync(item.final, t, t); }
    } catch { item.state = 'missed'; return; }
    item.state = 'done';
    record(item, item.final);
    bytesDone += got;
    summary.bytesCopied += got;
    if (item.live) summary.liveVideos++; else summary.copied++;
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
  const watchdog = setInterval(() => {
    const now = bytesDone + dirSize(staging) + summary.copied;
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
        let reason = 'The copy did not complete.';
        if (item.convertFailed) { summary.failures.push({ id: item.asset.id, filename: item.asset.filename,
          reason: 'HEIC to JPEG conversion failed. Install Microsoft\'s free "HEIF Image Extensions" from the Microsoft Store, or copy without converting.' }); continue; }
        if (summary.disconnected) reason = 'The device was disconnected.';
        else if ((await ios.remoteSize(item.remote, device, tools)) == null) reason = 'The original is not on the device. It may be stored only in iCloud.';
        summary.failures.push({ id: item.asset.id, filename: item.asset.filename, reason });
      }
    }
  } finally {
    clearInterval(watchdog);
    saveManifest();
    try { fs.rmSync(staging, { recursive: true, force: true }); } catch {}
    summary.elapsed = (Date.now() - started) / 1000;
    emit();
  }
  return summary;
}

module.exports = { exportAssets, patternFolder, MANIFEST, STAGING };
