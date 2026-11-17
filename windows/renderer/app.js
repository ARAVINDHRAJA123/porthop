'use strict';
/* Window logic. All device work happens in the main process; this file only draws and asks. */
(() => {
const api = window.bridge;
const $ = (s) => document.querySelector(s);
// Lists of children may contain empty slots; drop them instead of printing "null".
const nativeReplace = Element.prototype.replaceChildren;
Element.prototype.replaceChildren = function (...kids) { return nativeReplace.apply(this, kids.flat().filter((k) => k != null && k !== false)); };
let state = null;
let selection = 'nav_home';
let drawnKey = '';

// MARK: small helpers

function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'html') el.innerHTML = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'style') el.style.cssText = v;
    else if (k in el && k !== 'list') el[k] = v;
    else el.setAttribute(k, v);
  }
  for (const kid of kids.flat()) if (kid != null && kid !== false) el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  return el;
}
// Material Symbols (Rounded, filled), generated into icons.js by tools/fetch-icons.mjs.
const icon = (name) => h('span', { html: `<svg class="ms" viewBox="0 -960 960 960"><path d="${MATERIAL_ICONS[name] || MATERIAL_ICONS.app}"/></svg>`, style: 'display:contents' });
const tile = (name, color) => h('span', { class: 'tile', style: `background:${color}` }, icon(name));
const bytes = (n) => {
  if (!(n > 0)) return '—';
  const u = ['bytes', 'KB', 'MB', 'GB', 'TB'];
  let i = 0, v = n;
  while (v >= 1000 && i < 4) { v /= 1000; i++; }
  return (i === 0 ? v : v.toFixed(v >= 100 ? 0 : v >= 10 ? 1 : 2)) + ' ' + u[i];
};
const count = (n) => Number(n).toLocaleString();
const plural = (n, word) => `${count(n)} ${word}${n === 1 ? '' : 's'}`;
const kindWord = () => (state && state.details ? state.details.kindWord : 'device');
const isAndroid = () => state && state.device && state.device.kind === 'android';
function eta(secs) {
  if (!isFinite(secs) || secs <= 0) return '';
  if (secs < 60) return 'less than a minute left';
  const m = Math.round(secs / 60);
  return m < 60 ? `about ${m} min left` : `about ${Math.floor(m / 60)} h ${m % 60} min left`;
}

// MARK: dialogs

function openModal(content) { const m = $('#modal'); m.replaceChildren(content); m.classList.remove('hidden'); return m; }
function closeModal() { $('#modal').classList.add('hidden'); $('#modal').replaceChildren(); }
function confirmBox(title, text, okLabel, danger) {
  return new Promise((resolve) => {
    openModal(h('div', { class: 'sheet' }, h('h2', {}, title), h('p', { class: 'dim' }, text),
      h('div', { class: 'foot' }, h('button', { class: 'btn', onclick: () => { closeModal(); resolve(false); } }, 'Cancel'),
        h('button', { class: 'btn primary' + (danger ? '' : ''), onclick: () => { closeModal(); resolve(true); } }, okLabel))));
  });
}
function promptBox(title, text, placeholder, okLabel) {
  return new Promise((resolve) => {
    const input = h('input', { type: 'text', placeholder, style: 'width:100%' });
    const done = (v) => { closeModal(); resolve(v); };
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter' && input.value.trim()) done(input.value.trim()); if (e.key === 'Escape') done(null); });
    openModal(h('div', { class: 'sheet' }, h('h2', {}, title), h('p', { class: 'dim' }, text), input,
      h('div', { class: 'foot' }, h('button', { class: 'btn', onclick: () => done(null) }, 'Cancel'),
        h('button', { class: 'btn primary', onclick: () => input.value.trim() && done(input.value.trim()) }, okLabel))));
    input.focus();
  });
}

// MARK: a table that only draws the rows on screen, so 60,000 rows stay instant

class VTable {
  constructor({ columns, rowKey, onOpen, onSelect, onSort, empty }) {
    Object.assign(this, { columns, rowKey, onOpen, onSelect, onSort, empty });
    this.rows = []; this.selected = new Set(); this.anchor = -1; this.sort = null; this.asc = false;
    this.head = h('div', { class: 'thead' });
    this.spacer = h('div', { class: 'spacer' });
    this.body = h('div', { class: 'tbody', tabIndex: 0 }, this.spacer);
    this.el = h('div', { class: 'table' }, this.head, this.body);
    this.body.addEventListener('scroll', () => this.draw());
    this.body.addEventListener('keydown', (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'a') { e.preventDefault(); this.selected = new Set(this.rows.map(this.rowKey)); this.changed(); }
      if (e.key === 'Escape') { this.selected.clear(); this.changed(); }
    });
    new ResizeObserver(() => this.draw()).observe(this.body);
    this.drawHead();
  }
  drawHead() {
    this.head.replaceChildren(...this.columns.map((c) => h('button', {
      class: c.sort ? 'sortable' : '', style: c.flex ? 'flex:1;min-width:120px' : `width:${c.width}px;flex:none`,
      onclick: () => { if (!c.sort || !this.onSort) return; this.asc = this.sort === c.sort ? !this.asc : !!c.ascFirst; this.sort = c.sort; this.drawHead(); this.onSort(this.sort, this.asc); },
    }, c.title + (this.sort && this.sort === c.sort ? (this.asc ? '  ▲' : '  ▼') : ''))));
  }
  setRows(rows, keepSelection) {
    this.rows = rows;
    if (!keepSelection) { this.selected.clear(); this.anchor = -1; }
    this.spacer.style.height = rows.length * 30 + 'px';
    this.body.scrollTop = 0;
    this.draw();
    if (this.onSelect) this.onSelect(this.selected);
  }
  changed() { this.draw(); if (this.onSelect) this.onSelect(this.selected); }
  draw() {
    const top = this.body.scrollTop, hgt = this.body.clientHeight || 600;
    const first = Math.max(0, Math.floor(top / 30) - 6), last = Math.min(this.rows.length, Math.ceil((top + hgt) / 30) + 6);
    const frag = [];
    for (let i = first; i < last; i++) {
      const row = this.rows[i], key = this.rowKey(row);
      const tr = h('div', { class: 'tr' + (i % 2 ? ' alt' : '') + (this.selected.has(key) ? ' sel' : ''), style: `top:${i * 30}px` },
        this.columns.map((c) => h('div', { class: 'td ' + (c.cls || ''), style: c.flex ? 'flex:1;min-width:120px' : `width:${c.width}px;flex:none`, title: c.tip ? c.cell(row) : null }, c.cell(row))));
      tr.addEventListener('click', (e) => this.click(i, key, e));
      tr.addEventListener('dblclick', () => this.onOpen && this.onOpen(row));
      frag.push(tr);
    }
    if (!this.rows.length && this.empty) frag.push(h('div', { class: 'empty' }, this.empty()));
    this.spacer.replaceChildren(...frag);
  }
  click(i, key, e) {
    if (e.shiftKey && this.anchor >= 0) {
      const [a, b] = [Math.min(this.anchor, i), Math.max(this.anchor, i)];
      if (!(e.ctrlKey || e.metaKey)) this.selected.clear();
      for (let j = a; j <= b; j++) this.selected.add(this.rowKey(this.rows[j]));
    } else if (e.ctrlKey || e.metaKey) { if (this.selected.has(key)) this.selected.delete(key); else this.selected.add(key); this.anchor = i; }
    else { this.selected = new Set([key]); this.anchor = i; }
    this.changed();
  }
}

// MARK: top bar

const SMART_ICONS = { smart_hidden: ['eye', '#7369ff'], smart_all: ['photo', '#3d8bff'], smart_favorites: ['heart', '#ff6b94'], smart_videos: ['video', '#9e73ff'],
  smart_live: ['live', '#ffa842'], smart_screenshots: ['shot', '#38c7d6'], smart_selfies: ['selfie', '#4dcc85'], smart_trashed: ['trash', '#808ca3'] };
const DATA_KINDS = [['messages', 'Messages', 'msg', '#3ecf74'], ['whatsapp', 'WhatsApp', 'chats', '#2bbf9d'], ['contacts', 'Contacts', 'person', '#8a8894'], ['notes', 'Notes', 'note', '#e0b000'],
  ['calendar', 'Calendar', 'cal', '#ff5d5d'], ['calls', 'Call Log', 'call', '#33a9c9'], ['safari', 'Safari', 'globe', '#3b8cff'], ['files', 'Backup Files', 'box', '#a8794f']];
const SMART_ORDER = ['smart_hidden', 'smart_all', 'smart_videos', 'smart_screenshots', 'smart_favorites', 'smart_live', 'smart_selfies', 'smart_trashed'];
const ANDROID_FOLDERS = [['Camera', 'camera', '/sdcard/DCIM'], ['Pictures', 'photo', '/sdcard/Pictures'], ['Download', 'down', '/sdcard/Download'],
  ['Movies', 'video', '/sdcard/Movies'], ['Music', 'music', '/sdcard/Music'], ['Documents', 'file', '/sdcard/Documents']];

let destCache = [];          // places copies can go, refreshed whenever Shores is drawn
let pendingDest = null;      // where the next copy goes, when the place was picked first
let lensInit = null;         // filters to open a group with (from the Ask box)
let pendingUploads = null;   // files dropped on the device, sent once its folder is open
let pendingFlight = null;    // [pile element, destination element] for the hop animation
const live = { export: null, destName: '' };
const liveViews = new Set();

function updateLive() {
  for (const f of [...liveViews]) f();
  const b = $('#badge');
  if (b) {
    const p = live.export;
    b.classList.toggle('hidden', !p);
    if (p) b.replaceChildren(h('span', { class: 'mini-ring', style: `--p:${Math.round(frac(p) * 100)}` }), `${Math.round(frac(p) * 100)}%`);
  }
  document.querySelectorAll('.dest').forEach((el) => {
    const on = !!live.export && state && el.dataset.path === state.exportDest;
    el.classList.toggle('receiving', on);
    const bar = el.querySelector('.dest-bar i'), sub = el.querySelector('small');
    if (on && bar) bar.style.width = Math.round(frac(live.export) * 100) + '%';
    if (sub) sub.textContent = on ? `Receiving… ${Math.round(frac(live.export) * 100)}%` : sub.dataset.text;
  });
}
const frac = (p) => (p.bytesTotal > 0 ? Math.min(1, p.bytesDone / p.bytesTotal) : (p.total ? (p.copied + p.skipped + p.failed) / p.total : 0));

