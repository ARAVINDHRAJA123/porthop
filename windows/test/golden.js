'use strict';
// Runs the cases shared with the Mac edition (../Tests/golden) against the Windows code, so the two can't drift apart.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const { patternFolder, fileStem } = require('../core/exporter');
const { APPLE_EPOCH } = require('../core/catalog');
const dir = path.join(__dirname, '..', '..', 'Tests', 'golden');
let failed = 0;
const check = (name, ok, why = '') => { if (!ok) failed++; console.log(ok ? 'PASS' : 'FAIL', name, ok ? '' : why); };
const day = (ts) => { const d = new Date((ts + APPLE_EPOCH) * 1000); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };

// The Ask parser runs in a small sandbox holding just the page globals it reads.
const askCases = JSON.parse(fs.readFileSync(path.join(dir, 'ask.json'), 'utf8'));
const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'ask-parse.js'), 'utf8');
const misses = [];
for (const c of askCases) {
  const ctx = c.context || {};
  const sandbox = { destCache: (ctx.destinations || []).map((d) => ({ name: d.name, kind: d.kind, path: '/tmp/' + d.name })),
    state: { smart: [], user: (ctx.userAlbums || []).map((a) => ({ id: a.id, title: a.title })), people: (ctx.people || []).map((a) => ({ id: a.id, title: a.title })) }, isAndroid: () => !!ctx.isAndroid,
    DATA_KINDS: [['messages', 'Messages'], ['whatsapp', 'WhatsApp'], ['contacts', 'Contacts'], ['notes', 'Notes'], ['calendar', 'Calendar'], ['calls', 'Call Log'], ['safari', 'Safari'], ['photos', 'Photos & Videos'], ['voiceMemos', 'Voice Memos'], ['files', 'Backup Files']],
    FILTERS: [['all', 'All'], ['photos', 'Photos'], ['videos', 'Videos'], ['live', 'Live Photos'], ['screenshots', 'Screenshots'], ['favorites', 'Favorites'], ['heic', 'HEIC']],
    bytes: (n) => String(n) };
  vm.createContext(sandbox);
  vm.runInContext(src + '\nthis.result = parseAsk(' + JSON.stringify(c.text) + ');', sandbox);
  const i = sandbox.result, got = {};
  if (i.route) got.route = i.route;
  if (i.album) got.album = i.album;
  if (i.filter) got.filter = i.filter;
  if (i.from != null) { got.from = day(i.from); got.to = day(i.to); }
  if (i.minBytes) got.minBytes = i.minBytes;
  if (i.dest) got.dest = i.dest.name;
  const want = c.expect || {};
  const same = JSON.stringify(Object.entries(got).sort()) === JSON.stringify(Object.entries(want).sort());
  if (!same) misses.push(`${c.text}: got ${JSON.stringify(got)}, expected ${JSON.stringify(want)}`);
}
check(`shared Ask cases (${askCases.length})`, askCases.length && !misses.length, '\n  ' + misses.join('\n  '));

const patCases = JSON.parse(fs.readFileSync(path.join(dir, 'patterns.json'), 'utf8'));
const pmiss = [];
for (const c of patCases) {
  const [y, m, d] = c.date.split('-').map(Number);
  const [hh, mm, ss] = (c.time || '12:00:00').split(':').map(Number);
  const ts = new Date(y, m - 1, d, hh, mm, ss).getTime() / 1000 - APPLE_EPOCH;
  const a = { ts, directory: c.directory, filename: c.filename || 'IMG_0001.JPG', isVideo: !!c.video, isScreenshot: !!c.screenshot };
  if ('name' in c) {
    const got = fileStem(c.name, a, c.album, c.device || '', a.filename);
    if (got !== c.expectName) pmiss.push(`name ${c.name}: got ${got}, expected ${c.expectName}`);
  } else {
    const got = patternFolder(c.pattern, a, c.album, c.device || '').split(path.sep).join('/');
    if (got !== c.expect) pmiss.push(`${c.pattern}: got ${got}, expected ${c.expect}`);
  }
}
check(`shared folder-pattern cases (${patCases.length})`, patCases.length && !pmiss.length, '\n  ' + pmiss.join('\n  '));
// Remove location: the same small files the Mac checks, scrubbed in a scratch copy.
const os = require('node:os');
const { scrub } = require('../core/location');
const locDir = path.join(dir, 'location'), work = fs.mkdtempSync(path.join(os.tmpdir(), 'porthop-loc-'));
const lmiss = [];
const locCases = JSON.parse(fs.readFileSync(path.join(locDir, 'expect.json'), 'utf8'));
for (const e of locCases) {
  const f = path.join(work, e.file);
  fs.copyFileSync(path.join(locDir, e.file), f);
  const before = fs.statSync(f).size, ok = scrub(f), after = fs.readFileSync(f);
  const has = (x) => after.indexOf(Buffer.from(x, 'latin1')) >= 0;
  const left = e.gone.filter(has), lost = e.kept.filter((k) => !has(k));
  if (!ok || before !== after.length || left.length || lost.length) lmiss.push(`${e.file}: scrubbed ${ok}, still there ${left}, lost ${lost}`);
}
fs.rmSync(work, { recursive: true, force: true });
check(`shared remove-location files (${locCases.length})`, locCases.length === 3 && !lmiss.length, '\n  ' + lmiss.join('\n  '));

const { isNewer } = require('../core/updates');
const verCases = JSON.parse(fs.readFileSync(path.join(dir, 'versions.json'), 'utf8'));
const vmiss = verCases.filter((c) => isNewer(c.candidate, c.current) !== c.newer).map((c) => JSON.stringify(c));
check(`shared update-version cases (${verCases.length})`, verCases.length && !vmiss.length, '\n  ' + vmiss.join('\n  '));
console.log(failed ? `${failed} FAILED` : 'ALL PASSED');
process.exit(failed ? 1 : 0);
