'use strict';
// Makes standard device backups and reads them (plain or password-protected). Never writes into a backup.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const { pipeline } = require('node:stream/promises');
const { DatabaseSync } = require('node:sqlite');
const plist = require('./plist');
const { run, fileSize } = require('./shell');
const ios = require('./ios');

const TEMP_PREFIX = 'PortHop-bk-', LEGACY_TEMP_PREFIX = 'PhoneAlbumExtractor-bk-';
const pad = (n) => String(n).padStart(2, '0');

const KINDS = {
  messages: { title: 'Messages', groupWord: 'conversations' }, whatsapp: { title: 'WhatsApp', groupWord: 'conversations' },
  contacts: { title: 'Contacts' }, notes: { title: 'Notes' }, calendar: { title: 'Calendar', groupWord: 'calendars' },
  calls: { title: 'Call Log', needsEncrypted: true }, safari: { title: 'Safari', groupWord: 'lists' },
  photos: { title: 'Photos & Videos', groupWord: 'folders', files: true }, voiceMemos: { title: 'Voice Memos', files: true }, files: { title: 'Backup Files', groupWord: 'areas', files: true },
};

// Note text from ZICNOTEDATA.ZDATA: gzip-compressed protobuf, the text at NoteStoreProto.document(2).note(3).note_text(2).
// Locked notes stay unreadable (they are encrypted on the device) and fall back to the short preview.
function noteText(blob) {
  let raw;
  try { raw = blob[0] === 0x1f && blob[1] === 0x8b ? zlib.gunzipSync(blob) : blob[0] === 0x78 ? zlib.inflateSync(blob) : null; } catch { return null; }
  const doc = raw && protoField(raw, 2), note = doc && protoField(doc, 3), text = note && protoField(note, 2);
  return text ? text.toString('utf8') : null;
}
function protoField(b, number) {
  let o = 0;
  const varint = () => { let v = 0n, shift = 0n; while (o < b.length) { const x = b[o++]; v |= BigInt(x & 0x7f) << shift; if (!(x & 0x80)) return v; shift += 7n; if (shift > 63n) return null; } return null; };
  while (o < b.length) {
    const key = varint();
    if (key == null) return null;
    const wire = Number(key & 7n), field = Number(key >> 3n);
    if (wire === 0) { if (varint() == null) return null; }
    else if (wire === 1) o += 8;
    else if (wire === 2) { const len = varint(); if (len == null || len > BigInt(b.length - o)) return null; if (field === number) return b.subarray(o, o + Number(len)); o += Number(len); }
    else if (wire === 5) o += 4;
    else return null;
  }
  return null;
}
const vEsc = (s) => String(s ?? '').replace(/\\/g, '\\\\').replace(/;/g, '\;').replace(/,/g, '\\,').replace(/\r\n|\n/g, '\\n');
/// Long lines are folded at 75 bytes, as vCard and iCalendar require.
function fold(line) {
  let out = '', width = 0;
  for (const ch of line) {
    const n = Buffer.byteLength(ch);
    if (width + n > 75) { out += '\r\n '; width = 1; }
    out += ch; width += n;
  }
  return out;
}

function readPlist(file) { try { return plist.parse(fs.readFileSync(file)); } catch { return null; } }

function existing(folder) {
  let subs = [];
  try { subs = fs.readdirSync(folder, { withFileTypes: true }).filter((d) => d.isDirectory() && !d.name.startsWith('.')); } catch { return []; }
  const out = [];
  for (const d of subs) {
    const dir = path.join(folder, d.name);
    const info = readPlist(path.join(dir, 'Info.plist'));
    if (!info) continue;
    const man = readPlist(path.join(dir, 'Manifest.plist')) || {};
    const date = info['Last Backup Date'] instanceof Date ? info['Last Backup Date'] : null;
    out.push({ path: dir, deviceName: info['Device Name'] || d.name, date: date ? date.getTime() : null, encrypted: man.IsEncrypted === true, osVersion: info['Product Version'] || '' });
  }
  return out.sort((a, b) => (b.date || 0) - (a.date || 0));
}

/// Runs a backup. Resolves to null on success, otherwise a plain-language reason.
async function runBackup(device, tools, folder, job, onProgress) {
  if (!tools.backup) return 'The backup tool is missing from this copy of the app.';
  try { fs.mkdirSync(folder, { recursive: true }); } catch (e) { return `The backup folder could not be created: ${e.message}`; }
  let tail = '', success = false;
  const r = await run(tools.backup, [...ios.base(device), 'backup', folder], {
    onStart: (c) => job.track(c),
    onOutput: (chunk) => {
      tail = (tail + chunk).slice(-4000);
      if (chunk.includes('Backup Successful')) success = true;
      const all = [...tail.matchAll(/(\d{1,3})% Finished/g)];
      const percent = all.length ? Math.min(1, Number(all[all.length - 1][1]) / 100) : null;
      const line = tail.split(/[\r\n]+/).filter(Boolean).pop() || '';
      onProgress(percent, line.includes('Receiving') ? 'Receiving files…' : line.includes('Sending') ? 'Preparing…' : 'Backing up…');
    },
  });
  if (job.cancelled) return 'Backup stopped. Run it again to continue; finished files are kept.';
  if (success && r.ok) return null;
  const lower = tail.toLowerCase();
  if (lower.includes('passcode') || lower.includes('password protected') || lower.includes('locked')) return 'The device is locked. Unlock it, enter the passcode if it asks, and try again.';
  if (lower.includes('no space') || lower.includes('disk full')) return "The backup folder's disk is full.";
  const err = tail.split('\n').filter((l) => /ERROR|Error/.test(l)).pop();
  return err ? `The backup did not finish: ${err.trim()}` : 'The backup did not finish. Keep the device unlocked and connected, then try again.';
}

