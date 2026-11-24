'use strict';
// Checks a phone against published spyware indicators: the STIX2 files that Amnesty International, Citizen Lab and others
// publish (the format of Amnesty's Mobile Verification Toolkit). An iPhone is checked through its newest backup, an Android
// phone live over USB. A match is a reason to ask an expert, not proof; no match is not a guarantee. Same rules as the Mac app.
const fs = require('node:fs');
const path = require('node:path');
const plist = require('./plist');
const { textFromArchive, stamp } = require('./backup');
const android = require('./android');
const { supportDir } = require('./shell');

const KINDS = { 'domain-name:value': 'domain', 'url:value': 'url', 'process:name': 'process', 'email-addr:value': 'email',
  'file:name': 'fileName', 'file:path': 'filePath', 'app:id': 'appID', 'configuration-profile:id': 'profile' };
const INDEX_URL = 'https://raw.githubusercontent.com/mvt-project/mvt-indicators/main/indicators.yaml';

/// The host in "https://user@host.example:8080/path", "host.example/path" or "host.example"; null when it isn't one.
function hostOf(token) {
  let s = String(token).toLowerCase();
  const scheme = s.indexOf('://');
  if (scheme >= 0) s = s.slice(scheme + 3);
  const end = s.search(/[/?#]/);
  if (end >= 0) s = s.slice(0, end);
  const at = s.lastIndexOf('@');
  if (at >= 0) s = s.slice(at + 1);
  const colon = s.indexOf(':');
  if (colon >= 0) s = s.slice(0, colon);
  const labels = s.split('.');
  const tld = labels[labels.length - 1];
  if (labels.length < 2 || tld.length < 2 || !/^\p{L}+$/u.test(tld)) return null;
  if (!labels.every((l) => l.length > 0 && l.length <= 63 && /^[\p{L}\p{N}-]+$/u.test(l))) return null;
  return s;
}

function normal(kind, value) {
  let v = String(value).trim().toLowerCase();
  if (kind === 'domain' && v.startsWith('www.')) v = v.slice(4);
  if (kind === 'filePath' && v.length > 1 && v.endsWith('/')) v = v.slice(0, -1);
  if (kind === 'domain') v = v.replace(/^\.+|\.+$/g, '');
  return v;
}

/// Indicators by kind, then by lowercased value.
class Indicators {
  constructor() { this.table = new Map(); this.count = 0; }
  get isEmpty() { return this.count === 0; }
  add(i) {
    const key = normal(i.kind, i.value);
    if (!key) return;
    if (!this.table.has(i.kind)) this.table.set(i.kind, new Map());
    const t = this.table.get(i.kind);
    const list = t.get(key) || [];
    if (list.some((x) => x.malware === i.malware)) return;
    list.push(i); t.set(key, list); this.count++;
  }
  lookup(kind, value) { return (this.table.get(kind) && this.table.get(kind).get(normal(kind, value))) || []; }
  /// A host matches an indicator domain when it is that domain or one of its subdomains.
  domainHits(host) {
    const domains = this.table.get('domain');
    if (!domains) return [];
    const labels = normal('domain', host).split('.');
    const out = [];
    while (labels.length >= 2) { const hit = domains.get(labels.join('.')); if (hit) out.push(...hit); labels.shift(); }
    return out;
  }
  /// Device usage logs cut process names to 15 or 16 characters, so a cut name matches the longer indicator.
  processHits(name) {
    const n = normal('process', name), all = this.table.get('process');
    if (!n || !all) return [];
    if (all.has(n)) return all.get(n);
    if (n.length !== 15 && n.length !== 16) return [];
    return [...all].filter(([k]) => k.startsWith(n)).flatMap(([, v]) => v);
  }
  /// Addresses and web links in a piece of text (a message, say) that point at an indicator domain or link.
  /// One pass over the words, so a very long message takes no longer than its length.
  textHits(text) {
    const out = [];
    if (!text) return out;
    if (this.table.has('domain') && String(text).includes('.')) {
      for (const word of String(text).split(/[\s"'<>()[\]{}|\\^`,;]+/)) {
        if (!word.includes('.')) continue;
        const token = word.replace(/^[.:!?*]+|[.:!?*]+$/g, '');
        const host = hostOf(token);
        if (host) for (const i of this.domainHits(host)) out.push([token, i]);
      }
    }
    const urls = this.table.get('url');
    if (urls && urls.size) { const lower = String(text).toLowerCase(); for (const [v, list] of urls) if (lower.includes(v)) for (const i of list) out.push([v, i]); }
    return out;
  }
}

function parsePattern(pattern) {
  const body = String(pattern).replace(/^[\[\] \n]+|[\[\] \n]+$/g, '');
  const eq = body.indexOf('=');
  if (eq < 0) return null;
  const kind = KINDS[body.slice(0, eq).trim()], value = body.slice(eq + 1).replace(/^[ '"]+|[ '"]+$/g, '');
  return kind && value ? [kind, value] : null;
}

/// Reads one STIX2 file. Each indicator is credited to the spyware it "indicates" (or the file's only family).
function parseSTIX(data, source) {
  let root;
  try { root = JSON.parse(Buffer.isBuffer(data) ? data.toString('utf8') : data); } catch { return []; }
  const objects = Array.isArray(root && root.objects) ? root.objects : [];
  const families = new Map(), indicates = new Map();
  for (const o of objects) {
    if (o.type === 'malware' && o.id) families.set(o.id, o.name || source);
    if (o.type === 'relationship' && o.relationship_type === 'indicates' && o.source_ref && o.target_ref) indicates.set(o.source_ref, o.target_ref);
  }
  const only = families.size === 1 ? [...families.values()][0] : null;
  const out = [];
  for (const o of objects) {
    if (o.type !== 'indicator' || typeof o.pattern !== 'string') continue;
    const p = parsePattern(o.pattern);
    if (!p) continue;
    out.push({ kind: p[0], value: p[1], malware: families.get(indicates.get(o.id)) || only || source, source });
  }
  return out;
}

const slug = (s) => String(s).toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-+|-+$/g, '');

/// Reads the index (a small YAML list). Only the fields PortHop needs are read: a name and where the file lives.
function parseIndex(yaml) {
  const out = [];
  let f = {};
  const flush = () => {
    if (f.name) {
      let url = f.download_url;
      if (!url && f.owner && f.repo && f.path) url = `https://raw.githubusercontent.com/${f.owner}/${f.repo}/${f.branch || 'main'}/${f.path}`;
      if (url && url.startsWith('https://')) out.push({ name: f.name, url, file: slug(f.name) + '.stix2' });
    }
    f = {};
  };
  for (const raw of String(yaml).split('\n')) {
    let line = raw.trim();
    if (line.startsWith('-') && raw.match(/^ */)[0].length <= 2) { flush(); line = line.slice(1).trim(); }
    const c = line.indexOf(':');
    if (c < 0) continue;
    const key = line.slice(0, c).replace(/^[- ]+|[- ]+$/g, ''), value = line.slice(c + 1).replace(/^[ '"]+|[ '"]+$/g, '');
    if (value && ['name', 'owner', 'repo', 'branch', 'path', 'download_url'].includes(key) && f[key] == null) f[key] = value;
  }
  flush();
  return out;
}

function folder() { return process.env.PORTHOP_INDICATORS_DIR || path.join(supportDir(), 'Indicators'); }
function sources(dir = folder()) { try { return JSON.parse(fs.readFileSync(path.join(dir, 'sources.json'), 'utf8')); } catch { return []; } }
function save(list, dir) { fs.writeFileSync(path.join(dir, 'sources.json'), JSON.stringify(list, null, 2)); }

function load(dir = folder()) {
  const set = new Indicators();
  for (const s of sources(dir)) {
    let d;
    try { d = fs.readFileSync(path.join(dir, s.file)); } catch { continue; }
    for (const i of parseSTIX(d, s.name)) set.add(i);
  }
  return set;
}

/// Downloads the current public indicator files. Resolves to null when they were saved, or what went wrong.
async function download(dir = folder(), index = INDEX_URL, fetchImpl = fetch) {
  fs.mkdirSync(dir, { recursive: true });
  const get = async (url) => {
    try { const r = await fetchImpl(url, { headers: { 'User-Agent': 'PortHop' } }); return r.ok ? Buffer.from(await r.arrayBuffer()) : null; } catch { return null; }
  };
  const text = await get(index);
  if (!text) return 'The list of indicator files could not be downloaded. Check the internet connection and try again.';
  const wanted = parseIndex(text.toString('utf8'));
  if (!wanted.length) return 'The list of indicator files was empty or in an unexpected format.';
  const fetched = await Promise.all(wanted.map(async (s) => [s, await get(s.url)]));
  const kept = sources(dir).filter((s) => String(s.url).startsWith('file:'));
  const saved = [];
  for (const [s, data] of fetched) {
    if (!data) continue;
    const n = parseSTIX(data, s.name).length;
    if (!n) continue;
    try { fs.writeFileSync(path.join(dir, s.file), data); } catch { continue; }
    saved.push({ ...s, count: n, updated: new Date().toISOString() });
  }
  if (!saved.length) return 'None of the indicator files could be downloaded. Try again later.';
  save([...saved.sort((a, b) => (a.name < b.name ? -1 : 1)), ...kept], dir);
  return saved.length < wanted.length ? `${saved.length} of ${wanted.length} indicator files were downloaded; the others were not available.` : null;
}

/// Adds an indicator file the user chose (one an investigator sent, say). Resolves to null when it was added.
function addFile(file, dir = folder()) {
  let d;
  try { d = fs.readFileSync(file); } catch { return 'The file could not be read.'; }
  const name = path.basename(file, path.extname(file));
  const n = parseSTIX(d, name).length;
  if (!n) return 'This is not an indicator file PortHop can read (STIX2, as used by the Mobile Verification Toolkit).';
  fs.mkdirSync(dir, { recursive: true });
  const fileName = 'custom-' + slug(name) + '.stix2';
  try { fs.writeFileSync(path.join(dir, fileName), d); } catch { return 'The file could not be saved.'; }
  save([...sources(dir).filter((s) => s.file !== fileName), { name, url: 'file:' + file, file: fileName, count: n, updated: new Date().toISOString() }], dir);
  return null;
}

const ROOTS = { HomeDomain: '/private/var/mobile', MediaDomain: '/private/var/mobile', CameraRollDomain: '/private/var/mobile', RootDomain: '/private/var/root',
  WirelessDomain: '/private/var/wireless', SystemPreferencesDomain: '/private/var/preferences', DatabaseDomain: '/private/var/db',
  ManagedPreferencesDomain: '/private/var/Managed Preferences', KeychainDomain: '/private/var/Keychains', NetworkDomain: '/private/var/networkd',
  ProtectedDomain: '/private/var/protected', InstallDomain: '/private/var/installd', MobileDeviceDomain: '/private/var/MobileDevice',
  KeyboardDomain: '/private/var/mobile', TonesDomain: '/private/var/mobile', HealthDomain: '/private/var/mobile/Library' };

function unique(list) {
  const seen = new Set();
  return list.filter((f) => { const k = `${f.area}|${f.found.toLowerCase()}|${f.indicator.value}|${f.indicator.malware}`; if (seen.has(k)) return false; seen.add(k); return true; });
}

/// Checks a backup opened with BackupReader (never changed).
async function scanBackup(r, set) {
  const report = { findings: [], checked: [], missing: [], review: [], warnings: [], indicatorCount: set.count, date: new Date().toISOString() };
  const found = (area, value, hits, when = '') => { for (const i of hits) report.findings.push({ area, found: value, indicator: i, when }); };
  const area = (name, present) => (present ? report.checked : report.missing).push(name);
  const rows = (db, sql) => { try { return db.prepare(sql).all(); } catch { return []; } };
  const contents = async (domain, rel) => { const id = r.fileID(domain, rel); const p = id && await r.plain(id); try { return p ? fs.readFileSync(p) : null; } catch { return null; } };

  let history = false;
  for (const [domain, rel] of [['AppDomain-com.apple.mobilesafari', 'Library/Safari/History.db'], ['HomeDomain', 'Library/Safari/History.db']]) {
    const db = await r.database(domain, rel);
    if (!db) continue;
    history = true;
    for (const row of rows(db, 'SELECT i.url u, CAST(COALESCE(MAX(v.visit_time), 0) AS REAL) t FROM history_items i LEFT JOIN history_visits v ON v.history_item = i.id GROUP BY i.id')) {
      for (const [what, i] of set.textHits(row.u)) found('Safari history', what, [i], stamp(row.t));
    }
  }
  area('Safari history', history);

  let tabs = false;
  const tabsDb = await r.database('AppDomain-com.apple.mobilesafari', 'Library/Safari/SafariTabs.db');
  if (tabsDb) { tabs = true; for (const row of rows(tabsDb, 'SELECT url u FROM bookmarks WHERE url IS NOT NULL')) for (const [w, i] of set.textHits(row.u)) found('Safari tabs', w, [i]); }
  for (const domain of ['AppDomain-com.apple.mobilesafari', 'HomeDomain']) {
    const db = await r.database(domain, 'Library/Safari/BrowserState.db');
    if (!db) continue;
    tabs = true;
    for (const row of rows(db, 'SELECT url u FROM tabs')) for (const [w, i] of set.textHits(row.u)) found('Safari tabs', w, [i]);
  }
  area('Safari tabs', tabs);

  const marks = await r.database('HomeDomain', 'Library/Safari/Bookmarks.db');
  area('Safari bookmarks', !!marks);
  if (marks) for (const row of rows(marks, 'SELECT url u FROM bookmarks WHERE url IS NOT NULL')) for (const [w, i] of set.textHits(row.u)) found('Safari bookmarks', w, [i]);

  const sms = await r.database('HomeDomain', 'Library/SMS/sms.db');
  area('Messages', !!sms);
  if (sms) {
    const archive = sms.columns('message').has('attributedBody') ? 'm.attributedBody' : 'NULL';
    for (const row of rows(sms, `SELECT m.text t, ${archive} a, CAST(m.date AS REAL) d, COALESCE(h.id,'') h FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id`)) {
      let body = row.t || '';
      if (!body && row.a) body = textFromArchive(row.a) || '';
      const when = stamp(row.d);
      for (const [w, i] of set.textHits(body)) found('Messages', w, [i], when);
      if (String(row.h).includes('@')) found('Messages (sender)', row.h, set.lookup('email', row.h), when);
    }
  }

  const wa = await r.database('AppDomainGroup-group.net.whatsapp.WhatsApp.shared', 'ChatStorage.sqlite');
  area('WhatsApp', !!wa);
  if (wa) for (const row of rows(wa, 'SELECT COALESCE(ZTEXT,\'\') t, COALESCE(ZMESSAGEDATE,0) d FROM ZWAMESSAGE WHERE ZTEXT IS NOT NULL')) {
    for (const [w, i] of set.textHits(row.t)) found('WhatsApp', w, [i], stamp(row.d));
  }

  const webData = [], apps = new Set(), profiles = [];
  const filePaths = set.table.get('filePath') || new Map();
  for (const row of r.manifest.prepare('SELECT domain, relativePath FROM Files WHERE flags = 1').iterate()) {
    const domain = row.domain, rel = row.relativePath;
    if (rel.endsWith('ResourceLoadStatistics/observations.db')) webData.push([domain, rel]);
    if (domain === 'SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles') profiles.push([domain, rel]);
    for (const prefix of ['AppDomain-', 'AppDomainPlugin-']) if (domain.startsWith(prefix)) apps.add(domain.slice(prefix.length));
    found('Backup files', `${domain} › ${rel}`, set.lookup('fileName', rel.split('/').pop()));
    const root = ROOTS[domain];
    if (root) {
      const full = (root + '/' + rel).toLowerCase();
      for (const [value, list] of filePaths) if (full === value || full.startsWith(value + '/')) found('Backup files', root + '/' + rel, list);
    }
  }
  area('Backup files', true);
  for (const [domain, rel] of webData) {
    const db = await r.database(domain, rel);
    if (!db) continue;
    for (const row of rows(db, 'SELECT registrableDomain h, COALESCE(mostRecentUserInteractionTime, 0) t FROM ObservedDomains')) {
      found('Websites apps loaded', row.h, set.domainHits(row.h), row.t > 0 ? stamp(row.t - 978307200) : '');
    }
  }
  area('Websites apps loaded', webData.length > 0);

  const usage = await r.database('WirelessDomain', 'Library/Databases/DataUsage.sqlite');
  area('App network use', !!usage);
  if (usage) for (const row of rows(usage, "SELECT COALESCE(ZPROCNAME,'') p, COALESCE(ZBUNDLENAME,'') b, CAST(COALESCE(ZTIMESTAMP, ZFIRSTTIMESTAMP, 0) AS REAL) t FROM ZPROCESS")) {
    const when = stamp(row.t);
    found('App network use', row.p, set.processHits(row.p), when);
    if (row.b) found('App network use', row.b, set.lookup('appID', row.b), when);
  }

  const daily = await contents('HomeDomain', 'Library/Preferences/com.apple.osanalytics.addaily.plist');
  let dailyPlist = null;
  try { dailyPlist = daily && plist.parse(daily); } catch {}
  area('Daily usage statistics', !!dailyPlist);
  if (dailyPlist) for (const name of Object.keys(dailyPlist.netUsageBaseline || {})) found('Daily usage statistics', name, set.processHits(name));

  const ids = await contents('HomeDomain', 'Library/Preferences/com.apple.identityservices.idstatuscache.plist');
  let idsPlist = null;
  try { idsPlist = ids && plist.parse(ids); } catch {}
  area('iMessage and FaceTime lookups', !!idsPlist);
  if (idsPlist) {
    const handles = new Set();
    const walk = (v) => {
      if (Array.isArray(v)) v.forEach(walk);
      else if (v && typeof v === 'object' && !Buffer.isBuffer(v) && !(v instanceof Date)) for (const [k, sub] of Object.entries(v)) { if (k.toLowerCase().startsWith('mailto:')) handles.add(k.slice(7)); walk(sub); }
    };
    walk(idsPlist);
    for (const h of [...handles].sort()) found('iMessage and FaceTime lookups', h, set.lookup('email', h));
  }

  let info = null;
  try { info = plist.parse(fs.readFileSync(path.join(r.folder, 'Info.plist'))); } catch {}
  if (info) { for (const id of info['Installed Applications'] || []) apps.add(id); for (const id of Object.keys(info.Applications || {})) apps.add(id); }
  for (const id of [...apps].sort()) found('Installed apps', id, set.lookup('appID', id));
  area('Installed apps', apps.size > 0);

  const profileIDs = set.table.get('profile');
  if (profiles.length && profileIDs && profileIDs.size) {
    for (const [domain, rel] of profiles) {
      const d = await contents(domain, rel);
      if (!d) continue;
      const text = d.toString('latin1').toLowerCase();
      for (const [value, list] of profileIDs) if (text.includes(value)) found('Configuration profiles', rel.split('/').pop(), list);
    }
  }
  area('Configuration profiles', profiles.length > 0);
  report.findings = unique(report.findings);
  return report;
}

/// Checks an Android phone live over USB: installed apps, running programs, and apps with powerful access.
async function scanAndroid(device, tools, set) {
  const report = { findings: [], checked: [], missing: [], review: [], warnings: [], indicatorCount: set.count, date: new Date().toISOString() };
  const sh = (c) => android.shell(c, device, tools, 60);
  const packages = (text) => String(text || '').split('\n').map((l) => l.trim()).filter((t) => t.startsWith('package:')).map((t) => t.slice(8).split(' ')[0]);
  const installed = packages(await sh('pm list packages'));
  (installed.length ? report.checked : report.missing).push('Installed apps');
  for (const p of installed) for (const i of set.lookup('appID', p)) report.findings.push({ area: 'Installed apps', found: p, indicator: i, when: '' });

  const ps = (await sh('ps -A -o NAME')) ?? (await sh('ps -A')) ?? '';
  const running = new Set();
  for (const line of ps.split('\n')) { const name = line.trim().split(/\s+/).pop(); if (name && name !== 'NAME') running.add(name); }
  (running.size ? report.checked : report.missing).push('Running programs');
  for (const name of [...running].sort()) {
    const app = name.split(':')[0];
    for (const i of [...set.processHits(name), ...set.lookup('appID', app)]) {
      if (!installed.includes(app) || i.kind === 'process') report.findings.push({ area: 'Running programs', found: name, indicator: i, when: 'now' });
    }
  }

  const userApps = new Set(packages(await sh('pm list packages -3')));
  const components = (text) => {
    const t = String(text || '').trim();
    if (!t || t === 'null') return [];
    return [...new Set(t.split(':').map((c) => c.split('/')[0]).filter(Boolean))].sort();
  };
  const access = components(await sh('settings get secure enabled_accessibility_services'));
  const notifications = components(await sh('settings get secure enabled_notification_listeners'));
  const admins = [...new Set([...String((await sh('dumpsys device_policy')) || '').matchAll(/ComponentInfo\{([^/}]+)\//g)].map((m) => m[1]))].sort();
  const installers = String((await sh('appops query-op REQUEST_INSTALL_PACKAGES allow')) || '').split('\n').map((l) => l.trim()).filter((p) => p && userApps.has(p));
  report.checked.push('Apps with special access');
  for (const [title, detail, apps] of [
    ['Can read the screen and act for you', 'Accessibility access. Stalkerware almost always asks for this.', access],
    ['Can read every notification', 'Notification access shows message previews and codes as they arrive.', notifications],
    ['Device administrators', 'These apps can lock the phone or stop themselves being removed.', admins],
    ['Can install other apps', 'Allowed to install apps from outside the Play Store.', installers]]) {
    if (apps.length) report.review.push({ title, detail, apps });
  }
  if (String((await sh('settings get global package_verifier_enable')) || '').trim() === '0') {
    report.warnings.push('Google Play Protect scanning is turned off. Turn it back on in the Play Store app › Play Protect.');
  }
  report.findings = unique(report.findings);
  return report;
}

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/// The result as a web page (also saved as a PDF), for keeping or sending to someone who can help.
function html(r, device, source) {
  let b = `<!doctype html><meta charset=utf-8><title>Spyware check — ${esc(device)}</title><style>body{font:14px -apple-system,Segoe UI,sans-serif;margin:32px;color:#1d2433}h1{font-size:22px;margin:0 0 4px}table{border-collapse:collapse;width:100%;margin:12px 0}td,th{border-bottom:1px solid #dde;padding:6px 8px;text-align:left;vertical-align:top}th{font-size:12px;color:#667}.bad{color:#b3261e}.ok{color:#1b7a3a}.dim{color:#667}</style>`;
  b += `<h1>Spyware check: ${esc(device)}</h1><div class=dim>${esc(new Date(r.date).toLocaleString())} · ${esc(source)} · ${r.indicatorCount} known indicators</div>`;
  if (!r.findings.length) b += '<h2 class=ok>No known spyware indicators were found</h2><p>This checks only for spyware that has been publicly documented. It is not a guarantee.</p>';
  else {
    b += `<h2 class=bad>${r.findings.length} match${r.findings.length === 1 ? '' : 'es'} with known spyware indicators</h2>`;
    b += "<p>A match can be a false alarm, but take it seriously. Amnesty International's Security Lab (securitylab.amnesty.org) and Access Now's Digital Security Helpline (accessnow.org/help) help people for free.</p>";
    b += '<table><tr><th>Where</th><th>What was found</th><th>Linked to</th><th>When</th></tr>';
    for (const f of r.findings) b += `<tr><td>${esc(f.area)}</td><td>${esc(f.found)}</td><td>${esc(f.indicator.malware)} <span class=dim>(${esc(f.indicator.source)})</span></td><td>${esc(f.when)}</td></tr>`;
    b += '</table>';
  }
  for (const w of r.warnings) b += `<p class=bad>${esc(w)}</p>`;
  for (const g of r.review) b += `<h3>${esc(g.title)}</h3><div class=dim>${esc(g.detail)}</div><ul>${g.apps.map((a) => `<li>${esc(a)}</li>`).join('')}</ul>`;
  b += `<p class=dim>Checked: ${esc(r.checked.join(', '))}.`;
  if (r.missing.length) b += ` Not available: ${esc(r.missing.join(', '))}.`;
  return b + '</p>';
}

module.exports = { Indicators, parseSTIX, parsePattern, parseIndex, folder, sources, load, download, addFile, scanBackup, scanAndroid, html, INDEX_URL };
