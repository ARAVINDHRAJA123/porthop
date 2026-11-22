'use strict';
// Ask PortHop's parser: a typed request into a group, filters, dates, sizes and a destination.
// Kept free of the page so the shared tests (test/golden.js) can run it.

// MARK: ask

const MONTHS = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'];
const EPOCH = 978307200;
const tsOf = (d) => d.getTime() / 1000 - EPOCH;

function parseAsk(raw) {
  const i = { route: null, album: null, filter: null, from: null, to: null, minBytes: 0, dest: null, parts: [] };
  let body = ' ' + raw.toLowerCase().replace(/’/g, "'") + ' ';
  const m = body.match(/^(.*) (?:to|into|onto) (.+?)\s*$/);
  if (m) {
    const target = m[2].trim();
    const hit = destCache.find((d) => d.name.toLowerCase() === target)
      || destCache.find((d) => target && (d.name.toLowerCase().includes(target) || target.includes(d.name.toLowerCase())))
      || (['pc', 'this pc', 'computer', 'my computer', 'pictures', 'mac'].includes(target) ? destCache.find((d) => d.kind === 'pictures') : null);
    if (hit) { i.dest = hit; body = m[1] + ' '; }
  }
  const says = (...w) => w.some((x) => body.includes(x));
  const routes = [['bk:whatsapp', ['whatsapp']], ['bk:messages', ['message', 'imessage', ' sms', 'texts']], ['bk:contacts', ['contact']], ['bk:notes', [' note']],
    ['bk:calendar', ['calendar', 'event']], ['bk:calls', ['call log', 'calls', 'call history']], ['bk:safari', ['safari', 'bookmark', 'browsing']],
    ['nav_backup', ['back up', 'backup', 'restore']], ['nav_device', ['battery', 'health', 'storage', 'serial', 'imei', 'details']], ['nav_files', ['files', 'apps', 'documents']]];
  const albums = [['smart_hidden', ['hidden']], ['smart_screenshots', ['screenshot']], ['smart_favorites', ['favorite', 'favourite']], ['smart_selfies', ['selfie']],
    ['smart_live', ['live photo']], ['smart_trashed', ['deleted', 'trash']], ['smart_all', ['everything', 'all photos', 'library', 'all my']]];
  if (!isAndroid()) {
    for (const [id, w] of albums) if (says(...w)) { i.album = id; break; }
    if (!i.album) { const a = state.user.find((x) => x.title.length >= 3 && body.includes(x.title.toLowerCase())); if (a) i.album = a.id; }
  }
  if (says('video', 'movie', 'clip')) { if (!i.album) i.album = 'smart_videos'; else i.filter = 'videos'; }
  if (says('photo', 'picture', 'pic ') && !says('live photo') && i.album) i.filter = i.filter || 'photos';
  if (says('heic')) i.filter = 'heic';
  const now = new Date(), thisYear = now.getFullYear();
  const yearRange = (y) => [tsOf(new Date(y, 0, 1)), tsOf(new Date(y + 1, 0, 1)) - 1];
  const monthRange = (y, mo) => [tsOf(new Date(y, mo, 1)), tsOf(new Date(y, mo + 1, 1)) - 1];
  const years = (body.match(/\b(19|20)\d{2}\b/g) || []).map(Number);
  const mi = MONTHS.findIndex((x) => body.includes(' ' + x) || body.includes(' ' + x.slice(0, 3) + ' '));
  let r = null;
  if (mi >= 0) { let y = years[0] || thisYear; if (!years.length && mi > now.getMonth()) y--; r = monthRange(y, mi); }
  else if (years.length >= 2) r = [yearRange(Math.min(years[0], years[1]))[0], yearRange(Math.max(years[0], years[1]))[1]];
  else if (years.length) r = yearRange(years[0]);
  else if (says('last year')) r = yearRange(thisYear - 1);
  else if (says('this year')) r = yearRange(thisYear);
  else if (says('last month')) { const d = new Date(thisYear, now.getMonth() - 1, 1); r = monthRange(d.getFullYear(), d.getMonth()); }
  else if (says('this month')) r = monthRange(thisYear, now.getMonth());
  if (r) [i.from, i.to] = r;
  const sz = body.match(/(?:over|above|bigger than|larger than|more than|at least|>)\s*(\d+(?:\.\d+)?)\s*(kb|mb|gb)/);
  if (sz) i.minBytes = Math.round(Number(sz[1]) * (sz[2] === 'gb' ? 1e9 : sz[2] === 'mb' ? 1e6 : 1e3));
  const photoRequest = i.album || i.filter || i.from != null || i.minBytes;
  if (!photoRequest) {
    const hit = routes.find(([, w]) => says(...w));
    if (hit && !(isAndroid() && (hit[0].startsWith('bk:') || hit[0] === 'nav_backup'))) i.route = hit[0];
  }
  if (photoRequest && !i.album && !isAndroid()) i.album = 'smart_all';
  if (i.route) i.parts.push(i.route.startsWith('bk:') ? DATA_KINDS.find((k) => 'bk:' + k[0] === i.route)[1] : { nav_backup: 'Backups', nav_device: 'Device details', nav_files: isAndroid() ? 'Phone storage' : 'Media files' }[i.route]);
  if (i.album) i.parts.push([...state.smart, ...state.user].find((a) => a.id === i.album)?.title || 'Library');
  if (i.filter) i.parts.push(FILTERS.find((f) => f[0] === i.filter)[1]);
  if (i.from != null) i.parts.push(rangeText(i.from, i.to));
  if (i.minBytes) i.parts.push('over ' + bytes(i.minBytes));
  if (i.dest) i.parts.push('to ' + i.dest.name);
  return i;
}
const rangeText = (from, to) => {
  const f = (t) => new Date((t + EPOCH) * 1000).toLocaleString(undefined, { month: 'short', year: 'numeric' });
  return f(from) === f(to) ? f(from) : `${f(from)} – ${f(to)}`;
};
