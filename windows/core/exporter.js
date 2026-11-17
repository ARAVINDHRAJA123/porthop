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
  try { for (const e of JSON.parse(fs.readFileSync(manifestPath, 'utf8'))) manifest.set(e.sourceRemotePath, e); } catch {}
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
    manifest.set(item.remote, { preferredPath: path.relative(dest, item.preferred), exportedPath: path.relative(dest, finalPath),
      sourceRemotePath: item.remote, sourceSize: item.size, exportedSize: fileSize(finalPath) });
  };
  for (const a of assets) {
    const sub = options.subfolder === 'yearMonth' ? a.yearMonth : options.subfolder === 'iphoneFolder' ? safeName(path.posix.basename(a.directory)) : '';
    const baseName = safeName(options.useOriginalNames ? a.originalFilename : a.filename);
    const items = [{ asset: a, remote: a.remotePath, size: a.fileSize, live: false, preferred: path.join(dest, sub, baseName) }];
    if (options.includeLiveVideo && a.isLivePhoto) {
      const stem = (s) => s.replace(/\.[^.]*$/, '');
      items.push({ asset: a, remote: stem(a.remotePath) + '.MOV', size: 0, live: true, preferred: path.join(dest, sub, stem(baseName) + '.MOV') });
    }
    for (const item of items) {
      const known = manifest.get(item.remote);
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
    for (const item of batch) { await settle(item, interrupted); active.delete(item); }
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
        if (summary.disconnected) reason = 'The device was disconnected.';
        else if ((await ios.remoteSize(item.remote, device, tools)) == null) reason = 'The original is not on the device. It may be stored only in iCloud.';
        summary.failures.push({ id: item.asset.id, filename: item.asset.filename, reason });
      }
    }
  } finally {
    clearInterval(watchdog);
    try {
      const tmp = manifestPath + '.tmp';
      fs.writeFileSync(tmp, JSON.stringify([...manifest.values()]));
      fs.renameSync(tmp, manifestPath);
    } catch {}
    try { fs.rmSync(staging, { recursive: true, force: true }); } catch {}
    summary.elapsed = (Date.now() - started) / 1000;
    emit();
  }
  return summary;
}

module.exports = { exportAssets, MANIFEST, STAGING };