const askInput = h('input', { class: 'ask-input', placeholder: 'Ask PortHop: hidden videos from 2024 to T7', spellcheck: false });
const askPanel = h('div', { class: 'ask-panel hidden' });
const badge = h('button', { id: 'badge', class: 'badge hidden', title: 'See what is copying', onclick: () => go('nav_home') });

function drawTopBar() {
  const s = state, ready = s.phase === 'ready';
  const back = ready && selection !== 'nav_home' ? h('button', { class: 'tb-btn', title: 'Back to Shores', onclick: () => go('nav_home') }, icon('back')) : null;
  const pill = h('div', { class: 'splitbtn' },
    h('button', { class: 'split-main', disabled: !ready, title: 'Battery and device details', onclick: () => go('nav_device') },
      h('i', { class: 'dot' + (ready ? '' : ' off') }), ready ? s.details.name : 'No device'),
    h('button', { class: 'split-menu', disabled: !ready, title: 'Devices, backups and more', onclick: (e) => { e.currentTarget.classList.add('open'); devicePopover(e.currentTarget); } }, icon('chev')));
  const askWrap = h('div', { class: 'ask' + (ready ? '' : ' off') }, icon('search'), askInput, h('kbd', {}, 'Ctrl K'));
  const settingsBtn = h('button', { class: 'tb-btn', title: 'Settings and licences', onclick: async (e) => {
    const target = e.currentTarget, now = await api.call('appearance');
    const mode = (v, label, ic) => [label, now === v ? 'check' : ic, () => api.call('appearance', v)];
    popover(target, [mode('system', 'Match Windows', 'contrast'), mode('light', 'Light', 'sun'), mode('dark', 'Dark', 'moon'),
      ['Open-source licences', 'file', () => api.call('licences')], ['PortHop on GitHub', 'globe', () => api.call('github')]]);
  } }, icon('dots'));
  $('#topbar').replaceChildren(h('div', { class: 'tb-left' }, back, pill), askWrap, h('div', { class: 'tb-right' }, badge, settingsBtn));
  askInput.disabled = !ready;
  updateLive();
}

function popover(anchor, items) {
  document.querySelectorAll('.popover').forEach((p) => p.remove());
  const r = anchor.getBoundingClientRect();
  const el = h('div', { class: 'popover', style: `top:${r.bottom + 6}px;left:${Math.min(r.left, window.innerWidth - 270)}px` },
    items.map((it) => it === '-' ? h('div', { class: 'pop-sep' }) : (it[0] === null ? h('div', { class: 'pop-head' }, it[1])
      : h('button', { class: 'pop-item', onclick: () => { done(); it[2](); } }, icon(it[1]), h('span', {}, it[0]), it[3] != null ? h('i', {}, it[3]) : null))));
  const done = () => { el.remove(); document.querySelectorAll('.split-menu.open').forEach((b) => b.classList.remove('open')); };
  document.body.append(el);
  setTimeout(() => document.addEventListener('mousedown', function close(e) { if (!el.contains(e.target)) { done(); document.removeEventListener('mousedown', close); } }), 0);
  return el;
}

function devicePopover(anchor) {
  const s = state, items = [];
  if (s.devices.length > 1) {
    items.push([null, 'Connected devices']);
    for (const d of s.devices) items.push([d.name, d.udid === s.device.udid ? 'check' : 'phone', () => api.call('switch', d.udid)]);
    items.push('-');
  }
  items.push(['Battery and device details', 'info', () => go('nav_device')]);
  if (!isAndroid()) items.push(['Backups', 'clock', () => go('nav_backup')]);
  items.push([isAndroid() ? 'Phone storage' : 'Media files', 'folder', () => go('nav_files')], '-', ['Refresh', 'refresh', () => api.call('refresh')]);
  popover(anchor, items);
}

function go(id) { selection = id; document.querySelectorAll('.popover').forEach((p) => p.remove()); drawTopBar(); drawMain(true); }

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
const askEmpty = (i) => !i.route && !i.album && !i.filter && i.from == null && !i.minBytes && !i.dest;

function applyAsk(i) {
  if (askEmpty(i)) return false;
  if (i.dest) pendingDest = i.dest.path;
  if (i.route) { go(i.route); return true; }
  lensInit = { filter: i.filter || 'all', from: i.from, to: i.to, minBytes: i.minBytes || 0 };
  go(i.album);
  return true;
}

