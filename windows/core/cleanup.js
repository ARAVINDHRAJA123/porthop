'use strict';
// Removing from the phone what has been copied: only items whose copy is confirmed. Same rules as the Mac.
const path = require('node:path');
const { fileSize } = require('./shell');
const android = require('./android');

const ext = (n) => path.extname(n).slice(1).toLowerCase();

/// The phone's camera files that belong to confirmed items (same folder and name; a HEIC may be offered as a JPEG).
function deletable(assets, files, liveVideos) {
  const key = (folder, name) => folder.toUpperCase() + '/' + name.replace(/\.[^.]*$/, '').toUpperCase();
  const byKey = new Map();
  for (const f of files) { const k = key(f.folder, f.name); if (!byKey.has(k)) byKey.set(k, []); byKey.get(k).push(f); }
  const out = new Map();
  for (const a of assets) {
    const list = byKey.get(key(a.directory.split('/').pop(), a.filename));
    if (!list) continue;
    const mine = ext(a.filename);
    const offersOriginal = list.some((f) => ext(f.name) === mine);
    for (const f of list) {
      const theirs = ext(f.name);
      const same = theirs === mine && (f.size <= 0 || a.fileSize <= 0 || f.size === a.fileSize);
      const converted = !offersOriginal && ['heic', 'heif'].includes(mine) && ['jpg', 'jpeg'].includes(theirs);
      const live = a.isLivePhoto && liveVideos && theirs === 'mov' && mine !== 'mov';
      if (same || converted || live) out.set(`${f.folder}/${f.name}`, f);
    }
  }
  return [...out.values()].sort((x, y) => (x.folder + '/' + x.name < y.folder + '/' + y.name ? -1 : 1));
}

/// Phone files under copied folders whose copy on this computer has the same size: safe to delete.
async function androidConfirmed(pairs, device, tools) {
  const out = [];
  for (const p of pairs) {
    for (const e of await android.filesBelow(p.remote, device, tools)) {
      if (!e.path.startsWith(p.remote + '/')) continue;
      const local = path.join(p.local, ...e.path.slice(p.remote.length + 1).split('/'));
      if (e.size > 0 && fileSize(local) === e.size) out.push(e);
    }
  }
  return out;
}

module.exports = { deletable, androidConfirmed };
