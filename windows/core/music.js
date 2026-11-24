'use strict';
// The iPhone's music library over USB: songs synced from a computer or bought in the iTunes Store, and ringtones.
// Reads the iPhone's own library database (read-only copy) and copies files out as Artist/Album/01 Title.ext. Same as the Mac.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { DatabaseSync } = require('node:sqlite');
const { run, fileSize } = require('./shell');
const ios = require('./ios');
const android = require('./android');
const plist = require('./plist');

const DATABASE = 'iTunes_Control/iTunes/MediaLibrary.sqlitedb';
const TONES = 'iTunes_Control/Ringtones';
const safe = (s) => String(s).replace(/[\\/:*?"<>|\u0000-\u001f]/g, '-').trim().replace(/[. ]+$/, '');
const collator = new Intl.Collator(undefined, { sensitivity: 'base' });

function decorate(s) {
  s.ext = path.extname(s.remotePath).slice(1).toLowerCase();
  s.onPhone = !!s.remotePath;
  s.isProtected = s.ext === 'm4p' || s.ext === 'movpkg';
  s.canCopy = s.onPhone && !s.isProtected;
  const name = (safe(s.title) || `Track ${s.id}`) + (s.ext ? '.' + s.ext : '');
  const number = s.track > 0 ? (s.disc > 1 ? `${s.disc}-` : '') + String(s.track).padStart(2, '0') + ' ' : '';
  s.savedPath = s.isRingtone ? `Ringtones/${name}` : `${safe(s.albumArtist || s.artist) || 'Unknown Artist'}/${safe(s.album) || 'Unknown Album'}/${number}${name}`;
  return s;
}

async function get(remote, local, device, tools, job) {
  await run(tools.afc, [...ios.base(device), '--', 'get', remote, local], { onStart: (c) => job && job.track(c) });
  return fileSize(local) > 0;
}

/// Reads the library database. Only the columns that exist in this iOS version are used.
function read(file) {
  let db;
  try { db = new DatabaseSync(file, { readOnly: false }); } catch { return []; }
  try {
    const cols = (t) => { try { return new Set(db.prepare(`PRAGMA table_info("${t}")`).all().map((c) => c.name)); } catch { return new Set(); } };
    const item = cols('item'), extra = cols('item_extra');
    if (!item.has('item_pid') || !extra.has('location')) return [];
    const pick = (set, expr, name, fallback) => (set.has(name) ? expr : fallback);
    let joins = 'FROM item i JOIN item_extra e ON e.item_pid = i.item_pid', artist = "''", album = "''", albumArtist = "''", base = "''";
    if (cols('item_artist').has('item_artist') && item.has('item_artist_pid')) { joins += ' LEFT JOIN item_artist ar ON ar.item_artist_pid = i.item_artist_pid'; artist = "COALESCE(ar.item_artist,'')"; }
    if (cols('album').has('album') && item.has('album_pid')) { joins += ' LEFT JOIN album al ON al.album_pid = i.album_pid'; album = "COALESCE(al.album,'')"; }
    if (cols('album_artist').has('album_artist') && item.has('album_artist_pid')) { joins += ' LEFT JOIN album_artist aa ON aa.album_artist_pid = i.album_artist_pid'; albumArtist = "COALESCE(aa.album_artist,'')"; }
    if (cols('base_location').has('path') && item.has('base_location_id')) { joins += ' LEFT JOIN base_location b ON b.base_location_id = i.base_location_id'; base = "COALESCE(b.path,'')"; }
    const rows = db.prepare(`SELECT i.item_pid id, ${pick(extra, "COALESCE(e.title,'')", 'title', "''")} title, ${artist} artist, ${album} album, ${albumArtist} albumArtist,
      ${pick(item, 'COALESCE(i.track_number,0)', 'track_number', '0')} track, ${pick(item, 'COALESCE(i.disc_number,0)', 'disc_number', '0')} disc,
      ${pick(extra, 'COALESCE(e.year,0)', 'year', '0')} year, ${pick(extra, 'COALESCE(e.total_time_ms,0)', 'total_time_ms', '0')} ms,
      ${pick(extra, 'COALESCE(e.file_size,0)', 'file_size', '0')} size, ${base} folder, COALESCE(e.location,'') file ${joins}`).all();
    return rows.map((r) => {
      const remote = r.folder && r.file ? r.folder.replace(/^\/+|\/+$/g, '') + '/' + r.file : '';
      return decorate({ id: Number(r.id), title: r.title, artist: r.artist, album: r.album, albumArtist: r.albumArtist, track: Number(r.track), disc: Number(r.disc),
        year: Number(r.year), seconds: Number(r.ms) / 1000, size: Number(r.size), remotePath: remote, isRingtone: remote.includes('Ringtones/') });
    }).sort((a, b) => collator.compare(a.albumArtist || a.artist, b.albumArtist || b.artist) || collator.compare(a.album, b.album)
      || a.disc - b.disc || a.track - b.track || (a.title < b.title ? -1 : a.title > b.title ? 1 : 0));
  } catch { return []; } finally { try { db.close(); } catch {} }
}

/// Ringtones in the iPhone's ringtone folder, named from its list of tones when there is one.
async function ringtones(device, tools, dir) {
  const names = {};
  const listFile = path.join(dir, 'Ringtones.plist');
  if (await get('iTunes_Control/iTunes/Ringtones.plist', listFile, device, tools)) {
    try { for (const [file, info] of Object.entries(plist.parse(fs.readFileSync(listFile)).Ringtones || {})) if (info && info.Name) names[file] = info.Name; } catch {}
  }
  return (await ios.list(TONES, null, device, tools)).filter((e) => !e.isDirectory && e.name.toLowerCase().endsWith('.m4r'))
    .map((e, i) => decorate({ id: -(i + 1), title: names[e.name] || e.name.replace(/\.[^.]+$/, ''), artist: '', album: '', albumArtist: '', track: 0, disc: 0, year: 0,
      seconds: 0, size: e.size, remotePath: `${TONES}/${e.name}`, isRingtone: true }));
}

/// The songs and ringtones on the iPhone: { songs, problem }.
async function load(device, tools) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'PortHop-music-'));
  try {
    const db = path.join(dir, 'MediaLibrary.sqlitedb');
    let songs = [];
    if (await get(DATABASE, db, device, tools)) {
      await get(DATABASE + '-wal', db + '-wal', device, tools);
      await get(DATABASE + '-shm', db + '-shm', device, tools);
      songs = read(db);
    }
    const known = new Set(songs.map((s) => s.remotePath));
    const tones = (await ringtones(device, tools, dir)).filter((t) => !known.has(t.remotePath));
    const all = [...songs, ...tones];
    if (!all.length && !fs.existsSync(db)) return { songs: [], problem: 'The music library could not be read. Unlock the iPhone and try again.' };
    return { songs: all, problem: null };
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

/// Copies songs into a folder as "Artist/Album/01 Title.ext". A file already there with the same size is skipped.
async function copy(songs, folder, device, tools, job, progress = () => {}) {
  const o = { copied: 0, skipped: 0, failed: [], cancelled: false };
  for (let n = 0; n < songs.length; n++) {
    if (job && job.cancelled) { o.cancelled = true; break; }
    const s = songs[n];
    progress(n, songs.length, s.title);
    if (!s.canCopy) { o.failed.push(s.title); continue; }
    const dest = path.join(folder, ...s.savedPath.split('/'));
    if (fs.existsSync(dest) && (s.size <= 0 || fileSize(dest) === s.size)) { o.skipped++; continue; }
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const part = dest + '.porthop-part';
    fs.rmSync(part, { force: true });
    await get(s.remotePath, part, device, tools, job);
    const size = fileSize(part);
    if (size > 0 && (s.size <= 0 || size === s.size)) {
      try { fs.rmSync(dest, { force: true }); fs.renameSync(part, dest); o.copied++; continue; } catch {}
    }
    fs.rmSync(part, { force: true });
    o.failed.push(s.title);
  }
  return o;
}

/// Sends songs straight to a connected Android phone (Music/…, ringtones to Ringtones), through a temporary folder.
async function send(songs, device, phone, tools, job, progress = () => {}) {
  const staging = fs.mkdtempSync(path.join(os.tmpdir(), 'PortHop-music-'));
  const o = { copied: 0, skipped: 0, failed: [], cancelled: false };
  try {
    for (let n = 0; n < songs.length; n++) {
      if (job && job.cancelled) { o.cancelled = true; break; }
      const s = songs[n];
      progress(n, songs.length, s.title);
      const one = await copy([s], staging, device, tools, job);
      const local = path.join(staging, ...s.savedPath.split('/'));
      if (one.copied !== 1) { o.failed.push(s.title); continue; }
      const dir = s.isRingtone ? android.ROOT + '/Ringtones' : android.ROOT + '/Music/' + s.savedPath.split('/').slice(0, -1).join('/');
      const existing = new Set((await android.list(dir, phone, tools)).map((e) => e.name));
      if (existing.has(path.basename(local))) { o.skipped++; fs.rmSync(local, { force: true }); continue; }
      if (await android.mkdirs(dir, phone, tools) && await android.push(local, dir, existing, phone, tools, job)) {
        await android.scan([`${dir}/${path.basename(local)}`], phone, tools);
        o.copied++;
      } else o.failed.push(s.title);
      fs.rmSync(local, { force: true });
    }
  } finally { fs.rmSync(staging, { recursive: true, force: true }); }
  return o;
}

module.exports = { load, read, copy, send, DATABASE };
