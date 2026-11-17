'use strict';
// Reads the device's own photo database (PhotoData/Photos.sqlite). Apple does not document it, so every
// table and column is checked before use.
const { DatabaseSync } = require('node:sqlite');

const APPLE_EPOCH = 978307200;
const pad = (n) => String(n).padStart(2, '0');
function dateText(d) {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function loadCatalog(dbPath) {
  let db;
  try { db = new DatabaseSync(dbPath, { readOnly: true }); }
  catch { return { error: 'unreadable' }; }
  try {
    const hasTable = (n) => !!db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(n);
    const columns = (t) => new Set(db.prepare(`PRAGMA table_info(${t})`).all().map((r) => r.name));
    const table = hasTable('ZASSET') ? 'ZASSET' : (hasTable('ZGENERICASSET') ? 'ZGENERICASSET' : null);
    if (!table) return { error: 'unsupported', why: 'The photo database has no asset table this app recognises (ZASSET).' };
    const cols = columns(table);
    const missing = ['Z_PK', 'ZDIRECTORY', 'ZFILENAME'].filter((c) => !cols.has(c));
    if (missing.length) return { error: 'unsupported', why: `The asset table is missing ${missing.join(', ')}, which this app needs to locate files.` };
    const attrCols = hasTable('ZADDITIONALASSETATTRIBUTES') ? columns('ZADDITIONALASSETATTRIBUTES') : new Set();
    const joinAttr = attrCols.has('ZASSET');
    const warnings = [];
    const col = (name, fallback, warn) => {
      if (cols.has(name)) return `COALESCE(a.${name}, ${fallback})`;
      if (warn) warnings.push(warn);
      return fallback;
    };
    const orig = joinAttr && attrCols.has('ZORIGINALFILENAME') ? 'COALESCE(attr.ZORIGINALFILENAME, a.ZFILENAME)' : 'a.ZFILENAME';
    let size = '0';
    if (joinAttr && attrCols.has('ZORIGINALFILESIZE')) size = 'COALESCE(attr.ZORIGINALFILESIZE, 0)';
    else warnings.push("File sizes are not available in this iOS version's photo database, so size sorting and size verification are limited.");
    const hidden = col('ZHIDDEN', '0', 'This iOS version does not mark hidden items the way this app expects, so the Hidden album cannot be identified.');
    const shot = cols.has('ZISDETECTEDSCREENSHOT') ? 'COALESCE(a.ZISDETECTEDSCREENSHOT, 0)'
      : (cols.has('Z1_ISDETECTEDSCREENSHOT') ? 'COALESCE(a.Z1_ISDETECTEDSCREENSHOT, 0)' : '0');
    const sql = `SELECT a.Z_PK pk, a.ZDIRECTORY dir, a.ZFILENAME fn, ${orig} orig, ${size} size, ${hidden} hidden,
        ${col('ZFAVORITE', '0')} fav, ${col('ZTRASHEDSTATE', '0')} trashed, ${col('ZKIND', '0')} kind, ${col('ZDATECREATED', '0')} ts,
        ${col('ZWIDTH', '0')} w, ${col('ZHEIGHT', '0')} h, ${col('ZDURATION', '0.0')} dur, ${shot} shot,
        ${col('ZCAMERACAPTUREDEVICE', '0')} cam, ${col('ZKINDSUBTYPE', '0')} sub
      FROM ${table} a ${joinAttr ? 'LEFT JOIN ZADDITIONALASSETATTRIBUTES attr ON attr.ZASSET = a.Z_PK' : ''}
      WHERE a.ZFILENAME IS NOT NULL AND a.ZDIRECTORY IS NOT NULL AND a.ZFILENAME != ''
      ORDER BY ${cols.has('ZDATECREATED') ? 'a.ZDATECREATED DESC' : 'a.Z_PK DESC'}`;
    let rows;
    try { rows = db.prepare(sql).all(); }
    catch (e) { return { error: 'unsupported', why: `The photo database could not be queried (${e.message}).` }; }
    const ordered = [], byPK = new Map();
    for (const r of rows) {
      const ts = Number(r.ts) || 0;
      const date = ts !== 0 ? new Date((ts + APPLE_EPOCH) * 1000) : null;
      const kind = Number(r.kind), sub = Number(r.sub);
      const dir = String(r.dir), fn = String(r.fn), dt = date ? dateText(date) : '—';
      const ext = fn.includes('.') ? fn.split('.').pop().toUpperCase() : '';
      const a = {
        id: Number(r.pk), directory: dir, filename: fn, originalFilename: String(r.orig || fn), fileSize: Number(r.size) || 0,
        width: Number(r.w) || 0, height: Number(r.h) || 0, duration: Number(r.dur) || 0,
        isHidden: Number(r.hidden) !== 0, isFavorite: Number(r.fav) !== 0, isTrashed: Number(r.trashed) !== 0,
        isVideo: kind === 1, isScreenshot: Number(r.shot) !== 0 || sub === 10, isSelfie: Number(r.cam) === 1,
        isLivePhoto: kind === 0 && sub === 2, ts, dateText: dt, ext, isHEIC: ext === 'HEIC' || ext === 'HEIF',
        yearMonth: date ? `${date.getFullYear()}-${pad(date.getMonth() + 1)}` : 'Unknown Date',
      };
      a.remotePath = (dir.startsWith('/') ? dir.slice(1) : dir) + '/' + fn;
      a.searchKey = `${fn} ${a.originalFilename} ${dir} ${dt}`.toLowerCase();
      ordered.push(a); byPK.set(a.id, a);
    }
    const user = [];
    if (hasTable('ZGENERICALBUM') && columns('ZGENERICALBUM').has('ZTITLE')) {
      const trash = columns('ZGENERICALBUM').has('ZTRASHEDSTATE') ? 'AND COALESCE(alb.ZTRASHEDSTATE, 0) = 0' : '';
      const joins = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z\\_%ASSETS' ESCAPE '\\'").all()
        .map((r) => r.name).filter((n) => /^[A-Za-z0-9_]+$/.test(n));
      for (const jt of joins) {
        const jc = [...columns(jt)].sort();
        const albumCol = jc.find((c) => c.endsWith('ALBUMS'));
        const assetCol = jc.find((c) => c.endsWith('ASSETS') && !c.startsWith('Z_FOK'));
        if (!albumCol || !assetCol) continue;
        let list;
        try {
          list = db.prepare(`SELECT alb.Z_PK pk, alb.ZTITLE title, j.${assetCol} asset FROM ZGENERICALBUM alb
            INNER JOIN ${jt} j ON alb.Z_PK = j.${albumCol} WHERE alb.ZTITLE IS NOT NULL AND alb.ZTITLE != '' ${trash}`).all();
        } catch { continue; }
        const map = new Map();
        for (const r of list) {
          const a = byPK.get(Number(r.asset));
          // Like the Photos app: a hidden item appears only in Hidden.
          if (!a || a.isTrashed || a.isHidden) continue;
          if (!map.has(r.pk)) map.set(r.pk, { id: `album_${r.pk}`, title: String(r.title), smart: false, assets: [] });
          map.get(r.pk).assets.push(a);
        }
        for (const v of map.values()) { v.assets.sort((x, y) => y.ts - x.ts); user.push(v); }
      }
    }
    user.sort((a, b) => a.title.localeCompare(b.title, undefined, { sensitivity: 'base' }));
    const live = ordered.filter((a) => !a.isTrashed), shown = live.filter((a) => !a.isHidden);
    const smart = (id, title, assets) => ({ id, title, smart: true, assets });
    return {
      smart: [
        smart('smart_hidden', 'Hidden', live.filter((a) => a.isHidden)), smart('smart_all', 'Library', shown),
        smart('smart_favorites', 'Favorites', shown.filter((a) => a.isFavorite)), smart('smart_videos', 'Videos', shown.filter((a) => a.isVideo)),
        smart('smart_live', 'Live Photos', shown.filter((a) => a.isLivePhoto)), smart('smart_screenshots', 'Screenshots', shown.filter((a) => a.isScreenshot)),
        smart('smart_selfies', 'Selfies', shown.filter((a) => a.isSelfie)), smart('smart_trashed', 'Recently Deleted', ordered.filter((a) => a.isTrashed)),
      ],
      user, warnings, assetCount: ordered.length,
    };
  } finally { try { db.close(); } catch {} }
}

const FILTERS = {
  all: () => true, photos: (a) => !a.isVideo, videos: (a) => a.isVideo, live: (a) => a.isLivePhoto,
  screenshots: (a) => a.isScreenshot, favorites: (a) => a.isFavorite, heic: (a) => a.isHEIC,
};
const SORTS = {
  date: (a) => a.ts, size: (a) => a.fileSize, name: (a) => a.filename, original: (a) => a.originalFilename,
  folder: (a) => a.directory, resolution: (a) => a.width * a.height, kind: (a) => (a.isVideo ? 2 : a.isLivePhoto ? 1 : 0),
};
const natural = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });

function view(assets, { filter = 'all', search = '', sort = 'date', ascending = false, from = null, to = null, minBytes = 0 } = {}) {
  let list = assets;
  if (from != null && to != null) list = list.filter((a) => a.ts && a.ts >= from && a.ts <= to);
  if (minBytes > 0) list = list.filter((a) => a.fileSize >= minBytes);
  if (filter !== 'all' && FILTERS[filter]) list = list.filter(FILTERS[filter]);
  const q = search.trim().toLowerCase();
  if (q) list = list.filter((a) => a.searchKey.includes(q));
  const key = SORTS[sort] || SORTS.date;
  const sign = ascending ? 1 : -1;
  return [...list].sort((a, b) => {
    const x = key(a), y = key(b);
    const c = typeof x === 'string' ? natural.compare(x, y) : x - y;
    return c !== 0 ? c * sign : a.id - b.id;
  });
}

module.exports = { loadCatalog, view, APPLE_EPOCH, dateText };