/// Puts a backup back onto a device, replacing its settings and app data. Resolves to null on success, otherwise a reason.
/// The password, when the backup has one, is handed to the tool privately (not on its command line).
async function runRestore(entry, device, tools, password, job, onProgress) {
  if (!tools.backup) return 'The backup tool is missing from this copy of the app.';
  if (entry.encrypted && !password) return 'This backup is protected by a password. Enter it to restore.';
  let tail = '', success = false;
  const r = await run(tools.backup, [...ios.base(device), '--source', path.basename(entry.path), 'restore', '--system', '--settings', '--reboot', path.dirname(entry.path)], {
    env: password ? { BACKUP_PASSWORD: password } : null,
    onStart: (c) => job.track(c),
    onOutput: (chunk) => {
      tail = (tail + chunk).slice(-4000);
      if (chunk.includes('Restore Successful')) success = true;
      const all = [...tail.matchAll(/(\d{1,3})% Finished/g)];
      onProgress(all.length ? Math.min(1, Number(all[all.length - 1][1]) / 100) : null, 'Restoring… do not unplug the device.');
    },
  });
  if (success && r.ok) return null;
  if (job.cancelled) return 'Restore stopped part-way. The device may be incomplete: run the restore again to finish it.';
  const lower = tail.toLowerCase();
  if (lower.includes('find my')) return 'Find My is turned on. On the device, open Settings, tap your name, Find My, and turn Find My off, then try again.';
  if (lower.includes('password')) return 'The backup password was not accepted.';
  // Otherwise show what the device itself said, and name the usual cause.
  const said = tail.split(/[\r\n]+/).filter((l) => /^ErrorCode \d+:/.test(l.trim())).pop();
  if (said) return `The device refused the restore (${said.trim()}). The usual cause is Find My being on: turn it off in Settings, your name, Find My, then try again.`;
  if (lower.includes('passcode') || lower.includes('locked')) return 'The device is locked. Unlock it, enter the passcode if it asks, and try again.';
  const err = tail.split('\n').filter((l) => /ERROR|Error/.test(l)).pop();
  return err ? `The restore did not finish: ${err.trim()}` : 'The restore did not finish. Keep the device unlocked and connected, then try again.';
}

// MARK: password-protected backups

function unwrap(wrapped, kek) {
  if (wrapped.length < 24 || wrapped.length % 8) return null;
  const n = wrapped.length / 8 - 1;
  let a = Buffer.from(wrapped.subarray(0, 8));
  const r = [];
  for (let i = 0; i < n; i++) r.push(Buffer.from(wrapped.subarray(8 + i * 8, 16 + i * 8)));
  for (let j = 5; j >= 0; j--) {
    for (let i = n - 1; i >= 0; i--) {
      const t = BigInt(n * j + i + 1);
      const x = Buffer.alloc(8); x.writeBigUInt64BE(a.readBigUInt64BE() ^ t);
      const d = crypto.createDecipheriv('aes-256-ecb', kek, null); d.setAutoPadding(false);
      const b = Buffer.concat([d.update(Buffer.concat([x, r[i]])), d.final()]);
      a = b.subarray(0, 8); r[i] = b.subarray(8);
    }
  }
  return a.equals(Buffer.alloc(8, 0xa6)) ? Buffer.concat(r) : null;
}

const pbkdf2 = (pw, salt, rounds, digest) => new Promise((res, rej) => crypto.pbkdf2(pw, salt, rounds, 32, digest, (e, k) => (e ? rej(e) : res(k))));

/// Derives the backup's class keys. Returns { keys } | { wrong: true } | { unreadable: true }.
async function unlock(bag, password) {
  const header = {}, classes = [];
  let cur = null;
  for (let i = 0; i + 8 <= bag.length;) {
    const tag = bag.toString('latin1', i, i + 4), n = bag.readUInt32BE(i + 4);
    if (i + 8 + n > bag.length) break;
    const value = bag.subarray(i + 8, i + 8 + n);
    i += 8 + n;
    if (tag === 'UUID' && !header.UUID) header.UUID = value;
    else if (tag === 'WRAP' && !header.WRAP && !cur) header.WRAP = value;
    else if (tag === 'UUID') { if (cur) classes.push(cur); cur = { UUID: value }; }
    else if (cur && ['CLAS', 'WRAP', 'WPKY', 'KTYP', 'PBKY'].includes(tag)) cur[tag] = value;
    else header[tag] = value;
  }
  if (cur) classes.push(cur);
  if (!header.SALT || !header.ITER || !header.DPSL || !header.DPIC) return { unreadable: true };
  const first = await pbkdf2(Buffer.from(password, 'utf8'), header.DPSL, header.DPIC.readUInt32BE(), 'sha256');
  const passKey = await pbkdf2(first, header.SALT, header.ITER.readUInt32BE(), 'sha1');
  const keys = new Map();
  let wrapped = 0;
  for (const c of classes) {
    if (!c.CLAS || !c.WPKY) continue;
    wrapped++;
    const k = unwrap(c.WPKY, passKey);
    if (!k) return { wrong: true };
    keys.set(c.CLAS.readUInt32BE(), k);
  }
  return wrapped ? { keys } : { unreadable: true };
}