function drawAskPanel() {
  const text = askInput.value.trim();
  const examples = isAndroid() ? ['battery', 'files'] : ['hidden photos', 'videos over 500 MB', `screenshots from ${new Date().getFullYear()}`, 'favourites from last year to Pictures', 'messages', 'back up my iPhone'];
  const run = (t) => { if (applyAsk(parseAsk(t))) { askInput.value = ''; askInput.blur(); } };
  if (!text) {
    askPanel.replaceChildren(h('div', { class: 'ask-try' }, 'Try'), h('div', { class: 'chips' }, examples.map((e) => h('button', { class: 'chip', onmousedown: (ev) => { ev.preventDefault(); run(e); } }, e))));
  } else {
    const i = parseAsk(text);
    askPanel.replaceChildren(askEmpty(i)
      ? h('div', { class: 'dim' }, 'Not sure what to open. Try an album (hidden, videos, screenshots), a year, a size like “over 100 MB”, or “to” a drive.')
      : h('div', {}, h('div', { class: 'chips' }, i.parts.map((p) => h('span', { class: 'chip on' }, p))), h('div', { class: 'ask-try' }, 'Press Enter to open it')));
  }
}
askInput.addEventListener('focus', () => { askPanel.classList.remove('hidden'); drawAskPanel(); api.call('destinations').then((d) => { destCache = d; drawAskPanel(); }); });
askInput.addEventListener('blur', () => setTimeout(() => askPanel.classList.add('hidden'), 120));
askInput.addEventListener('input', drawAskPanel);
askInput.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && applyAsk(parseAsk(askInput.value))) { askInput.value = ''; askInput.blur(); }
  if (e.key === 'Escape') { askInput.value = ''; askInput.blur(); }
});
document.addEventListener('keydown', (e) => { if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k' && !askInput.disabled) { e.preventDefault(); askInput.focus(); } });

// MARK: main area

function drawMain(force) {
  const s = state;
  const key = s.phase === 'ready' ? `ready:${selection}:${s.device.udid}` : `${s.phase}:${s.message}`;
  if (!force && key === drawnKey) {
    // Shores is redrawn only when what it shows changed, so drags, menus and thumbnails are not interrupted.
    if (s.phase === 'ready' && selection === 'nav_home' && shoresSig() !== lastShoresSig) { lastShoresSig = shoresSig(); show(shoresView()); }
    return;
  }
  drawnKey = key;
  if (s.phase !== 'ready') return show(statusView());
  if (selection === 'nav_home') { lastShoresSig = shoresSig(); return show(shoresView()); }
  if (selection === 'nav_device') return show(deviceView());
  if (selection === 'nav_backup') return show(backupView());
  if (selection === 'nav_files' || selection.startsWith('app:')) return show(filesView());
  if (selection.startsWith('bk:')) return show(dataView(selection.slice(3)));
  if ([...s.smart, ...s.user].some((a) => a.id === selection)) return show(albumView());
  selection = 'nav_home'; drawTopBar(); lastShoresSig = shoresSig(); show(shoresView());
}
let lastShoresSig = '';
function shoresSig() {
  const s = state, d = s.details || {};
  return JSON.stringify([s.smart.map((a) => a.id + a.count), s.user.map((a) => a.id + a.count), s.apps.length, d.battery, d.freeBytes, d.name, s.lastHop]);
}
function show(view) { $('#main').replaceChildren(view); }
const viewBox = (...kids) => h('div', { class: 'view' }, ...kids);

function statusView() {
  const s = state;
  const waiting = (t) => h('div', { class: 'pulse' }, h('i'), t);
  const hero = (ic) => h('div', { class: 'hero' }, icon(ic));
  if (s.phase === 'searching') return viewBox(h('div', { class: 'center' }, h('div', { class: 'spinner' }), h('div', { class: 'dim' }, 'Looking for your device…')));
  if (s.phase === 'loading') return viewBox(h('div', { class: 'center' }, hero('photo'), h('h2', {}, s.message), h('div', { class: 'spinner' }),
    h('div', { class: 'dim' }, 'Large libraries can take a moment. Keep the device unlocked.')));
  if (s.phase === 'noDevice' && s.restarting) return viewBox(h('div', { class: 'center' }, hero('refresh'), h('h1', {}, `${s.restartingName || 'Your device'} is restarting`),
    h('div', { class: 'dim', style: 'max-width:520px' }, 'It will appear here again by itself in a minute or two. If it asks, unlock it and tap Trust.'), waiting('Waiting for it to come back')));
  if (s.phase === 'needsTrust') return viewBox(h('div', { class: 'center' }, hero('lock'), h('h1', {}, 'Unlock and allow'), h('div', { class: 'dim', style: 'max-width:540px' }, s.message), waiting('Checking again every few seconds')));
  if (s.phase === 'toolsMissing') return viewBox(h('div', { class: 'center' }, hero('box'), h('h1', {}, 'A part of the app is missing'),
    h('div', { class: 'dim', style: 'max-width:560px' }, 'The device tools that ship inside this app were not found. Download the app again and unzip the whole folder before opening it.'), waiting('Checking again every few seconds')));
  if (s.phase === 'catalogError') return viewBox(h('div', { class: 'center' }, hero('warn'), h('h1', {}, 'The photo library could not be read'), h('div', { class: 'dim', style: 'max-width:560px' }, s.message),
    h('button', { class: 'btn primary', onclick: () => api.call('refresh') }, icon('refresh'), 'Try Again')));
  const step = (n, title, text) => h('div', { class: 'step' }, h('div', { class: 'num' }, n), h('b', {}, title), h('span', { class: 'dim' }, text));
  return viewBox(h('div', { class: 'center' }, hero('cable'),
    h('h1', {}, s.hasAdb ? 'Connect your iPhone, iPad or Android' : 'Connect your iPhone or iPad'),
    h('div', { class: 'dim' }, 'Copy photos, videos and files to this computer or an external drive over USB.'),
    h('div', { class: 'steps' }, step(1, 'Plug in', 'Use a USB cable that carries data.'), step(2, 'Unlock and allow', 'Unlock the device. Tap Trust on an iPhone, or Allow on Android.'), step(3, 'Hop it across', 'Drag a group of photos onto a folder or drive.')),
    s.isWindows ? h('div', { class: 'dim', style: 'max-width:620px;font-size:12.5px' }, 'iPhone not showing up? Windows needs Apple’s driver: install “Apple Devices” from the Microsoft Store (or iTunes), then plug the iPhone in again.') : null,
    !s.hasAdb ? androidSetup() : null,
    waiting('Waiting for a device — it will appear here automatically')));
}

function androidSetup() {
  const note = h('span', { class: 'dim', style: 'font-size:12.5px' }, 'Android needs Google’s free connection tool (about 15 MB, downloaded from Google).');
  const btn = h('button', { class: 'btn', onclick: async () => {
    btn.disabled = true; note.textContent = 'Downloading from Google…';
    const problem = await api.call('adb:setup');
    btn.disabled = false;
    note.textContent = problem || 'Android support is ready. Turn on USB debugging on the phone and plug it in.';
  } }, icon('down'), 'Set Up Android Support');
  return h('div', { style: 'display:flex;align-items:center;gap:12px;margin-top:4px' }, btn, note);
}

function ring(fraction, big, small, color) {
  const c = 2 * Math.PI * 36;
  return h('div', { class: 'ring' }, h('span', { html: `<svg viewBox="0 0 84 84"><circle cx="42" cy="42" r="36" stroke="rgba(255,255,255,.1)"/><circle cx="42" cy="42" r="36" stroke="${color}" stroke-dasharray="${c * Math.min(1, fraction)} ${c}"/></svg>`, style: 'display:contents' }),
    h('div', {}, h('b', {}, big), small));
}

// MARK: shores

function shoresView() {
  const s = state;
  const piles = isAndroid()
    ? ANDROID_FOLDERS.map(([title, ic, p]) => ({ id: 'android:' + p, title, icon: ic, color: '#5a8cff', path: p }))
    : SMART_ORDER.map((id) => s.smart.find((a) => a.id === id)).filter((a) => a && (a.count || a.id === 'smart_hidden'))
      .map((a) => ({ id: a.id, title: a.title, icon: SMART_ICONS[a.id][0], color: SMART_ICONS[a.id][1], count: a.count, bytes: a.bytes, thumbs: a.thumbs, blur: a.id === 'smart_hidden' }));
  const albums = isAndroid() ? [] : s.user.map((a) => ({ id: a.id, title: a.title, icon: 'album', color: '#5aa2ff', count: a.count, bytes: a.bytes, compact: true }));
  const all = [...piles, ...albums];

  const left = h('div', { class: 'shore' },
    deviceHero(),
    h('div', { class: 'label' }, isAndroid() ? `Folders on your ${kindWord()}` : `On your ${kindWord()}`),
    h('div', { class: 'piles' }, piles.map(pileCard)),
    isAndroid() ? h('button', { class: 'btn', style: 'align-self:flex-start', onclick: () => go('nav_files') }, icon('folder'), 'Browse all storage') : null,
    albums.length ? [h('div', { class: 'label' }, 'Your albums'), h('div', { class: 'piles' }, albums.map(pileCard))] : null,
    s.apps.length ? [h('div', { class: 'label' }, 'Send files to apps'), h('div', { class: 'chips' }, s.apps.map((a) => h('button', { class: 'chip', onclick: () => go('app:' + a.id) }, a.name)))] : null,
    h('div', { class: 'hint' }, isAndroid() ? 'Drop files here to send them to the Download folder.'
      : `Click a group to look inside. Drag it across to copy it.${s.apps.length ? ' Drop files here to send them to an app.' : ''}`));
  left.addEventListener('dragover', (e) => { if (e.dataTransfer.types.includes('Files') && (isAndroid() || s.apps.length)) { e.preventDefault(); left.classList.add('drop'); } });
  left.addEventListener('dragleave', (e) => { if (!left.contains(e.relatedTarget)) left.classList.remove('drop'); });
  left.addEventListener('drop', (e) => {
    left.classList.remove('drop');
    if (!e.dataTransfer.files.length) return;
    e.preventDefault();
    const paths = [...e.dataTransfer.files].map((f) => api.pathOf(f)).filter(Boolean);
    if (!paths.length) return;
    if (isAndroid()) sendFiles(paths, null);
    else if (s.apps.length === 1) sendFiles(paths, s.apps[0].id);
    else popover(left.querySelector('.label'), [[null, `Send ${plural(paths.length, 'item')} to which app?`], ...s.apps.map((a) => [a.name, 'app', () => sendFiles(paths, a.id)])]);
  });

  const destList = h('div', { class: 'dests' }, h('div', { class: 'dim', style: 'padding:8px 2px' }, 'Looking for drives…'));
  const right = h('div', { class: 'shore' },
    h('div', { class: 'label' }, 'Hop them to'),
    destList,
    h('button', { class: 'choose', onclick: async () => { const p = await api.call('pick:folder', 'Choose a folder or drive'); if (p) { destCache = await api.call('dest:remember', p); fill(); } } },
      icon('plus'), 'Choose another folder…'),
    isAndroid() ? null : [h('div', { class: 'label', style: 'margin-top:8px' }, 'Keep a full copy'), backupsCard()]);
  const fill = () => { destList.replaceChildren(...destCache.map((d) => destCard(d, all))); updateLive(); };
  api.call('destinations').then((d) => { destCache = d; fill(); });

  return viewBox(h('div', { class: 'shores' }, left, channelView(), right));
}

function deviceHero() {
  const d = state.details, used = d.totalBytes > 0 ? (d.totalBytes - d.freeBytes) / d.totalBytes : 0;
  return h('button', { class: 'hero-card', title: 'Battery health, storage and device details', onclick: () => go('nav_device') },
    h('span', { class: 'hero-ic' }, icon('phone')),
    h('div', { class: 'hero-text' }, h('b', {}, d.name), h('small', {}, `${d.modelName} · ${d.osName} ${d.osVersion} · ${state.device.isNetwork ? 'Wi-Fi' : 'USB'}`),
      d.totalBytes > 0 ? [h('div', { class: 'bar' }, h('i', { style: `width:${Math.round(used * 100)}%` })), h('small', { class: 'faint' }, `${bytes(d.freeBytes)} free of ${bytes(d.totalBytes)}`)] : null),
    d.battery != null ? h('div', { class: 'hero-ring' }, ring(d.battery / 100, d.battery + '%', '', d.battery < 20 ? 'var(--red)' : 'var(--green)')) : null);
}

const PILE_SHAPES = { smart_hidden: 'cookie9', smart_all: 'clover4', smart_videos: 'sunny', smart_screenshots: 'squircle', smart_favorites: 'flower',
  smart_live: 'burst', smart_selfies: 'cookie4', smart_trashed: 'cookie6' };
const shapeFor = (id) => 'shape-' + (PILE_SHAPES[id] || ['cookie6', 'clover4', 'sunny', 'flower', 'cookie9', 'burst'][[...id].reduce((n, c) => n + c.charCodeAt(0), 0) % 6]);

function pileCard(p) {
  const el = h('div', { class: 'pile' + (p.compact ? ' compact' : ''), draggable: true, title: p.path || 'Click to look inside. Drag onto a place on the right to copy everything in it.',
    onclick: () => (p.path ? (pendingFolder = p.path, go('nav_files')) : go(p.id)) },
    h('div', { class: 'pile-top' }, h('span', { class: 'tile big ' + shapeFor(p.id), style: `background:${p.color}` }, icon(p.icon)), !p.compact && p.thumbs && p.thumbs.length ? thumbFan(p.thumbs, p.blur) : null),
    h('div', {}, h('div', { class: 'pile-name' }, p.title),
      h('div', { class: 'pile-sub' }, p.count != null ? `${plural(p.count, 'item')} · ${bytes(p.bytes)}` : (p.path || '').replace('/sdcard/', ''))));
  el.dataset.pile = p.id;
  el.addEventListener('dragstart', (e) => { e.dataTransfer.setData('text/porthop-pile', p.id); e.dataTransfer.effectAllowed = 'copy'; });
  return el;
}

function thumbFan(ids, blur) {
  const fan = h('div', { class: 'fan' + (blur ? ' blur' : '') });
  ids.slice(0, 3).forEach((id, i) => {
    const card = h('span', { style: `--i:${i - 1}` });
    fan.append(card);
    api.call('thumb', id).then((p) => { if (p) card.append(h('img', { src: 'file:///' + p.replace(/\\/g, '/').replace(/^\//, '') })); });
  });
  return fan;
}

function destCard(d, piles) {
  const sub = [d.free ? `${bytes(d.free)} free` : null, d.detail].filter(Boolean).join(' · ');
  const small = h('small', {}, sub);
  small.dataset.text = sub;
  const el = h('div', { class: 'dest', title: d.path },
    h('span', { class: 'dest-ic' }, icon(d.kind === 'drive' ? 'drive' : d.kind === 'recent' ? 'folder' : 'photo')),
    h('div', { class: 'dest-text' }, h('b', {}, d.name), small, h('div', { class: 'dest-bar' }, h('i'))),
    d.isFAT ? h('span', { class: 'tag-warn' }, 'FAT32: 4 GB limit') : h('span', { class: 'dest-arrow' }, icon('down')));
  el.dataset.dest = d.id;
  el.dataset.path = d.path;
  el.addEventListener('dragover', (e) => { if (e.dataTransfer.types.includes('text/porthop-pile')) { e.preventDefault(); el.classList.add('targeted'); } });
  el.addEventListener('dragleave', () => el.classList.remove('targeted'));
  el.addEventListener('drop', (e) => {
    e.preventDefault(); el.classList.remove('targeted');
    const p = piles.find((x) => x.id === e.dataTransfer.getData('text/porthop-pile'));
    if (p) hop(p, d, el);
  });
  el.addEventListener('click', () => popover(el, [[null, `Copy to ${d.name}`], ...piles.map((p) => [p.title, p.icon, () => hop(p, d, el), p.count != null ? count(p.count) : null]),
    '-', ['Show in folder', 'folder', () => api.call('reveal', d.path)]]));
  return el;
}

function backupsCard() {
  const card = h('div', { class: 'card backups' },
    h('button', { class: 'row-btn', onclick: () => go('nav_backup') }, tile('clock', '#ffb547'),
      h('div', { style: 'flex:1;min-width:0' }, h('b', {}, `Back up ${state.details.name}`), h('small', { class: 'dim', id: 'bk-detail' }, 'Looking for backups…')), icon('arrow')));
  api.call('backup:list').then((list) => {
    const latest = list[0];
    const el = card.querySelector('#bk-detail');
    if (el) el.textContent = latest && latest.date ? `Last backup ${new Date(latest.date).toLocaleDateString()}${latest.encrypted ? ' · encrypted' : ''}` : 'No backup in the backup folder yet';
    if (list.length) card.append(h('div', { class: 'faint', style: 'font-size:12px;margin:10px 0 6px' }, 'Look inside your latest backup'),
      h('div', { class: 'chips' }, DATA_KINDS.map(([k, t]) => h('button', { class: 'chip', onclick: () => go('bk:' + k) }, t))));
  });
  return card;
}

function channelView() {
  const body = h('div', { class: 'chan-body' });
  const el = h('div', { class: 'channel' },
    h('div', { class: 'arc' }, h('span', { html: '<svg viewBox="0 0 200 110"><path d="M6 104 Q100 -50 194 104" fill="none" stroke="currentColor" stroke-width="2.5" stroke-dasharray="1 9" stroke-linecap="round"/></svg>', style: 'display:contents' }),
      h('i', { class: 'hopper' }), h('i', { class: 'hopper' }), h('i', { class: 'hopper' })), body);
  let mode = null, refs = null;
  const render = () => {
    if (!el.isConnected && el.dataset.drawn) { liveViews.delete(render); return; }
    el.dataset.drawn = '1';
    const p = live.export;
    el.classList.toggle('active', !!p);
    if (p) {
      if (mode !== 'export') {
        mode = 'export';
        refs = { title: h('b', { class: 'chan-title' }), count: h('div', { class: 'chan-count' }), wave: wavyBar(200), detail: h('div', { class: 'dim chan-detail' }) };
        body.replaceChildren(refs.title, refs.count, refs.wave.el, refs.detail,
          h('button', { class: 'btn', onclick: (e) => { e.currentTarget.disabled = true; e.currentTarget.textContent = 'Stopping…'; api.call('export:stop'); } }, 'Stop'));
      }
      refs.title.textContent = `Hopping to ${live.destName}`;
      refs.count.textContent = `${count(Math.min(p.total, p.copied + p.skipped + p.failed + (p.inFlight || 0)))} of ${count(p.total)}`;
      refs.wave.set(frac(p));
      refs.detail.textContent = progressText(p);
    } else {
      mode = 'idle';
      body.replaceChildren(h('span', { class: 'chan-ic' }, icon('arrow')), h('b', {}, 'Drag a group across'),
        h('div', { class: 'dim' }, `or click a place on the right and pick what to copy. Nothing is removed from your ${kindWord()}.`),
        state.lastHop ? h('div', { class: 'faint', style: 'margin-top:8px' }, `Last hop: ${state.lastHop}`) : null,
        lastCopyNote ? h('div', { class: 'faint', style: 'margin-top:6px' }, lastCopyNote) : null);
    }
  };
  render();
  liveViews.add(render);
  return el;
}

/// Material 3 Expressive's wavy progress bar: a moving wave for what is done, a flat track for what is left.
let wavyId = 0;
function wavyBar(W) {
  const id = 'wv' + (++wavyId);
  let d = 'M-24 7';
  for (let x = -24; x < W + 24; x += 24) d += ' q 6 -6 12 0 t 12 0';
  const el = h('span', { style: 'display:contents', html: `<svg class="wavy" style="width:${W}px;height:14px" viewBox="0 0 ${W} 14"><defs><clipPath id="${id}"><rect x="0" y="0" width="0" height="14"/></clipPath></defs><g clip-path="url(#${id})"><path class="wv-wave" d="${d}"/></g><line class="wv-track" x1="0" y1="7" x2="${W - 2}" y2="7"/><circle class="wv-stop" cx="${W - 2}" cy="7" r="2"/></svg>` });
  const svg = el.firstChild, rect = svg.querySelector('rect'), line = svg.querySelector('line');
  return {
    el: svg,
    set(f) {
      const x = Math.max(0, Math.min(1, f)) * W;
      rect.setAttribute('width', x.toFixed(1));
      line.setAttribute('x1', Math.min(W - 2, x + 8).toFixed(1));
      line.style.display = x + 8 >= W - 2 ? 'none' : '';
    },
  };
}
let lastCopyNote = '';

function progressText(p) {
  const parts = [];
  if (p.bytesTotal > 0) parts.push(`${bytes(p.bytesDone)} of ${bytes(p.bytesTotal)}`);
  if (p.bytesPerSecond > 0) { parts.push(`${bytes(p.bytesPerSecond)}/s`); const e = eta((p.bytesTotal - p.bytesDone) / p.bytesPerSecond); if (e) parts.push(e); }
  if (p.skipped) parts.push(`${count(p.skipped)} already there`);
  return parts.length ? parts.join(' · ') : `Keep the ${kindWord()} connected and unlocked.`;
}

function hop(p, d, destEl) {
  if (live.export) return;
  const pileEl = document.querySelector(`.pile[data-pile="${CSS.escape(p.id)}"]`);
  pendingFlight = pileEl && destEl ? [pileEl, destEl] : null;
  if (p.path) {
    launchFlight();
    lastCopyNote = `Copying ${p.title} to ${d.name}…`; updateLive();
    api.call('folders:copy', { paths: [p.path], folder: d.path }).then((r) => {
      lastCopyNote = !r ? 'Another copy is still running.' : r.cancelled ? `Stopped. ${r.saved} of ${r.total} copied.` : r.saved === r.total ? `Copied ${p.title} to ${d.name}.` : `${p.title} could not be copied completely.`;
      updateLive();
    });
    return;
  }
  exportSheet({ title: p.title, count: p.count }, { album: p.id, filter: 'all', search: '', sort: 'date', ascending: false }, null, p.bytes, p.count, d.path);
}

function launchFlight() {
  if (!pendingFlight) return;
  const [a, b] = pendingFlight.map((x) => x.getBoundingClientRect());
  pendingFlight = null;
  const from = [a.left + a.width / 2, a.top + a.height / 2], to = [b.left + 40, b.top + b.height / 2];
  const c = [(from[0] + to[0]) / 2, Math.min(from[1], to[1]) - 160];
  const frames = [];
  for (let k = 0; k <= 24; k++) {
    const t = k / 24, x = (1 - t) ** 2 * from[0] + 2 * (1 - t) * t * c[0] + t * t * to[0], y = (1 - t) ** 2 * from[1] + 2 * (1 - t) * t * c[1] + t * t * to[1];
    frames.push({ transform: `translate(${x - 19}px, ${y - 15}px) rotate(${(t - 0.5) * 50}deg) scale(${1 - 0.25 * t})`, opacity: t > 0.92 ? (1 - t) / 0.08 : 1 });
  }
  for (let i = 0; i < 3; i++) {
    const f = h('div', { class: 'flight' }, icon('photo'));
    document.body.append(f);
    f.animate(frames, { duration: 950, delay: i * 130, easing: 'ease-in-out', fill: 'both' }).finished.then(() => f.remove());
  }
}

function sendFiles(paths, appId) {
  pendingUploads = paths;
  if (isAndroid()) { pendingFolder = '/sdcard/Download'; go('nav_files'); } else go('app:' + appId);
}

function deviceView() {
  const d = state.details;
  const kv = (k, v) => h('div', { class: 'kv' }, h('span', {}, k), h('span', {}, v));
  const msg = h('div', { class: 'dim', style: 'margin-top:10px;min-height:20px' });
  const act = async (action) => {
    const restart = action === 'restart';
    if (!await confirmBox(restart ? `Restart the ${kindWord()}?` : `Put the ${kindWord()} to sleep?`,
      restart ? 'It will turn off and on again, and reappear here when it is back. Anything unsaved in open apps may be lost.' : 'The screen turns off. Nothing is closed or lost.', restart ? 'Restart' : 'Sleep')) return;
    msg.textContent = restart ? `Asking the ${kindWord()} to restart…` : `Putting the ${kindWord()} to sleep…`;
    const ok = await api.call('power', action);
    msg.textContent = ok ? (restart ? `The ${kindWord()} is restarting. It will reappear here when it is back.` : `The ${kindWord()} is asleep.`) : `The ${kindWord()} did not accept the request. Unlock it and try again.`;
  };
  const copyAll = h('button', { class: 'btn', onclick: () => { api.call('copy', d.info.map((r) => `${r[0]}: ${r[1]}`).join('\n')); copyAll.lastChild.textContent = 'Copied'; setTimeout(() => (copyAll.lastChild.textContent = 'Copy All'), 1500); } }, icon('file'), 'Copy All');
  return viewBox(h('div', { class: 'scroll' }, h('div', { class: 'pad', style: 'max-width:940px' },
    h('div', { class: 'banner' }, h('span', { class: 'banner-ic' }, icon('phone')), h('div', {}, h('h1', {}, d.name), h('div', { style: 'opacity:.9;font-size:16px' }, `${d.modelName} · ${d.osName} ${d.osVersion} · ${state.device.isNetwork ? 'Wi-Fi' : 'USB'}`))),
    h('div', { class: 'cards' },
      h('div', { class: 'card' }, h('h3', {}, 'Battery'), h('div', { style: 'display:flex;gap:18px;align-items:center' },
        d.battery != null ? ring(d.battery / 100, d.battery + '%', '', d.battery < 20 ? 'var(--red)' : 'var(--green)') : null,
        h('div', { style: 'flex:1' }, kv('Charging', d.charging == null ? 'Not reported' : d.charging ? 'Yes' : 'No'), kv('Health', d.health != null ? d.health + '%' : 'Not reported'), kv('Charge cycles', d.cycles != null ? count(d.cycles) : 'Not reported')))),
      h('div', { class: 'card' }, h('h3', {}, 'Storage'), h('div', { class: 'bar', style: 'height:9px' }, h('i', { style: `width:${d.totalBytes > 0 ? Math.round(((d.totalBytes - d.freeBytes) / d.totalBytes) * 100) : 0}%` })),
        kv('Used', bytes(d.totalBytes - d.freeBytes)), kv('Available', bytes(d.freeBytes)), kv('Capacity', bytes(d.totalBytes))),
      h('div', { class: 'card wide' }, h('div', { style: 'display:flex;justify-content:space-between;align-items:center;margin-bottom:8px' }, h('h3', { style: 'margin:0' }, 'Device information'), copyAll),
        h('div', { class: 'infogrid' }, d.info.map((r) => kv(r[0], r[1])))),
      h('div', { class: 'card wide' }, h('h3', {}, 'Quick actions'), h('div', { style: 'display:flex;gap:10px;flex-wrap:wrap' },
        h('button', { class: 'btn', disabled: !state.canPower, onclick: () => act('restart') }, icon('restart'), 'Restart'),
        h('button', { class: 'btn', disabled: !state.canPower, onclick: () => act('sleep') }, icon('moon'), 'Sleep'),
        !isAndroid() ? h('button', { class: 'btn', onclick: () => go('nav_backup') }, icon('clock'), 'Back Up…') : null,
        h('button', { class: 'btn', onclick: () => api.call('refresh') }, icon('refresh'), 'Refresh Details')), msg)),
    state.warnings.length ? h('div', { class: 'note' }, state.warnings.join(' ')) : null)));
}

// MARK: albums and export

const FILTERS = [['all', 'All'], ['photos', 'Photos'], ['videos', 'Videos'], ['live', 'Live Photos'], ['screenshots', 'Screenshots'], ['favorites', 'Favorites'], ['heic', 'HEIC']];

function albumView() {
  const meta = [...state.smart, ...state.user].find((a) => a.id === selection);
  const init = lensInit || {};
  lensInit = null;
  const q = { album: selection, filter: init.filter || 'all', search: '', sort: 'date', ascending: false, from: init.from ?? null, to: init.to ?? null, minBytes: init.minBytes || 0 };
  let info = { rows: [], bytes: 0, videos: 0 };
  const sub = h('div', { class: 'dim' });
  const msg = h('div', { class: 'msg' });
  const selBytes = () => info.rows.reduce((n, r) => (table.selected.has(r[0]) ? n + Math.max(0, r[3]) : n), 0);
  const destBtn = h('button', { class: 'dest-pick', onclick: (e) => pickDestination(e.currentTarget) });
  const exportSel = h('button', { class: 'btn', onclick: () => exportSheet(meta, q, [...table.selected], selBytes()) }, icon('arrow'), 'Copy Selected…');
  const exportAll = h('button', { class: 'btn primary', onclick: () => exportSheet(meta, q, null, info.bytes, info.rows.length) }, icon('arrow'), 'Copy All…');
  const stop = h('button', { class: 'btn', onclick: () => { stop.disabled = true; stop.textContent = 'Stopping…'; api.call('export:stop'); } }, 'Stop');
  const table = new VTable({
    rowKey: (r) => r[0],
    columns: [
      { title: 'Name', flex: true, sort: 'name', ascFirst: true, cell: (r) => (r[8] ? r[1] + '  ♥' : r[1]), tip: true },
      { title: 'Kind', width: 130, cls: 'sec', sort: 'kind', cell: (r) => r[2] },
      { title: 'Size', width: 90, cls: 'tn', sort: 'size', cell: (r) => bytes(r[3]) },
      { title: 'Dimensions', width: 115, cls: 'sec tn', sort: 'resolution', cell: (r) => r[4] },
      { title: 'Date', width: 150, cls: 'tn', sort: 'date', cell: (r) => r[5] },
      { title: 'Original Name', width: 150, cls: 'sec', sort: 'original', ascFirst: true, cell: (r) => r[6], tip: true },
      { title: 'Device Folder', width: 130, cls: 'sec', sort: 'folder', ascFirst: true, cell: (r) => r[7] },
    ],
    onSort: (sort, asc) => { q.sort = sort; q.ascending = asc; load(true); },
    onSelect: () => drawBar(),
    onOpen: (r) => previewSheet(r),
    empty: () => [h('b', {}, 'Nothing here'), h('span', {}, q.search || q.filter !== 'all' || q.from != null || q.minBytes ? 'Nothing matches the search or filters.' : 'This group is empty.')],
  });
  table.sort = 'date';
  table.drawHead();
  const actionbar = h('div', { class: 'actionbar' });
  function drawBar() {
    if (!actionbar.isConnected && actionbar.dataset.drawn) { liveViews.delete(drawBar); return; }
    actionbar.dataset.drawn = '1';
    const p = live.export;
    if (p) {
      actionbar.replaceChildren(h('span', { class: 'mini-ring', style: `--p:${Math.round(frac(p) * 100)}` }),
        h('div', { class: 'msg' }, h('b', {}, `Copying to ${live.destName} · ${count(Math.min(p.total, p.copied + p.skipped + p.failed + (p.inFlight || 0)))} of ${count(p.total)}`), '  ', h('span', { class: 'dim' }, progressText(p))), stop);
      return;
    }
    stop.disabled = false; stop.textContent = 'Stop';
    const n = table.selected.size;
    msg.textContent = n ? `${plural(n, 'item')} selected · ${bytes(selBytes())}` : 'Click to select. Shift-click for a range, Ctrl-click to add, Ctrl+A for all.';
    exportSel.lastChild.textContent = n ? `Copy ${count(n)} Selected…` : 'Copy Selected…';
    exportSel.disabled = !n;
    exportAll.lastChild.textContent = `Copy All ${count(info.rows.length)}…`;
    exportAll.disabled = !info.rows.length;
    const d = destCache.find((x) => x.path === pendingDest);
    destBtn.replaceChildren(icon('arrow'), pendingDest ? `To ${d ? d.name : pendingDest.split(/[\\/]/).pop()}` : 'Choose where', icon('chev'));
    actionbar.replaceChildren(msg, destBtn, exportSel, exportAll);
  }
  liveViews.add(drawBar);
  const load = async (keep) => {
    info = await api.call('album:rows', q);
    sub.textContent = `${plural(info.rows.length, 'item')} · ${bytes(info.bytes)}` + (info.videos ? ` · ${plural(info.videos, 'video')}` : '');
    table.setRows(info.rows, keep);
    drawChips();
    timeline.refresh();
  };
  const chipRow = h('div', { class: 'toolbar' });
  let timer;
  const search = h('input', { class: 'search', placeholder: 'Search name, folder or date', oninput: () => { clearTimeout(timer); timer = setTimeout(() => { q.search = search.value; load(); }, 160); } });
  function drawChips() {
    chipRow.replaceChildren(...FILTERS.map(([id, text]) => h('button', { class: 'chip' + (q.filter === id ? ' on' : ''), onclick: () => { q.filter = id; load(); } }, text)),
      q.minBytes ? h('button', { class: 'chip on violet', title: 'Remove the size filter', onclick: () => { q.minBytes = 0; load(); } }, `Over ${bytes(q.minBytes)}  ✕`) : null, search);
  }
  const timeline = timelineStrip(selection, q, () => load());
  api.call('destinations').then((d) => { destCache = d; drawBar(); });
  load();
  const [ic, color] = SMART_ICONS[selection] || ['album', '#5aa2ff'];
  return viewBox(h('div', { class: 'head' }, h('div', { class: 'big', style: `background:${color}` }, icon(ic)), h('div', {}, h('h2', {}, meta.title), sub)),
    chipRow, timeline.el, table.el, actionbar);
}

function pickDestination(anchor) {
  popover(anchor, [[null, 'Copy to'], ...destCache.map((d) => [d.name, d.path === pendingDest ? 'check' : (d.kind === 'drive' ? 'drive' : 'folder'), () => { pendingDest = d.path; updateLive(); }]),
    '-', ['Choose another folder…', 'plus', async () => { const p = await api.call('pick:folder', 'Choose where to copy'); if (p) { destCache = await api.call('dest:remember', p); pendingDest = p; updateLive(); } }],
    ...(pendingDest ? [['Ask each time', 'refresh', () => { pendingDest = null; updateLive(); }]] : [])]);
}

/// Monthly bars for a group. Drag across them to keep only that stretch of time.
function timelineStrip(albumId, q, onChange) {
  const label = h('span', { class: 'tl-label' });
  const clear = h('button', { class: 'link hidden', onclick: () => { q.from = q.to = null; onChange(); } }, 'Show all dates');
  const bars = h('div', { class: 'tl-bars' });
  const ends = h('div', { class: 'tl-ends' });
  const el = h('div', { class: 'timeline hidden' }, h('div', { class: 'tl-top' }, label, clear), bars, ends);
  let months = [], drag = null;
  const draw = () => {
    if (months.length < 2) { el.classList.add('hidden'); return; }
    el.classList.remove('hidden');
    const peak = Math.max(1, ...months.map((m) => m.photos + m.videos));
    const sel = drag || (q.from != null ? [months.findIndex((m) => m.to >= q.from), months.length - 1 - [...months].reverse().findIndex((m) => m.from <= q.to)] : null);
    bars.replaceChildren(...months.map((m, i) => h('div', { class: 'tl-col' + (sel && (i < sel[0] || i > sel[1]) ? ' dim' : '') + (sel && i >= sel[0] && i <= sel[1] ? ' sel' : '') },
      h('i', { class: 'p', style: `height:${(m.photos / peak) * 100}%` }), h('i', { class: 'v', style: `height:${(m.videos / peak) * 100}%` }))));
    ends.replaceChildren(h('span', {}, months[0].label), h('span', {}, months[months.length - 1].label));
    label.textContent = drag ? `${months[drag[0]].label} – ${months[drag[1]].label}` : (q.from != null ? rangeText(q.from, q.to) : 'Every month · drag across to pick a stretch of time');
    clear.classList.toggle('hidden', q.from == null);
  };
  const indexAt = (x) => { const r = bars.getBoundingClientRect(); return Math.max(0, Math.min(months.length - 1, Math.floor(((x - r.left) / r.width) * months.length))); };
  bars.addEventListener('pointerdown', (e) => { const i = indexAt(e.clientX); drag = [i, i, i]; bars.setPointerCapture(e.pointerId); draw(); });
  bars.addEventListener('pointermove', (e) => { if (!drag) return; const i = indexAt(e.clientX); drag = [Math.min(drag[2], i), Math.max(drag[2], i), drag[2]]; draw(); });
  bars.addEventListener('pointerup', () => { if (!drag) return; q.from = months[drag[0]].from; q.to = months[drag[1]].to; drag = null; onChange(); });
  api.call('album:months', albumId).then((m) => { months = m; draw(); });
  return { el, refresh: draw };
}

async function previewSheet(r) {
  const img = h('div', { class: 'dim', style: 'text-align:center;padding:30px' }, 'Loading preview…');
  openModal(h('div', { class: 'sheet preview' }, img, h('h2', {}, r[1]), h('div', { class: 'dim' }, `${r[2]} · ${bytes(r[3])} · ${r[4]} · ${r[5]}`),
    h('div', { class: 'dim', style: 'margin-top:4px' }, `Original name: ${r[6]} · Folder: ${r[7]}`),
    h('div', { class: 'foot' }, h('button', { class: 'btn primary', onclick: closeModal }, 'Close'))));
  const p = await api.call('thumb', r[0]);
  if (p) img.replaceWith(h('img', { src: 'file:///' + p.replace(/\\/g, '/').replace(/^\//, '') }));
  else img.textContent = 'No preview is stored on the device for this item. Copy it to see it.';
}

async function exportSheet(meta, query, ids, totalBytes, n, preset) {
  const total = ids ? ids.length : n;
  const defaults = await api.call('defaults');
  const sep = state.isWindows ? '\\' : '/';
  let dest = preset || pendingDest || `${defaults.pictures}${sep}${meta.title.replace(/[\\/:*?"<>|]/g, '-')}`;
  const destText = h('span', {}), spaceNote = h('div', {});
  const drivesRow = h('div', { class: 'drives' });
  const opt = { includeLiveVideo: false, useOriginalNames: false, subfolder: 'flat', skipExisting: true, setDates: true };
  const drives = await api.call('drives');
  const refresh = async () => {
    destText.textContent = '‎' + dest;
    const free = await api.call('space', dest);
    spaceNote.replaceChildren();
    if (free != null && totalBytes > 0 && free < totalBytes * 1.02) spaceNote.append(h('div', { class: 'note' }, `This disk has ${bytes(free)} free, but the copy needs ${bytes(totalBytes)}. Choose another place or select fewer items.`));
    else if (free != null) spaceNote.append(h('div', { class: 'dim', style: 'margin-top:6px;font-size:12.5px' }, `${bytes(free)} free on this disk.`));
    const d = drives.find((x) => dest.toLowerCase().startsWith(x.path.toLowerCase()));
    if (d && /^FAT/i.test(d.format)) spaceNote.append(h('div', { class: 'note' }, 'This drive uses the FAT32 format, which cannot hold a file larger than 4 GB. Big videos will fail to copy.'));
  };
  for (const d of drives) drivesRow.append(h('button', { class: 'chip', onclick: () => { dest = d.path + (/[\\/]$/.test(d.path) ? '' : sep) + 'Phone Export'; refresh(); } }, `${d.name} · ${bytes(d.free)} free`));
  const check = (key, text) => h('label', {}, h('input', { type: 'checkbox', checked: opt[key], onchange: (e) => (opt[key] = e.target.checked) }), text);
  const more = h('div', { class: 'hidden' },
    check('includeLiveVideo', 'Include the short video of each Live Photo'), check('useOriginalNames', 'Use original file names when the device kept them'),
    check('skipExisting', 'Skip files already in this folder (same name and size)'), check('setDates', 'Set each file’s date to when it was taken'),
    h('label', {}, 'Folders: ', h('select', { onchange: (e) => (opt.subfolder = e.target.value) }, h('option', { value: 'flat' }, 'One folder'), h('option', { value: 'yearMonth' }, 'By month (2026-11)'), h('option', { value: 'iphoneFolder' }, 'By device folder (100APPLE)'))));
  openModal(h('div', { class: 'sheet' }, h('h2', {}, `Copy ${plural(total, 'item')} from ${meta.title}`), h('div', { class: 'dim' }, `${bytes(totalBytes)} to copy. Nothing is removed from your ${kindWord()}.`),
    h('div', { class: 'stepno' }, h('div', { class: 'num' }, 1), 'Where should they go?'),
    h('div', { class: 'dest-row' }, icon('folder'), destText, h('button', { class: 'btn', onclick: async () => { const p = await api.call('pick:folder', 'Choose where to copy'); if (p) { dest = p; refresh(); } } }, 'Choose…')),
    drivesRow, spaceNote,
    h('div', { class: 'stepno' }, h('div', { class: 'num' }, 2), 'Copy'),
    h('div', { class: 'dim' }, 'Files already there are recognised and skipped. Nothing is ever overwritten.'),
    h('button', { class: 'btn', style: 'margin-top:10px', onclick: () => more.classList.toggle('hidden') }, 'More options'), more,
    h('div', { class: 'foot' }, h('button', { class: 'btn', onclick: () => { pendingFlight = null; closeModal(); } }, 'Cancel'),
      h('button', { class: 'btn primary', onclick: () => runExport(meta, query, ids, dest, opt) }, icon('arrow'), 'Copy'))));
  refresh();
}

async function runExport(meta, query, ids, dest, options) {
  closeModal();
  if (!ids) { const r = await api.call('album:rows', query); ids = r.rows.map((x) => x[0]); }
  live.export = { copied: 0, skipped: 0, failed: 0, total: ids.length, bytesDone: 0, bytesTotal: 0, bytesPerSecond: 0 };
  const d = destCache.find((x) => x.path === dest);
  live.destName = d ? d.name : dest.split(/[\\/]/).filter(Boolean).pop();
  updateLive();
  launchFlight();
  let s;
  try { s = await api.call('export:start', { query, ids, dest, options }); }
  finally { live.export = null; updateLive(); }
  if (!s) return;
  const title = s.fatalError ? 'The copy could not start' : s.stalled ? `The ${kindWord()} stopped responding` : s.disconnected ? `The ${kindWord()} was disconnected` : s.cancelled ? 'Copy stopped'
    : s.failures.length ? 'Finished, with some items missing' : 'All done';
  const text = s.fatalError ? s.fatalError : s.stalled ? `Everything copied so far is safe. It usually means the ${kindWord()} locked itself: unlock it, then copy to the same folder to continue.`
    : s.disconnected ? 'Everything copied so far is safe. Plug it back in and copy to the same folder to continue.' : s.cancelled ? 'Everything copied so far is safe. Copy to the same folder to continue where it stopped.'
      : `${bytes(s.bytesCopied)} copied in ${Math.max(1, Math.round(s.elapsed))} s.`;
  const stat = (v, label) => h('div', { class: 'stat' }, h('b', {}, count(v)), h('small', {}, label));
  openModal(h('div', { class: 'sheet' }, h('h2', {}, title), h('div', { class: 'dim' }, text),
    h('div', { class: 'stats' }, stat(s.copied, 'copied'), stat(s.skipped, 'already there'), stat(s.failures.length + s.notAttempted, s.notAttempted ? 'not copied yet' : 'could not be copied')),
    s.liveVideos ? h('div', { class: 'dim' }, `${plural(s.liveVideos, 'Live Photo video')} also copied.`) : null,
    s.failures.length ? h('div', { class: 'fails' }, s.failures.slice(0, 200).map((f) => h('div', {}, `${f.filename} — ${f.reason}`))) : null,
    h('div', { class: 'foot' },
      s.failures.length && !s.disconnected ? h('button', { class: 'btn', onclick: () => runExport(meta, query, s.failedIds, dest, options) }, 'Try Those Again') : null,
      h('button', { class: 'btn', onclick: () => api.call('reveal', s.destination) }, icon('folder'), 'Show Folder'), h('button', { class: 'btn primary', onclick: closeModal }, 'Done'))));
}

// MARK: files on the device

let pendingFolder = null;
function filesView() {
  const appId = selection.startsWith('app:') ? selection.slice(4) : null;
  const appName = appId ? (state.apps.find((a) => a.id === appId) || { name: 'App' }).name : null;
  const title = isAndroid() ? 'Phone Storage' : (appName || 'Media Files');
  let cur = { root: '/', path: '/', entries: [], canAdd: false }, busy = false;
  const crumbs = h('div', { class: 'crumbs' }), msg = h('div', { class: 'msg' }), buttons = h('div', { style: 'display:flex;gap:10px' });
  const table = new VTable({
    rowKey: (e) => e.path,
    columns: [{ title: 'Name', flex: true, cell: (e) => (e.isDirectory ? '📁  ' : '') + e.name, tip: true }, { title: 'Size', width: 110, cls: 'sec tn', cell: (e) => (e.isDirectory ? '—' : bytes(e.size)) }, { title: 'Modified', width: 190, cls: 'sec tn', cell: (e) => e.modified }],
    onOpen: (e) => { if (e.isDirectory) open(e.path); },
    onSelect: () => drawBar(),
    empty: () => [h('b', {}, 'This folder is empty'), cur.canAdd ? h('span', {}, 'Drag files here, or click Add Files.') : null],
  });
  const setMsg = (t) => { msg.textContent = t; };
  const apply = (r) => {
    if (!r) return;
    cur = r; table.setRows(r.entries);
    const parts = r.path.slice(r.root.length).split('/').filter(Boolean);
    const list = [[appName && !isAndroid() ? appName : kindWord(), r.root]];
    let acc = r.root === '/' ? '' : r.root;
    for (const p of parts) { acc += '/' + p; list.push([p, acc]); }
    crumbs.replaceChildren(h('button', { disabled: list.length < 2, onclick: () => open(list[list.length - 2][1]) }, icon('back')),
      ...list.flatMap(([name, p], i) => [i ? h('span', {}, '›') : null, h('button', { class: i === list.length - 1 ? 'last' : '', onclick: () => open(p) }, name)]));
    drawBar();
  };
  const open = async (p) => apply(await api.call('files:list', p));
  const drawBar = () => {
    const n = table.selected.size;
    if (!busy && !msg.dataset.keep) setMsg(n ? `${n} selected` : 'Select items to copy them to this computer.');
    buttons.replaceChildren(...(busy ? [h('button', { class: 'btn', onclick: () => api.call('files:stop') }, 'Stop')] : [
      cur.canAdd ? h('button', { class: 'btn', onclick: newFolder }, icon('plus'), 'New Folder') : null,
      cur.canAdd ? h('button', { class: 'btn' + (n ? '' : ' primary'), onclick: async () => upload(await api.call('pick:files')) }, icon('up'), 'Add Files…') : null,
      n || !cur.canAdd ? h('button', { class: 'btn primary', disabled: !n, onclick: download }, icon('down'), `Copy ${n} to Computer…`) : null]));
  };
  const work = async (fn) => { busy = true; delete msg.dataset.keep; drawBar(); try { await fn(); } finally { busy = false; msg.dataset.keep = '1'; drawBar(); setTimeout(() => delete msg.dataset.keep, 50); } };
  const upload = (paths) => paths && paths.length && work(async () => {
    const r = await api.call('files:upload', paths);
    if (!r) return setMsg('Another copy is still running.');
    table.setRows(r.entries); cur.entries = r.entries;
    setMsg(r.cancelled ? `Stopped. ${r.added} of ${r.total} added.` : r.added === r.total ? `Added ${plural(r.added, 'item')}.` + (appName ? ` Open ${appName} on the ${kindWord()} to see ${r.added === 1 ? 'it' : 'them'}.` : '') : `Added ${r.added} of ${r.total}. ${r.total - r.added} could not be added.`);
  });
  const download = async () => {
    const folder = await api.call('pick:folder', 'Choose where to copy');
    if (!folder) return;
    work(async () => {
      const r = await api.call('files:download', { paths: [...table.selected], folder });
      if (!r) return setMsg('Another copy is still running.');
      setMsg(r.cancelled ? `Stopped. ${r.saved} of ${r.total} copied.` : r.saved === r.total ? `Copied ${plural(r.saved, 'item')}.` : `Copied ${r.saved} of ${r.total}. ${r.total - r.saved} could not be copied.`);
    });
  };
  const newFolder = async () => {
    const name = await promptBox('New folder', `Creates a folder here on your ${kindWord()}.`, 'Folder name', 'Create');
    if (!name) return;
    const r = await api.call('files:mkdir', name);
    if (r) { table.setRows(r.entries); cur.entries = r.entries; msg.dataset.keep = '1'; setMsg(r.ok ? `Created “${name}”.` : 'The folder could not be created.'); setTimeout(() => delete msg.dataset.keep, 50); }
  };
  filesProgress = (t) => { if (busy) setMsg(t); };
  const el = viewBox(h('div', { class: 'head' }, h('div', { class: 'big', style: `background:${isAndroid() ? '#3ecf74' : appId ? '#35c9a5' : '#8a8894'}` }, icon(appId ? 'app' : 'folder')),
    h('div', {}, h('h2', {}, title), h('div', { class: 'dim' }, isAndroid() ? "Everything in the device's shared storage: Camera (DCIM), Pictures, Download and more. Drag files in, or copy them out."
      : appId ? `Files you add here appear inside ${appName} on your ${kindWord()}. Drag files in, or copy them out.` : 'The media area the device shares over USB. You can copy from here, but not add to it. For photos, use the albums on the left.'))),
    crumbs, table.el, h('div', { class: 'actionbar' }, msg, buttons));
  el.addEventListener('dragover', (e) => { if (cur.canAdd && !busy) { e.preventDefault(); el.classList.add('drop'); } });
  el.addEventListener('dragleave', () => el.classList.remove('drop'));
  el.addEventListener('drop', (e) => { e.preventDefault(); el.classList.remove('drop'); if (cur.canAdd && !busy) upload([...e.dataTransfer.files].map((f) => api.pathOf(f)).filter(Boolean)); });
  (async () => {
    apply(await api.call('files:open', appId));
    if (pendingFolder) { const p = pendingFolder; pendingFolder = null; await open(p); }
    if (pendingUploads) { const u = pendingUploads; pendingUploads = null; upload(u); }
  })();
  return el;
}
let filesProgress = null;

// MARK: backups

let backupProgress = null, backupRunning = false;
function backupView() {
  const list = h('div', {}), folderText = h('span', {}), drivesRow = h('div', { class: 'drives' }), status = h('div', {});
  const bar = h('progress', { max: 1, value: 0, class: 'hidden' });
  const start = h('button', { class: 'btn primary', onclick: () => run(null) }, icon('clock'), 'Back Up Now');
  let restoringNow = false;
  const stop = h('button', { class: 'btn hidden', onclick: async () => {
    if (restoringNow && !await confirmBox('Stop the restore?', `The ${kindWord()} may be left incomplete until you run the restore again.`, 'Stop Restore')) return;
    stop.disabled = true; api.call('backup:stop');
  } }, 'Stop');
  const drawList = (items) => {
    list.replaceChildren(...(items.length ? items.map((b) => h('div', { class: 'kv', style: 'padding:9px 0;border-top:1px solid var(--line)' },
      h('span', { style: 'color:var(--text)' }, h('b', {}, b.deviceName), h('div', { class: 'dim' }, [b.date ? new Date(b.date).toLocaleString() : 'Unfinished', b.osVersion ? `iOS ${b.osVersion}` : null, b.encrypted ? 'Encrypted' : 'Not encrypted'].filter(Boolean).join(' · '))),
      h('div', { style: 'display:flex;gap:8px' }, h('button', { class: 'btn', onclick: () => api.call('reveal', b.path) }, 'Show'),
        h('button', { class: 'btn', disabled: !b.date || !state.canBackup, onclick: () => restoreSheet(b) }, 'Restore…')))) : [h('div', { class: 'dim' }, 'No backups in this folder yet.')]));
  };
  const setFolder = async (p) => { drawList(await api.call('backup:folder', p)); folderText.textContent = '‎' + p; };
  // Nothing starts until the box is ticked and RESTORE is typed.
  function restoreSheet(b) {
    const name = state.details.name;
    const tick = h('input', { type: 'checkbox' }), word = h('input', { type: 'text', placeholder: 'RESTORE', style: 'width:140px' });
    const pw = b.encrypted ? h('input', { type: 'password', placeholder: 'Backup password', style: 'width:100%;margin-bottom:8px' }) : null;
    const goBtn = h('button', { class: 'btn primary', disabled: true, onclick: () => { const password = pw ? pw.value : null; closeModal(); run({ path: b.path, password }); } }, 'Restore Now');
    const check = () => { goBtn.disabled = !(tick.checked && word.value.trim().toUpperCase() === 'RESTORE' && (!pw || pw.value)); };
    for (const el of [tick, word, pw]) if (el) { el.addEventListener('input', check); el.addEventListener('change', check); }
    const point = (t) => h('div', { style: 'display:flex;gap:9px;padding:3px 0' }, h('span', { style: 'color:var(--orange)' }, '▲'), h('span', {}, t));
    openModal(h('div', { class: 'sheet' }, h('h2', {}, `Restore ${name} from a backup?`),
      h('div', { class: 'dim' }, `Backup of ${b.deviceName}` + (b.date ? `, made ${new Date(b.date).toLocaleString()}` : '')),
      h('div', { class: 'note', style: 'color:var(--text)' },
        point(`Settings, messages and app data on ${name} are replaced with what is in this backup. Anything newer than the backup can be lost, and this cannot be undone.`),
        point(`Find My must be turned off on the ${kindWord()} first (Settings, your name, Find My).`),
        point(`Keep the ${kindWord()} plugged in and unlocked until it restarts. Unplugging part-way can leave it incomplete.`),
        point('If there is anything on it you want to keep, make a fresh backup first.')),
      h('div', { style: 'margin-top:12px' }, pw),
      h('label', {}, tick, `I understand that this replaces data on ${name}`),
      h('label', {}, 'Type RESTORE to confirm:', word),
      h('div', { class: 'foot' }, h('button', { class: 'btn', onclick: closeModal }, 'Cancel'), goBtn)));
  }
  async function run(restore) {
    restoringNow = !!restore;
    backupRunning = true; start.classList.add('hidden'); stop.classList.remove('hidden'); stop.disabled = false; bar.classList.remove('hidden'); bar.removeAttribute('value');
    status.replaceChildren(h('div', { class: 'dim', style: 'margin-top:8px' }, `Starting… enter the passcode on the ${kindWord()} if it asks.`));
    backupProgress = (p) => { if (p.percent != null) bar.value = p.percent; status.replaceChildren(h('div', { class: 'dim', style: 'margin-top:8px' }, p.phase + (p.percent != null ? ` ${Math.round(p.percent * 100)}%` : ''))); };
    const problem = restore ? await api.call('backup:restore', restore) : await api.call('backup:start');
    backupRunning = false; backupProgress = null;
    start.classList.remove('hidden'); stop.classList.add('hidden'); bar.classList.add('hidden');
    status.replaceChildren(h('div', { class: 'note' + (problem ? '' : ' ok') }, problem || (restore ? `Restore complete. The ${kindWord()} is restarting and will reappear here when it is back.` : 'Backup complete.')));
    drawList(await api.call('backup:list'));
  }
  (async () => {
    folderText.textContent = '‎' + state.backupFolder;
    drawList(await api.call('backup:list'));
    for (const d of await api.call('drives')) drivesRow.append(h('button', { class: 'chip', onclick: () => setFolder(d.path + (/[\\/]$/.test(d.path) ? '' : '/') + 'Phone Backups') }, `${d.name} · ${bytes(d.free)} free`));
  })();
  return viewBox(h('div', { class: 'scroll' }, h('div', { class: 'pad', style: 'max-width:820px' },
    h('h1', {}, 'Backups', h('span', { class: 'beta' }, 'BETA')), h('div', { class: 'dim', style: 'margin-top:4px' }, `A full copy of the ${kindWord()}: messages, app data, settings and photos. The same format Apple’s own tools make.`),
    h('div', { class: 'card', style: 'margin-top:18px' }, h('h3', {}, 'Where backups are kept'),
      h('div', { class: 'dest-row' }, icon('folder'), folderText, h('button', { class: 'btn', onclick: async () => { const p = await api.call('pick:folder', 'Choose a backup folder'); if (p) setFolder(p); } }, 'Choose…')), drivesRow),
    h('div', { class: 'card', style: 'margin-top:16px' }, h('h3', {}, 'Back up now'),
      h('div', { class: 'dim', style: 'margin-bottom:12px' }, `Keep the ${kindWord()} connected and unlocked. The first backup can take a long time; later ones only copy what changed. Nothing on the ${kindWord()} is changed or removed.`),
      state.canBackup ? h('div', { style: 'display:flex;gap:10px' }, start, stop) : h('div', { class: 'note' }, 'The backup tool is missing from this copy of the app.'), h('div', { style: 'margin-top:12px' }, bar), status),
    h('div', { class: 'card', style: 'margin-top:16px' }, h('h3', {}, 'Backups in this folder'), list))));
}

// MARK: data read out of a backup

function dataView(kind) {
  const [, title, ic, color] = DATA_KINDS.find((k) => k[0] === kind);
  const source = h('div', { class: 'dim' }, 'Read from your newest backup. Nothing on the device or in the backup is changed.');
  const body = h('div', { style: 'flex:1;min-height:0;display:flex;flex-direction:column' });
  const loading = (t) => body.replaceChildren(h('div', { class: 'center' }, h('div', { class: 'spinner' }), h('div', { class: 'dim' }, t)));
  const load = async (password) => {
    loading(password ? 'Unlocking the backup… this takes a few seconds.' : 'Reading the backup…');
    const r = await api.call('data:open', { kind, password });
    if (r.source) source.textContent = `${r.source}. Nothing in it is changed.`;
    if (r.needsPassword) return askPassword(r.wrongPassword);
    if (r.note || !r.groups.length) return body.replaceChildren(h('div', { class: 'center' }, h('div', { class: 'hero', style: 'animation:none;width:70px;height:70px;border-radius:20px;opacity:.5' }, icon('box')),
      h('div', { class: 'dim', style: 'max-width:480px;font-size:16px' }, r.note || 'Nothing to show.'), h('button', { class: 'btn', onclick: () => go('nav_backup') }, icon('clock'), 'Open Backups')));
    draw(r.groups);
  };
  const askPassword = (wrong) => {
    const input = h('input', { type: 'password', placeholder: 'Backup password', style: 'width:240px;background:var(--bg);border:1px solid var(--line);border-radius:9px;padding:8px 10px;outline:none' });
    const unlock = () => input.value && load(input.value);
    input.addEventListener('keydown', (e) => e.key === 'Enter' && unlock());
    body.replaceChildren(h('div', { class: 'center' }, h('div', { class: 'hero', style: 'animation:none;width:70px;height:70px;border-radius:20px' }, icon('lock')), h('h2', {}, 'This backup is protected by a password'),
      h('div', { class: 'dim', style: 'max-width:450px' }, 'Enter the backup password you chose when encrypted backups were turned on for this device. It is not your Apple Account password, and it is not saved by this app.'),
      h('div', { style: 'display:flex;gap:10px;margin-top:6px' }, input, h('button', { class: 'btn primary', onclick: unlock }, 'Unlock')),
      wrong ? h('div', { class: 'note' }, 'That password did not open the backup. Check it and try again.') : null));
    input.focus();
  };
  const draw = (groups) => {
    let current = null, all = { columns: [], rows: [] };
    const msg = h('div', { class: 'msg' }), shown = h('span', { class: 'dim', style: 'padding:0 12px;font-size:12px;white-space:nowrap' });
    const rowSearch = h('input', { class: 'rowsearch', placeholder: 'Search', oninput: () => filter() });
    const holder = h('div', { style: 'flex:1;min-height:0;display:flex;flex-direction:column' });
    let table = null;
    const copyBtn = h('button', { class: 'btn primary', disabled: true, onclick: async () => {
      const folder = await api.call('pick:folder', 'Choose where to copy'); if (!folder) return;
      msg.textContent = 'Copying…';
      const r = await api.call('data:extract', { id: current.id, rows: [...table.selected], folder });
      msg.textContent = r.written === r.total ? `Copied ${plural(r.written, 'file')}.` : `Copied ${r.written} of ${r.total}. The rest could not be copied.`;
    } }, icon('down'), 'Copy to Computer…');
    const save = async (everything) => {
      const folder = await api.call('pick:folder', 'Choose where to save'); if (!folder) return;
      const r = await api.call('data:save', { id: current.id, all: everything, folder });
      msg.textContent = r.written === r.total ? `Saved ${plural(r.written, 'spreadsheet file')}.` : `Saved ${r.written} of ${r.total}. The rest could not be written.`;
    };
    const filter = () => {
      const q = rowSearch.value.trim().toLowerCase();
      const rows = [];
      all.rows.forEach((r, i) => { if (!q || r.some((c) => String(c).toLowerCase().includes(q))) rows.push([i, r]); });
      table.setRows(rows);
      shown.textContent = `${count(rows.length)} shown`;
    };
    const pick = async (g) => {
      current = g; rowSearch.value = ''; rowSearch.placeholder = `Search in ${g.title}`;
      all = await api.call('data:rows', g.id);
      const n = all.columns.length;
      table = new VTable({ rowKey: (r) => r[0], columns: all.columns.map((c, i) => {
        const wide = (i === n - 1 && n > 2) || (kind === 'files' && i === 1);
        return { title: c, flex: wide, width: /Date|Starts|Ends|Visited|changed|Length|Kind/.test(c) ? 150 : 210, cls: i && !wide ? 'sec' : '', cell: (r) => r[1][i] ?? '', tip: true };
      }), onSelect: (sel) => { copyBtn.disabled = !sel.size; if (kind === 'files') msg.textContent = sel.size ? `${sel.size} selected` : 'Select files to copy them out of the backup.'; } });
      holder.replaceChildren(table.el);
      filter();
      glist.querySelectorAll('.g').forEach((b) => b.classList.toggle('on', Number(b.dataset.id) === g.id));
    };
    const glist = h('div', { class: 'glist' });
    const drawGroups = (q) => glist.replaceChildren(...groups.filter((g) => !q || (g.title + ' ' + g.subtitle).toLowerCase().includes(q)).map((g) =>
      h('button', { class: 'g' + (current && current.id === g.id ? ' on' : ''), 'data-id': g.id, onclick: () => pick(g) }, h('div', {}, h('b', {}, g.title), g.subtitle && g.subtitle !== g.title ? h('small', {}, g.subtitle) : null), h('i', {}, count(g.count)))));
    drawGroups('');
    if (kind !== 'files') msg.textContent = 'Save as a spreadsheet file that opens in Excel.';
    body.replaceChildren(h('div', { class: 'split' },
      groups.length > 1 ? h('div', { class: 'groups' }, h('input', { placeholder: `Find in ${count(groups.length)} ${kind === 'files' ? 'areas' : kind === 'messages' || kind === 'whatsapp' ? 'conversations' : 'lists'}`, oninput: (e) => drawGroups(e.target.value.trim().toLowerCase()) }), glist) : null,
      h('div', { class: 'rows-pane' }, h('div', { class: 'rows-head' }, rowSearch, shown), holder)),
    h('div', { class: 'actionbar' }, msg, kind === 'files' ? copyBtn : [groups.length > 1 ? h('button', { class: 'btn', onclick: () => save(true) }, 'Save All…') : null, h('button', { class: 'btn primary', onclick: () => save(false) }, icon('down'), 'Save This…')]));
    pick(groups[0]);
  };
  load(null);
  return viewBox(h('div', { class: 'head' }, h('div', { class: 'big', style: `background:${color}` }, icon(ic)), h('div', {}, h('h2', {}, title), source)), body);
}

// Anything that fails unexpectedly is shown briefly instead of leaving the window stuck.
window.addEventListener('unhandledrejection', (e) => {
  const raw = String((e.reason && e.reason.message) || e.reason || 'unknown error');
  const t = h('div', { class: 'toast' }, icon('warn'), h('span', {}, 'Something went wrong: ' + raw.replace(/^Error invoking remote method '[^']+': (Error: )?/, '')));
  document.body.append(t);
  setTimeout(() => t.remove(), 7000);
});

// MARK: start

api.on('state', (s) => { state = s; drawTopBar(); drawMain(false); });
api.on('export:progress', (p) => { if (live.export) { live.export = p; updateLive(); } });
api.on('files:progress', (t) => filesProgress && filesProgress(t));
api.on('backup:progress', (p) => backupProgress && backupProgress(p));
(async () => {
  state = await api.call('state');
  document.body.append(askPanel);
  drawTopBar(); drawMain(true);
  if (api.test.startsWith('select:')) {
    const want = api.test.slice(7);
    const wait = setInterval(() => { if (state.phase === 'ready') { clearInterval(wait); if (want.startsWith('ask:')) { askInput.value = want.slice(4); askInput.focus(); askPanel.classList.remove('hidden'); api.call('destinations').then((d) => { destCache = d; drawAskPanel(); }); } else if (want.startsWith('hop:')) { const [al, ...rest] = want.slice(4).split(':'); const dest = rest.join(':'); api.call('destinations').then((d) => { destCache = d; go('nav_home'); setTimeout(() => runExport({ title: al }, { album: al, filter: 'all', search: '', sort: 'date', ascending: false }, null, dest, {}), 800); }); } else if (want.startsWith('export:')) { go('smart_hidden'); runExport({ title: 'Hidden' }, { album: 'smart_hidden', filter: 'all', search: '', sort: 'date', ascending: false }, null, want.slice(7), {}); } else if (want.startsWith('folder:')) { pendingFolder = want.slice(7); go('nav_files'); } else go(want); } }, 200);
  }
})();

})();