async function decryptFile(source, dest, key, size) {
  const d = crypto.createDecipheriv('aes-256-cbc', key, Buffer.alloc(16)); d.setAutoPadding(false);
  await pipeline(fs.createReadStream(source), d, fs.createWriteStream(dest));
  if (size != null && size >= 0 && size <= fileSize(dest)) fs.truncateSync(dest, size);
}

function fileRecord(blob) {
  const p = plist.parseBinary(Buffer.from(blob));
  if (!p || !Array.isArray(p.$objects)) return null;
  let size = null, clas = null, key = null;
  for (const o of p.$objects) {
    if (Buffer.isBuffer(o) && o.length === 44) key = o;
    else if (o && typeof o === 'object' && !Array.isArray(o)) {
      if (typeof o.ProtectionClass === 'number') { clas = o.ProtectionClass; size = typeof o.Size === 'number' ? o.Size : null; }
      if (Buffer.isBuffer(o['NS.data']) && o['NS.data'].length === 44) key = o['NS.data'];
    }
  }
  if (!key) return null;
  return { clas: clas ?? key.readUInt32LE(0), size, wrapped: key.subarray(4) };
}

function purgeTemp() {
  try { for (const n of fs.readdirSync(os.tmpdir())) if (n.startsWith(TEMP_PREFIX) || n.startsWith(LEGACY_TEMP_PREFIX)) fs.rmSync(path.join(os.tmpdir(), n), { recursive: true, force: true }); } catch {}
}

// MARK: reading

const APPLE = 978307200;
function stamp(raw) {
  raw = Number(raw);
  if (!(raw > 0)) return '';
  const d = new Date(((raw > 1e11 ? raw / 1e9 : raw) + APPLE) * 1000);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
const addressKey = (a) => (a.includes('@') ? a.toLowerCase() : a.replace(/\D/g, '').slice(-10));

/// Newer systems keep the message text inside an archived object instead of the plain text column.
function textFromArchive(blob) {
  const b = Buffer.from(blob);
  const at = b.indexOf('NSString');
  if (at < 0) return null;
  let i = at + 8 + 5;
  if (i >= b.length) return null;
  let n = b[i++];
  if (n === 0x81) { if (i + 2 > b.length) return null; n = b.readUInt16LE(i); i += 2; }
  else if (n === 0x82) { if (i + 4 > b.length) return null; n = b.readUInt32LE(i); i += 4; } // very long messages
  if (n <= 0 || i + n > b.length) return null;
  return b.toString('utf8', i, i + n);
}

const FRIENDLY = { CameraRollDomain: 'Camera Roll', HomeDomain: 'Home (Messages, Contacts, Settings)', MediaDomain: 'Media', RootDomain: 'System Root', WirelessDomain: 'Mobile Network', KeychainDomain: 'Keychain' };
function friendly(domain) {
  for (const [p, l] of [['AppDomainGroup-', 'Shared: '], ['AppDomainPlugin-', 'Extension: '], ['AppDomain-', 'App: '], ['SysContainerDomain-', 'System: '], ['SysSharedContainerDomain-', 'System: ']]) {
    if (domain.startsWith(p)) return l + domain.slice(p.length);
  }
  return FRIENDLY[domain] || domain;
}

class BackupReader {
  constructor(folder, temp, manifest, keys) { this.folder = folder; this.temp = temp; this.manifest = manifest; this.keys = keys; this.dbs = []; }

  /// Resolves to { reader } | { needsPassword } | { wrongPassword } | { unreadable }.
  static async open(folder, password) {
    const man = readPlist(path.join(folder, 'Manifest.plist')) || {};
    const encrypted = man.IsEncrypted === true;
    let keys = null, manifestKey = null;
    if (encrypted) {
      if (!password) return { needsPassword: true };
      if (!Buffer.isBuffer(man.BackupKeyBag) || !Buffer.isBuffer(man.ManifestKey) || man.ManifestKey.length <= 4) return { unreadable: true };
      const u = await unlock(man.BackupKeyBag, password);
      if (u.wrong) return { wrongPassword: true };
      if (!u.keys) return { unreadable: true };
      keys = u.keys;
      const classKey = keys.get(man.ManifestKey.readUInt32LE(0));
      manifestKey = classKey && unwrap(man.ManifestKey.subarray(4), classKey);
      if (!manifestKey) return { unreadable: true };
    }
    purgeTemp();
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), TEMP_PREFIX));
    try {
      const copy = path.join(temp, 'Manifest.db');
      if (encrypted) await decryptFile(path.join(folder, 'Manifest.db'), copy, manifestKey, null);
      else fs.copyFileSync(path.join(folder, 'Manifest.db'), copy);
      const db = new DatabaseSync(copy);
      if (!db.prepare('PRAGMA table_info(Files)').all().some((c) => c.name === 'fileID')) throw new Error('not a manifest');
      return { reader: new BackupReader(folder, temp, db, keys) };
    } catch {
      fs.rmSync(temp, { recursive: true, force: true });
      return { unreadable: true };
    }
  }

  close() {
    for (const d of [...this.dbs, this.manifest]) { try { d.close(); } catch {} }
    fs.rmSync(this.temp, { recursive: true, force: true });
  }

  stored(id) { return path.join(this.folder, id.slice(0, 2), id); }

  fileID(domain, rel) {
    const r = this.manifest.prepare('SELECT fileID FROM Files WHERE domain=? AND relativePath=? LIMIT 1').get(domain, rel);
    return r && fs.existsSync(this.stored(r.fileID)) ? r.fileID : null;
  }

  /// A readable copy of one stored file: the file itself, or a decrypted working copy for protected backups.
  async plain(id) {
    if (!this.keys) return this.stored(id);
    const dir = path.join(this.temp, 'plain'), out = path.join(dir, id);
    if (fs.existsSync(out)) return out;
    const row = this.manifest.prepare('SELECT file FROM Files WHERE fileID=? LIMIT 1').get(id);
    const rec = row && row.file && fileRecord(row.file);
    const classKey = rec && this.keys.get(rec.clas);
    const key = classKey && unwrap(rec.wrapped, classKey);
    if (!key) return null;
    fs.mkdirSync(dir, { recursive: true });
    try { await decryptFile(this.stored(id), out, key, rec.size); return out; }
    catch { fs.rmSync(out, { force: true }); return null; }
  }

  /// Opens a database held in the backup, always on a working copy so the backup itself is never touched.
  async database(domain, rel) {
    const id = this.fileID(domain, rel);
    const main = id && await this.plain(id);
    if (!main) return null;
    const dir = fs.mkdtempSync(path.join(this.temp, 'db-'));
    const copy = path.join(dir, 'db.sqlite');
    try {
      fs.copyFileSync(main, copy);
      const walID = this.fileID(domain, rel + '-wal');
      const wal = walID && await this.plain(walID);
      if (wal && fileSize(wal) > 0) fs.copyFileSync(wal, copy + '-wal');
      const db = new DatabaseSync(copy);
      db.columns = (t) => new Set(db.prepare(`PRAGMA table_info("${t}")`).all().map((c) => c.name));
      this.dbs.push(db);
      return db;
    } catch { return null; }
  }

  async contactNames() {
    const db = await this.database('HomeDomain', 'Library/AddressBook/AddressBook.sqlitedb');
    const names = new Map();
    if (!db) return names;
    try {
      for (const r of db.prepare(`SELECT TRIM(COALESCE(p.First,'') || ' ' || COALESCE(p.Last,'')) n, COALESCE(p.Organization,'') o, v.value v
          FROM ABMultiValue v JOIN ABPerson p ON p.ROWID = v.record_id WHERE v.property IN (3, 4) AND v.value IS NOT NULL`).all()) {
        const name = r.n || r.o, k = addressKey(String(r.v));
        if (name && k) names.set(k, name);
      }
    } catch {}
    return names;
  }

  async load(kind) {
    let data;
    try { data = await this[kind](); } catch { data = { groups: [] }; }
    data.note = data.note || '';
    if (data.groups.every((g) => !g.rows.length) && !data.note) {
      const k = KINDS[kind];
      return { groups: [], note: k.needsEncrypted && !this.keys ? `${k.title} is only saved in encrypted backups, and this backup is not encrypted.` : `This backup has no ${k.title} data.` };
    }
    return data;
  }

  static newestFirst(groups) { return groups.sort((a, b) => ((b.rows.at(-1) || [''])[0] > (a.rows.at(-1) || [''])[0] ? 1 : -1)); }

  async messages() {
    const db = await this.database('HomeDomain', 'Library/SMS/sms.db');
    if (!db) return { groups: [] };
    const names = await this.contactNames();
    const who = (a) => names.get(addressKey(a)) || a;
    const archive = db.columns('message').has('attributedBody') ? 'm.attributedBody' : 'NULL';
    const groups = [], index = new Map(), place = new Map();   // message → [conversation, row], for attachments
    const rows = db.prepare(`SELECT c.ROWID chat, COALESCE(c.display_name,'') named, COALESCE(c.chat_identifier,'') ident, CAST(m.date AS REAL) date,
        m.is_from_me me, COALESCE(h.id,'') handle, m.text text, ${archive} body, COALESCE(m.cache_has_attachments, 0) att, m.ROWID mid
      FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id JOIN chat c ON c.ROWID = j.chat_id
      LEFT JOIN handle h ON h.ROWID = m.handle_id ORDER BY m.date`).all();
    for (const r of rows) {
      if (!index.has(r.chat)) { index.set(r.chat, groups.length); groups.push({ id: Number(r.chat), title: r.named || who(r.ident), subtitle: r.ident, columns: ['Date', 'From', 'Message'], rows: [] }); }
      let body = r.text || '';
      if (!body && r.body) body = textFromArchive(r.body) || '';
      body = body.replace(/￼/g, '').trim();
      if (!body) body = Number(r.att) ? '(attachment)' : '(no text)';
      const g = groups[index.get(r.chat)];
      g.rows.push([stamp(r.date), Number(r.me) ? 'Me' : who(r.handle), body]);
      place.set(Number(r.mid), [g, g.rows.length - 1]);
    }
    // Attachments live in MediaDomain under the path the message gives ("~/Library/SMS/Attachments/…").
    if (db.columns('attachment').has('filename') && db.columns('message_attachment_join').size) {
      for (const a of db.prepare("SELECT j.message_id mid, COALESCE(a.filename,'') f FROM message_attachment_join j JOIN attachment a ON a.ROWID = j.attachment_id").all()) {
        const at = place.get(Number(a.mid));
        if (!at) continue;
        let p = String(a.f);
        if (p.startsWith('~/')) p = p.slice(2); else if (p.includes('/Library/SMS/')) p = p.slice(p.indexOf('/Library/SMS/') + 1);
        if (!p) continue;
        const [g, row] = at;
        g.media = g.media || {};
        (g.media[row] = g.media[row] || []).push({ domain: 'MediaDomain', path: p });
      }
    }
    return { groups: BackupReader.newestFirst(groups) };
  }

  async whatsapp() {
    const db = await this.database('AppDomainGroup-group.net.whatsapp.WhatsApp.shared', 'ChatStorage.sqlite');
    if (!db) return { groups: [], note: 'WhatsApp is not in this backup. It is included only when WhatsApp is installed on the device.' };
    const groups = [], index = new Map();
    for (const r of db.prepare("SELECT Z_PK pk, COALESCE(ZPARTNERNAME,'') name, COALESCE(ZCONTACTJID,'') jid FROM ZWACHATSESSION").all()) {
      const number = r.jid.split('@')[0];
      index.set(r.pk, groups.length);
      groups.push({ id: Number(r.pk), title: r.name || number, subtitle: r.jid.endsWith('@g.us') ? 'Group' : number, columns: ['Date', 'From', 'Message'], rows: [] });
    }
    const cols = db.columns('ZWAMESSAGE');
    const push = cols.has('ZPUSHNAME') ? "COALESCE(ZPUSHNAME,'')" : "''";
    // Photos, videos and documents: the media item's path, under Message/ in WhatsApp's shared group.
    const media = cols.has('ZMEDIAITEM') && db.columns('ZWAMEDIAITEM').has('ZMEDIALOCALPATH')
      ? "COALESCE((SELECT ZMEDIALOCALPATH FROM ZWAMEDIAITEM WHERE Z_PK = ZWAMESSAGE.ZMEDIAITEM),'')" : "''";
    for (const r of db.prepare(`SELECT ZCHATSESSION chat, CAST(ZMESSAGEDATE AS REAL) date, ZISFROMME me, ZTEXT text, ${push} push, ${media} media FROM ZWAMESSAGE ORDER BY ZMESSAGEDATE`).all()) {
      const g = groups[index.get(r.chat)];
      if (!g) continue;
      const from = Number(r.me) ? 'Me' : (g.subtitle === 'Group' ? (r.push || 'Member') : g.title);
      g.rows.push([stamp(r.date), from, r.text || '(photo, video or other attachment)']);
      if (r.media) { g.media = g.media || {}; g.media[g.rows.length - 1] = [{ domain: 'AppDomainGroup-group.net.whatsapp.WhatsApp.shared', path: 'Message/' + String(r.media).replace(/^\//, '') }]; }
    }
    return { groups: BackupReader.newestFirst(groups.filter((g) => g.rows.length)) };
  }

  async contacts() {
    const db = await this.database('HomeDomain', 'Library/AddressBook/AddressBook.sqlitedb');
    if (!db) return { groups: [] };
    const phones = new Map(), mails = new Map();
    for (const r of db.prepare('SELECT record_id id, property p, value v FROM ABMultiValue WHERE property IN (3, 4) AND value IS NOT NULL').all()) {
      const m = Number(r.p) === 3 ? phones : mails;
      if (!m.has(r.id)) m.set(r.id, []);
      m.get(r.id).push(String(r.v));
    }
    const g = { id: 0, title: 'All Contacts', subtitle: '', columns: ['Name', 'Company', 'Phone', 'Email'], rows: [] };
    for (const r of db.prepare("SELECT ROWID id, TRIM(COALESCE(First,'') || ' ' || COALESCE(Last,'')) n, COALESCE(Organization,'') o FROM ABPerson ORDER BY 2 COLLATE NOCASE").all()) {
      g.rows.push([r.n, r.o, (phones.get(r.id) || []).join(', '), (mails.get(r.id) || []).join(', ')]);
    }
    return { groups: [g] };
  }

  async notes() {
    const db = await this.database('AppDomainGroup-group.com.apple.notes', 'NoteStore.sqlite');
    if (!db) return { groups: [] };
    const cols = db.columns('ZICCLOUDSYNCINGOBJECT');
    const title = ['ZTITLE1', 'ZTITLE'].find((c) => cols.has(c));
    if (!title) return { groups: [] };
    const snippet = cols.has('ZSNIPPET') ? "COALESCE(ZSNIPPET,'')" : "''";
    const modified = ['ZMODIFICATIONDATE1', 'ZMODIFICATIONDATE'].find((c) => cols.has(c)) || '0';
    const live = cols.has('ZMARKEDFORDELETION') ? 'AND COALESCE(n.ZMARKEDFORDELETION, 0) = 0' : '';
    // The whole text is in ZICNOTEDATA.ZDATA (compressed); some layouts point from the note to it, others back.
    const dataCols = db.columns('ZICNOTEDATA');
    const join = !dataCols.has('ZDATA') ? '' : cols.has('ZNOTEDATA') ? 'LEFT JOIN ZICNOTEDATA d ON d.Z_PK = n.ZNOTEDATA'
      : dataCols.has('ZNOTE') ? 'LEFT JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK' : '';
    const g = { id: 0, title: 'All Notes', subtitle: '', columns: ['Title', 'Text', 'Last changed'], rows: [] };
    for (const r of db.prepare(`SELECT n.${title} t, ${snippet.replace('ZSNIPPET', 'n.ZSNIPPET')} s, CAST(${modified === '0' ? '0' : 'n.' + modified} AS REAL) m, ${join ? 'd.ZDATA' : 'NULL'} z
        FROM ZICCLOUDSYNCINGOBJECT n ${join} WHERE n.${title} IS NOT NULL ${live} ORDER BY 3 DESC`).all()) {
      g.rows.push([r.t, (r.z && noteText(Buffer.from(r.z))) || r.s, stamp(r.m)]);
    }
    return { groups: [g] };
  }

  /// Photos and videos in the camera roll part of the backup, by device folder (100APPLE…). Useful when the phone is gone.
  async photos() {
    const groups = [], index = new Map();
    for (const r of this.manifest.prepare("SELECT relativePath p, fileID id FROM Files WHERE domain = 'CameraRollDomain' AND flags = 1 AND relativePath LIKE 'Media/DCIM/%' ORDER BY relativePath").all()) {
      const folder = path.posix.basename(path.posix.dirname(r.p));
      if (!index.has(folder)) { index.set(folder, groups.length); groups.push({ id: groups.length, title: folder, subtitle: 'Camera roll', columns: ['File', 'Kind'], rows: [], fileIDs: [] }); }
      const ext = path.posix.extname(r.p).slice(1).toUpperCase();
      const g = groups[index.get(folder)];
      g.rows.push([path.posix.basename(r.p), ['MOV', 'MP4', 'M4V'].includes(ext) ? 'Video' : ext === 'AAE' ? 'Edit settings' : 'Photo']);
      g.fileIDs.push(r.id);
    }
    return { groups };
  }

  /// Voice Memos: the recordings list (newer iOS keeps it in the app's shared group, older iOS in Media) and the audio files.
  async voiceMemos() {
    const places = [['AppDomainGroup-group.com.apple.VoiceMemos.shared', 'Recordings/CloudRecordings.db', 'ZCLOUDRECORDING', 'Recordings/'],
      ['MediaDomain', 'Media/Recordings/Recordings.db', 'ZRECORDING', 'Media/Recordings/']];
    const g = { id: 0, title: 'All Recordings', subtitle: '', columns: ['File', 'Recorded', 'Length'], rows: [], fileIDs: [] };
    const used = new Set();
    const safe = (s) => String(s).replace(/[\\/:*?"<>|\x00-\x1f]/g, '-').trim().replace(/[. ]+$/, '');
    for (const [domain, dbPath, table, folder] of places) {
      const db = await this.database(domain, dbPath);
      if (!db) continue;
      const cols = db.columns(table);
      if (!cols.has('ZPATH')) continue;
      const names = ['ZCUSTOMLABEL', 'ZENCRYPTEDTITLE'].filter((c) => cols.has(c)).map((c) => `NULLIF(TRIM(${c}), '')`);
      const title = !names.length ? 'NULL' : names.length === 1 ? names[0] : `COALESCE(${names.join(', ')})`;
      for (const r of db.prepare(`SELECT ${title} t, ZPATH p, CAST(${cols.has('ZDATE') ? 'ZDATE' : '0'} AS REAL) d, CAST(${cols.has('ZDURATION') ? 'ZDURATION' : '0'} AS REAL) n FROM ${table} ORDER BY 3 DESC`).all()) {
        const file = path.posix.basename(String(r.p || ''));
        const id = file && this.fileID(domain, folder + file);
        if (!id) continue;
        const ext = path.posix.extname(file).slice(1) || 'm4a';
        const label = r.t ? String(r.t) : file.replace(/\.[^.]*$/, '');
        let name = `${safe(label)}.${ext}`;
        if (used.has(name.toLowerCase())) name = `${safe(label)} ${id.slice(0, 6)}.${ext}`;
        used.add(name.toLowerCase());
        const secs = Math.round(Number(r.n) || 0);
        g.rows.push([name, stamp(r.d), `${Math.floor(secs / 60)}:${pad(secs % 60)}`]);
        g.fileIDs.push(id);
      }
    }
    return { groups: [g] };
  }

  /// The contact list as a vCard 3.0 file, which Contacts, Outlook, Gmail and Android all import. Same output as the Mac.
  async vCard() {
    const db = await this.database('HomeDomain', 'Library/AddressBook/AddressBook.sqlitedb');
    if (!db) return null;
    const phones = new Map(), mails = new Map();
    for (const r of db.prepare('SELECT record_id id, property p, value v FROM ABMultiValue WHERE property IN (3, 4) AND value IS NOT NULL').all()) {
      const m = Number(r.p) === 3 ? phones : mails;
      if (!m.has(r.id)) m.set(r.id, []);
      m.get(r.id).push(String(r.v));
    }
    let out = '';
    for (const r of db.prepare("SELECT ROWID id, COALESCE(First,'') f, COALESCE(Last,'') l, COALESCE(Organization,'') o FROM ABPerson ORDER BY ROWID").all()) {
      const full = [r.f, r.l].filter(Boolean).join(' ');
      const card = ['BEGIN:VCARD', 'VERSION:3.0', `N:${vEsc(r.l)};${vEsc(r.f)};;;`, `FN:${vEsc(full || r.o)}`];
      if (r.o) card.push(`ORG:${vEsc(r.o)}`);
      for (const t of phones.get(r.id) || []) card.push(`TEL;TYPE=VOICE:${vEsc(t)}`);
      for (const e of mails.get(r.id) || []) card.push(`EMAIL;TYPE=INTERNET:${vEsc(e)}`);
      card.push('END:VCARD');
      out += card.map(fold).join('\r\n') + '\r\n';
    }
    return out || null;
  }

  /// The calendars as one iCalendar (.ics) file for Calendar, Outlook or Google Calendar. Same output as the Mac.
  async iCalendar() {
    const db = await this.database('HomeDomain', 'Library/Calendar/Calendar.sqlitedb');
    if (!db) return null;
    const iso = (t) => new Date((Number(t) + APPLE) * 1000).toISOString();
    const utc = (t) => iso(t).replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z'), day = (t) => iso(t).slice(0, 10).replace(/-/g, '');
    const now = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
    const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//PortHop//Backup export//EN', 'CALSCALE:GREGORIAN'];
    for (const r of db.prepare(`SELECT i.ROWID id, COALESCE(i.summary,'') s, CAST(i.start_date AS REAL) a, CAST(i.end_date AS REAL) b, COALESCE(i.all_day, 0) d, COALESCE(c.title,'Calendar') cal
        FROM CalendarItem i LEFT JOIN Calendar c ON c.ROWID = i.calendar_id ORDER BY i.start_date`).all()) {
      const allDay = !!Number(r.d), end = Math.max(Number(r.b), Number(r.a) + (allDay ? 86400 : 0));
      lines.push('BEGIN:VEVENT', `UID:porthop-${r.id}@backup`, `DTSTAMP:${now}`, allDay ? `DTSTART;VALUE=DATE:${day(r.a)}` : `DTSTART:${utc(r.a)}`,
        allDay ? `DTEND;VALUE=DATE:${day(end)}` : `DTEND:${utc(end)}`, `SUMMARY:${vEsc(r.s)}`, `CATEGORIES:${vEsc(r.cal)}`, 'END:VEVENT');
    }
    if (lines.length <= 4) return null;
    lines.push('END:VCALENDAR');
    return lines.map(fold).join('\r\n') + '\r\n';
  }

  async calendar() {
    const db = await this.database('HomeDomain', 'Library/Calendar/Calendar.sqlitedb');
    if (!db) return { groups: [] };
    const groups = [], index = new Map();
    for (const r of db.prepare(`SELECT COALESCE(c.title,'Calendar') cal, COALESCE(i.summary,'') s, CAST(i.start_date AS REAL) a, CAST(i.end_date AS REAL) b, COALESCE(i.all_day, 0) d
        FROM CalendarItem i LEFT JOIN Calendar c ON c.ROWID = i.calendar_id ORDER BY i.start_date DESC`).all()) {
      if (!index.has(r.cal)) { index.set(r.cal, groups.length); groups.push({ id: groups.length, title: r.cal, subtitle: '', columns: ['Event', 'Starts', 'Ends'], rows: [] }); }
      const start = stamp(r.a);
      groups[index.get(r.cal)].rows.push([r.s, Number(r.d) ? start.slice(0, 10) : start, Number(r.d) ? 'All day' : stamp(r.b)]);
    }
    return { groups };
  }

  async calls() {
    const db = await this.database('HomeDomain', 'Library/CallHistoryDB/CallHistory.storedata');
    if (!db) return { groups: [] };
    const names = await this.contactNames();
    const g = { id: 0, title: 'All Calls', subtitle: '', columns: ['Who', 'Number', 'Date', 'Length', 'Kind'], rows: [] };
    for (const r of db.prepare('SELECT CAST(ZADDRESS AS TEXT) a, CAST(ZDATE AS REAL) d, ZDURATION s, ZORIGINATED o, ZANSWERED n FROM ZCALLRECORD ORDER BY ZDATE DESC').all()) {
      const secs = Math.floor(Number(r.s) || 0), number = r.a || '';
      g.rows.push([names.get(addressKey(number)) || '', number, stamp(r.d), `${Math.floor(secs / 60)}:${pad(secs % 60)}`, Number(r.o) ? 'Outgoing' : (Number(r.n) ? 'Incoming' : 'Missed')]);
    }
    return { groups: [g] };
  }

  async safari() {
    const groups = [];
    let db = await this.database('HomeDomain', 'Library/Safari/Bookmarks.db');
    if (db) {
      const g = { id: 0, title: 'Bookmarks', subtitle: '', columns: ['Title', 'Address'], rows: [] };
      for (const r of db.prepare("SELECT COALESCE(title,'') t, url u FROM bookmarks WHERE url IS NOT NULL AND url != '' ORDER BY title COLLATE NOCASE").all()) g.rows.push([r.t, r.u]);
      groups.push(g);
    }
    db = await this.database('AppDomain-com.apple.mobilesafari', 'Library/Safari/History.db');
    if (db) {
      const g = { id: 1, title: 'History', subtitle: '', columns: ['Title', 'Address', 'Visited'], rows: [] };
      for (const r of db.prepare("SELECT COALESCE(v.title,'') t, i.url u, CAST(v.visit_time AS REAL) d FROM history_visits v JOIN history_items i ON i.id = v.history_item ORDER BY v.visit_time DESC").all()) g.rows.push([r.t, r.u, stamp(r.d)]);
      groups.push(g);
    }
    return { groups: groups.filter((g) => g.rows.length) };
  }

  async files() {
    const groups = [], index = new Map();
    for (const r of this.manifest.prepare('SELECT domain, relativePath, fileID FROM Files WHERE flags = 1 ORDER BY domain, relativePath').all()) {
      if (!index.has(r.domain)) { index.set(r.domain, groups.length); groups.push({ id: groups.length, title: friendly(r.domain), subtitle: r.domain, columns: ['File', 'Folder'], rows: [], fileIDs: [] }); }
      const g = groups[index.get(r.domain)];
      g.rows.push([path.posix.basename(r.relativePath), path.posix.dirname(r.relativePath) === '.' ? '' : path.posix.dirname(r.relativePath)]);
      g.fileIDs.push(r.fileID);
    }
    return { groups };
  }

  /// A conversation as a web page anyone can open: a folder with index.html and the attachments that are in the backup.
  /// Same page as the Mac edition writes. Returns the page's path, or null. Never overwrites.
  async webPage(group, kindTitle, folder) {
    const { uniquePath } = require('./shell');
    const safe = String(group.title).replace(/[\\/:*?"<>|\r\n]/g, '-').trim().slice(0, 80) || 'Untitled';
    const preferred = path.join(folder, `${safe} (${kindTitle})`);
    const dir = fs.existsSync(preferred) ? uniquePath(preferred) : preferred;
    const files = path.join(dir, 'attachments');
    try { fs.mkdirSync(files, { recursive: true }); } catch { return null; }
    const esc = (t) => String(t).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/\n/g, '<br>');
    const used = new Set();
    let body = '';
    for (const [r, row] of group.rows.entries()) {
      let extras = '';
      for (const ref of (group.media && group.media[r]) || []) {
        const base = ref.path.split('/').pop();
        const id = this.fileID(ref.domain, ref.path), src = id && await this.plain(id);
        if (!src) { extras += `<div class="missing">Attachment not in this backup: ${esc(base)}</div>`; continue; }
        let name = base, n = 2;
        const dot = base.lastIndexOf('.'), stem = dot > 0 ? base.slice(0, dot) : base, ext = dot > 0 ? base.slice(dot + 1) : '';
        while (used.has(name.toLowerCase())) name = `${stem} (${n++})${ext ? '.' + ext : ''}`;
        used.add(name.toLowerCase());
        try { fs.copyFileSync(src, path.join(files, name), fs.constants.COPYFILE_EXCL); } catch { continue; }
        const link = 'attachments/' + encodeURIComponent(name);
        if (/^(jpe?g|png|gif|heic|webp)$/i.test(ext)) extras += `<a href="${link}"><img src="${link}" alt="${esc(name)}"></a>`;
        else if (/^(mov|mp4|m4v)$/i.test(ext)) extras += `<video controls src="${link}"></video>`;
        else extras += `<a class="file" href="${link}">${esc(name)}</a>`;
      }
      const text = /^\(.*\)$/.test(row[2]) && extras ? '' : esc(row[2]);
      body += `<div class="msg${row[1] === 'Me' ? ' me' : ''}"><div class="meta">${esc(row[1])} · ${esc(row[0])}</div>${text ? `<div class="text">${text}</div>` : ''}${extras}</div>\n`;
    }
    const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(group.title)}</title>
<style>
:root { color-scheme: light dark; --me: #0a84ff; --them: #e9e9eb; --themText: #000; }
@media (prefers-color-scheme: dark) { :root { --them: #2c2c2e; --themText: #fff; } }
body { font: 15px/1.4 -apple-system, "Segoe UI", Roboto, sans-serif; max-width: 760px; margin: 0 auto; padding: 24px 16px; }
h1 { font-size: 22px; margin: 0 0 4px; } .sub { opacity: .6; margin-bottom: 20px; }
.msg { max-width: 75%; margin: 8px 0; } .msg.me { margin-left: auto; text-align: right; }
.meta { font-size: 12px; opacity: .55; margin: 0 8px 2px; }
.text { display: inline-block; text-align: left; padding: 8px 12px; border-radius: 18px; background: var(--them); color: var(--themText); overflow-wrap: anywhere; }
.me .text { background: var(--me); color: #fff; }
img, video { display: block; max-width: 320px; max-height: 320px; border-radius: 14px; margin: 4px 0 0 auto; } .msg:not(.me) img, .msg:not(.me) video { margin-left: 0; }
.file, .missing { display: inline-block; padding: 6px 10px; border-radius: 10px; background: var(--them); color: var(--themText); margin-top: 4px; font-size: 13px; }
.missing { opacity: .6; }
</style></head><body>
<h1>${esc(group.title)}</h1><div class="sub">${esc(kindTitle)} · ${group.rows.length} messages · saved by PortHop from a device backup</div>
${body}</body></html>`;
    const page = path.join(dir, 'index.html');
    try { fs.writeFileSync(page, html, { flag: 'wx' }); } catch { return null; }
    try { if (!fs.readdirSync(files).length) fs.rmdirSync(files); } catch {}
    return page;
  }

  /// Copies files out of the backup under their real names. Never overwrites. Returns the files written.
  async extract(group, rows, folder) {
    const written = [], reserved = new Set();
    const { uniquePath } = require('./shell');
    for (const r of rows) {
      if (!group.fileIDs || r >= group.fileIDs.length) continue;
      let name = String(group.rows[r][0]).replace(/[\\/:*?"<>|\u0000-\u001f]/g, '-').replace(/[. ]+$/, '');
      if (!name || /^(con|prn|aux|nul|com\d|lpt\d)(\..*)?$/i.test(name)) name = (name ? '_' + name : group.fileIDs[r]);   // names Windows keeps for devices
      const dest = uniquePath(path.join(folder, name), reserved);
      reserved.add(dest);
      const source = await this.plain(group.fileIDs[r]);
      try { if (source) { fs.copyFileSync(source, dest, fs.constants.COPYFILE_EXCL); written.push(dest); } } catch {}
    }
    return written;
  }
}

function csv(group) {
  const cell = (s) => '"' + String(s ?? '').replace(/"/g, '""') + '"';
  return [group.columns, ...group.rows].map((r) => r.map(cell).join(',')).join('\r\n') + '\r\n';
}

module.exports = { KINDS, existing, runBackup, runRestore, BackupReader, csv, purgeTemp, unwrap, textFromArchive, stamp };
