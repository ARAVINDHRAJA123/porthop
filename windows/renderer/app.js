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
const ICONS = {
  home: '<path d="M3 11l9-8 9 8v9a1 1 0 0 1-1 1h-5v-6h-6v6H4a1 1 0 0 1-1-1z"/>',
  phone: '<rect x="6" y="2" width="12" height="20" rx="3"/><path d="M11 18h2"/>',
  photo: '<rect x="3" y="4" width="18" height="16" rx="3"/><circle cx="9" cy="10" r="2"/><path d="M21 16l-5-5-8 9"/>',
  eye: '<path d="M3 3l18 18"/><path d="M10.6 6.2A9.7 9.7 0 0 1 12 6c6 0 9.5 6 9.5 6a16 16 0 0 1-2.6 3.2M6.2 7.9A15.6 15.6 0 0 0 2.5 12s3.5 6 9.5 6a9 9 0 0 0 3.3-.6"/>',
  heart: '<path d="M12 20s-7.5-4.6-9.3-9.2C1.4 7.300 3.600 4 7 4c2 0 3.700 1 5 2.800C13.300 5 15 4 17 4c3.400 0 5.600 3.300 4.300 6.800C19.500 15.400 12 20 12 20z"/>',
  video: '<rect x="2" y="6" width="14" height="12" rx="3"/><path d="M16 10l6-3v10l-6-3z"/>',
  live: '<circle cx="12" cy="12" r="3"/><circle cx="12" cy="12" r="7"/><circle cx="12" cy="12" r="10" stroke-dasharray="1 3.500"/>',
  shot: '<path d="M4 8V6a2 2 0 0 1 2-2h2M16 4h2a2 2 0 0 1 2 2v2M20 16v2a2 2 0 0 1-2 2h-2M8 20H6a2 2 0 0 1-2-2v-2"/><circle cx="12" cy="12" r="3"/>',
  person: '<circle cx="12" cy="8" r="4"/><path d="M4 21c1-4 4.500-6 8-6s7 2 8 6"/>',
  trash: '<path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/>',
  album: '<rect x="3" y="7" width="18" height="13" rx="3"/><path d="M6 4h12"/>',
  app: '<rect x="4" y="4" width="16" height="16" rx="5"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7.500v.500"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  file: '<path d="M7 3h7l5 5v12a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z"/><path d="M14 3v5h5"/>',
  msg: '<path d="M4 5h16a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1h-9l-5 4v-4H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1z"/>',
  note: '<path d="M6 3h12a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z"/><path d="M9 8h6M9 12h6M9 16h3"/>',
  cal: '<rect x="3" y="5" width="18" height="16" rx="3"/><path d="M3 10h18M8 3v4M16 3v4"/>',
  call: '<path d="M5 4h4l2 5-2.500 1.500a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2z"/>',
  globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3.500 3 14.500 0 18M12 3c-3 3.500-3 14.500 0 18"/>',
  box: '<path d="M3 8l9-5 9 5v8l-9 5-9-5z"/><path d="M3 8l9 5 9-5M12 13v8"/>',
  up: '<path d="M12 19V6M6 12l6-6 6 6"/>', down: '<path d="M12 5v13M6 12l6 6 6-6"/>',
  arrow: '<path d="M5 12h14M13 6l6 6-6 6"/>', back: '<path d="M15 5l-7 7 7 7"/>',
  cable: '<path d="M9 2v5M15 2v5M7 7h10v4a5 5 0 0 1-10 0zM12 16v6"/>',
  lock: '<rect x="5" y="11" width="14" height="10" rx="2.500"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
  refresh: '<path d="M20 11a8 8 0 0 0-14.500-4M4 4v4h4M4 13a8 8 0 0 0 14.500 4M20 20v-4h-4"/>',
  moon: '<path d="M20 14.500A8 8 0 0 1 9.500 4 8 8 0 1 0 20 14.500z"/>',
  plus: '<path d="M12 5v14M5 12h14"/>', warn: '<path d="M12 3l10 18H2z"/><path d="M12 10v5M12 18v.500"/>',
  check: '<path d="M5 12.500l4.500 4.500L19 7"/>', camera: '<path d="M4 8h3l2-3h6l2 3h3a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V9a1 1 0 0 1 1-1z"/><circle cx="12" cy="13" r="3.500"/>',
};
const icon = (name) => h('span', { html: `<svg viewBox="0 0 24 24">${(ICONS[name] || ICONS.app).replace(/(\d)00\b/g, '$1')}</svg>`, style: 'display:contents' });
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

// MARK: sidebar

const SMART_ICONS = { smart_hidden: ['eye', '#6d5bff'], smart_all: ['photo', '#3b8cff'], smart_favorites: ['heart', '#ff4d6a'], smart_videos: ['video', '#a05cff'],
  smart_live: ['live', '#ff9d2e'], smart_screenshots: ['shot', '#33c2c9'], smart_selfies: ['person', '#3ecf74'], smart_trashed: ['trash', '#8a8894'] };
const DATA_KINDS = [['messages', 'Messages', 'msg', '#3ecf74'], ['whatsapp', 'WhatsApp', 'call', '#2bbf9d'], ['contacts', 'Contacts', 'person', '#8a8894'], ['notes', 'Notes', 'note', '#e0b000'],
  ['calendar', 'Calendar', 'cal', '#ff5d5d'], ['calls', 'Call Log', 'call', '#33a9c9'], ['safari', 'Safari', 'globe', '#3b8cff'], ['files', 'Backup Files', 'box', '#a8794f']];

function drawSidebar() {
  const s = state, ready = s.phase === 'ready', d = s.details;
  const used = d && d.totalBytes > 0 ? Math.max(0, d.totalBytes - d.freeBytes) / d.totalBytes : 0;
  const card = h('div', { class: 'devcard' },
    h('div', { class: 'row' }, h('div', { class: 'devicon' }, icon('phone')),
      h('div', { style: 'min-width:0' }, h('div', { class: 'name' }, ready ? d.name : 'No device'),
        h('div', { class: 'sub' }, h('i', { class: 'dot' + (ready ? '' : ' off') }), ready ? `${d.osName} ${d.osVersion} · ${s.device.isNetwork ? 'Wi-Fi' : 'USB'}` : 'Not connected'))),
    ready && d.totalBytes > 0 ? [h('div', { class: 'bar' }, h('i', { style: `width:${Math.round(used * 100)}%` })), h('small', {}, `${bytes(d.freeBytes)} free of ${bytes(d.totalBytes)}`)] : null,
    ready && s.devices.length > 1 ? h('select', { onchange: (e) => api.call('switch', e.target.value) },
      s.devices.map((x) => h('option', { value: x.udid, selected: x.udid === s.device.udid }, x.name))) : null);
  const nav = (id, text, ic, color, n) => h('button', { class: 'nav' + (selection === id ? ' on' : ''), onclick: () => go(id) },
    tile(ic, color), h('span', { class: 't' }, text), n != null ? h('span', { class: 'n' }, count(n)) : null);
  const items = [card];
  if (ready) {
    items.push(nav('nav_home', 'Home', 'home', 'var(--accent)'));
    if (!isAndroid()) {
      items.push(h('div', { class: 'section' }, 'Library'));
      for (const a of s.smart) if (a.count || a.id === 'smart_hidden') items.push(nav(a.id, a.title, ...SMART_ICONS[a.id], a.count));
      if (s.user.length) { items.push(h('div', { class: 'section' }, 'Albums')); for (const a of s.user) items.push(nav(a.id, a.title, 'album', '#49a7ff', a.count)); }
      if (s.apps.length) { items.push(h('div', { class: 'section' }, 'Send files to apps')); for (const a of s.apps) items.push(nav('app:' + a.id, a.name, 'app', '#35c9a5')); }
      items.push(h('div', { class: 'section' }, 'From your backup'));
      for (const [k, t, ic, c] of DATA_KINDS) items.push(nav('bk:' + k, t, ic, c));
    }
    items.push(h('div', { class: 'section' }, kindWord()));
    items.push(nav('nav_device', 'Overview', 'info', '#3b8cff'));
    if (!isAndroid()) items.push(nav('nav_backup', 'Backups', 'clock', '#ff9d2e'));
    items.push(nav('nav_files', isAndroid() ? 'Phone Storage' : 'Media Files', 'folder', isAndroid() ? '#3ecf74' : '#8a8894'));
  }
  $('#sidebar').replaceChildren(...items);
}

function go(id) { selection = id; drawSidebar(); drawMain(true); }

// MARK: main area

function drawMain(force) {
  const s = state;
  const key = s.phase === 'ready' ? `ready:${selection}:${s.device.udid}` : `${s.phase}:${s.message}`;
  if (!force && key === drawnKey) { if (s.phase === 'ready' && selection === 'nav_home') show(homeView()); return; }
  drawnKey = key;
  if (s.phase !== 'ready') return show(statusView());
  if (selection === 'nav_home') return show(homeView());
  if (selection === 'nav_device') return show(deviceView());
  if (selection === 'nav_backup') return show(backupView());
  if (selection === 'nav_files' || selection.startsWith('app:')) return show(filesView());
  if (selection.startsWith('bk:')) return show(dataView(selection.slice(3)));
  if ([...s.smart, ...s.user].some((a) => a.id === selection)) return show(albumView());
  selection = 'nav_home'; drawSidebar(); show(homeView());
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
  if (s.phase === 'needsTrust') return viewBox(h('div', { class: 'center' }, hero('lock'), h('h1', {}, 'Unlock and allow'), h('div', { class: 'dim', style: 'max-width:540px' }, s.message), waiting('Checking again every few seconds')));
  if (s.phase === 'toolsMissing') return viewBox(h('div', { class: 'center' }, hero('box'), h('h1', {}, 'A part of the app is missing'),
    h('div', { class: 'dim', style: 'max-width:560px' }, 'The device tools that ship inside this app were not found. Download the app again and unzip the whole folder before opening it.'), waiting('Checking again every few seconds')));
  if (s.phase === 'catalogError') return viewBox(h('div', { class: 'center' }, hero('warn'), h('h1', {}, 'The photo library could not be read'), h('div', { class: 'dim', style: 'max-width:560px' }, s.message),
    h('button', { class: 'btn primary', onclick: () => api.call('refresh') }, icon('refresh'), 'Try Again')));
  const step = (n, title, text) => h('div', { class: 'step' }, h('div', { class: 'num' }, n), h('b', {}, title), h('span', { class: 'dim' }, text));
  return viewBox(h('div', { class: 'center' }, hero('cable'),
    h('h1', {}, s.hasAdb ? 'Connect your iPhone, iPad or Android' : 'Connect your iPhone or iPad'),
    h('div', { class: 'dim' }, 'Copy photos, videos and files to this computer or an external drive over USB.'),
    h('div', { class: 'steps' }, step(1, 'Plug in', 'Use a USB cable that carries data.'), step(2, 'Unlock and allow', 'Unlock the device. Tap Trust on an iPhone, or Allow on Android.'), step(3, 'Pick what to copy', 'Choose Hidden or any album, then Export.')),
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

function homeView() {
  const s = state, d = s.details;
  const n = (id) => (s.smart.find((a) => a.id === id) || { count: 0 }).count;
  const task = (ic, colors, title, text, action, disabled) => h('button', { class: 'task', disabled, onclick: action },
    h('div', { class: 'ic', style: `background:linear-gradient(135deg, ${colors[0]}, ${colors[1]})` }, icon(ic)), h('span', { class: 'go' }, icon('arrow')), h('b', {}, title), h('span', { class: 'dim' }, text));
  const openFolder = (p) => { pendingFolder = p; go('nav_files'); };
  const tiles = isAndroid() ? [
    task('camera', ['#3b8cff', '#33c2c9'], 'Copy camera photos to this computer', 'Everything the camera took, in the DCIM folder.', () => openFolder('/sdcard/DCIM')),
    task('photo', ['#6d5bff', '#a05cff'], 'Pictures and screenshots', 'Saved images, screenshots and pictures from apps.', () => openFolder('/sdcard/Pictures')),
    task('up', ['#35c9a5', '#2ba3a3'], `Send files to the ${kindWord()}`, 'Open Download, or any folder, and drag files in.', () => openFolder('/sdcard/Download')),
    task('video', ['#a05cff', '#e85aa0'], 'Movies and recordings', 'Videos saved in the Movies folder.', () => openFolder('/sdcard/Movies')),
    task('folder', ['#ff9d2e', '#e85aa0'], 'Browse all storage', "Every folder in the device's shared storage.", () => go('nav_files')),
    task('info', ['#8a8894', '#3b8cff'], `Check the ${kindWord()}`, 'Battery, storage, serial number and other details.', () => go('nav_device')),
  ] : [
    task('photo', ['#3b8cff', '#33c2c9'], 'Copy photos to this computer', `${count(n('smart_all'))} photos and videos. Pick some or take everything.`, () => go('smart_all')),
    task('eye', ['#6d5bff', '#a05cff'], 'Get the Hidden album', `${count(n('smart_hidden'))} hidden items, kept out of every other album.`, () => go('smart_hidden')),
    task('up', ['#35c9a5', '#2ba3a3'], `Send files to the ${kindWord()}`, s.apps.length ? `Drop files into ${s.apps.length} apps, such as video players and readers.` : 'No apps on this device share a folder yet.',
      () => go('app:' + s.apps[0].id), !s.apps.length),
    task('clock', ['#ff9d2e', '#e85aa0'], `Back up the ${kindWord()}`, 'A full copy of messages, app data and settings, to this computer or a drive.', () => go('nav_backup')),
    task('video', ['#a05cff', '#e85aa0'], 'Just the videos', `${count(n('smart_videos'))} videos, usually the biggest files. Sort by size to free space.`, () => go('smart_videos')),
    task('info', ['#8a8894', '#3b8cff'], `Check the ${kindWord()}`, 'Battery health, storage, serial number and other details.', () => go('nav_device')),
  ];
  const used = d.totalBytes > 0 ? (d.totalBytes - d.freeBytes) / d.totalBytes : 0;
  return viewBox(h('div', { class: 'scroll' }, h('div', { class: 'pad' },
    h('div', { style: 'display:flex;align-items:center;gap:20px' },
      h('div', { style: 'flex:1' }, h('h1', {}, 'What would you like to do?'), h('div', { class: 'dim', style: 'font-size:16px;margin-top:4px' }, `${d.name} is connected · ${d.osName} ${d.osVersion}`)),
      h('div', { class: 'gauges' }, d.battery != null ? ring(d.battery / 100, d.battery + '%', d.charging ? 'Charging' : 'Battery', d.battery < 20 ? 'var(--red)' : 'var(--green)') : null,
        d.totalBytes > 0 ? ring(used, bytes(d.freeBytes), 'Free', used > 0.9 ? 'var(--orange)' : 'var(--accent)') : null)),
    h('div', { class: 'tiles' }, tiles))));
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
    h('div', { class: 'banner' }, icon('phone'), h('div', {}, h('h1', {}, d.name), h('div', { style: 'opacity:.9;font-size:16px' }, `${d.modelName} · ${d.osName} ${d.osVersion} · ${state.device.isNetwork ? 'Wi-Fi' : 'USB'}`))),
    h('div', { class: 'cards' },
      h('div', { class: 'card' }, h('h3', {}, 'Battery'), h('div', { style: 'display:flex;gap:18px;align-items:center' },
        d.battery != null ? ring(d.battery / 100, d.battery + '%', '', d.battery < 20 ? 'var(--red)' : 'var(--green)') : null,
        h('div', { style: 'flex:1' }, kv('Charging', d.charging == null ? 'Not reported' : d.charging ? 'Yes' : 'No'), kv('Health', d.health != null ? d.health + '%' : 'Not reported'), kv('Charge cycles', d.cycles != null ? count(d.cycles) : 'Not reported')))),
      h('div', { class: 'card' }, h('h3', {}, 'Storage'), h('div', { class: 'bar', style: 'height:9px' }, h('i', { style: `width:${d.totalBytes > 0 ? Math.round(((d.totalBytes - d.freeBytes) / d.totalBytes) * 100) : 0}%` })),
        kv('Used', bytes(d.totalBytes - d.freeBytes)), kv('Available', bytes(d.freeBytes)), kv('Capacity', bytes(d.totalBytes))),
      h('div', { class: 'card wide' }, h('div', { style: 'display:flex;justify-content:space-between;align-items:center;margin-bottom:8px' }, h('h3', { style: 'margin:0' }, 'Device information'), copyAll),
        h('div', { class: 'infogrid' }, d.info.map((r) => kv(r[0], r[1])))),
      h('div', { class: 'card wide' }, h('h3', {}, 'Quick actions'), h('div', { style: 'display:flex;gap:10px;flex-wrap:wrap' },
        h('button', { class: 'btn', disabled: !state.canPower, onclick: () => act('restart') }, icon('refresh'), 'Restart'),
        h('button', { class: 'btn', disabled: !state.canPower, onclick: () => act('sleep') }, icon('moon'), 'Sleep'),
        !isAndroid() ? h('button', { class: 'btn', onclick: () => go('nav_backup') }, icon('clock'), 'Back Up…') : null,
        h('button', { class: 'btn', onclick: () => api.call('refresh') }, icon('refresh'), 'Refresh Details')), msg)),
    state.warnings.length ? h('div', { class: 'note' }, state.warnings.join(' ')) : null)));
}

// MARK: albums and export

const FILTERS = [['all', 'All'], ['photos', 'Photos'], ['videos', 'Videos'], ['live', 'Live Photos'], ['screenshots', 'Screenshots'], ['favorites', 'Favorites'], ['heic', 'HEIC']];

function albumView() {
  const meta = [...state.smart, ...state.user].find((a) => a.id === selection);
  const q = { album: selection, filter: 'all', search: '', sort: 'date', ascending: false };
  let info = { rows: [], bytes: 0, videos: 0 };
  const sub = h('div', { class: 'dim' });
  const msg = h('div', { class: 'msg' });
  const exportSel = h('button', { class: 'btn', onclick: () => exportSheet(meta, q, [...table.selected], selBytes()) }, icon('down'), 'Export Selected…');
  const exportAll = h('button', { class: 'btn primary', onclick: () => exportSheet(meta, q, null, info.bytes, info.rows.length) }, icon('down'), 'Export All…');
  const selBytes = () => info.rows.reduce((n, r) => (table.selected.has(r[0]) ? n + Math.max(0, r[3]) : n), 0);
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
    onSelect: (sel) => {
      exportSel.disabled = !sel.size;
      exportSel.lastChild.textContent = sel.size ? `Export ${count(sel.size)} Selected…` : 'Export Selected…';
      msg.textContent = sel.size ? `${plural(sel.size, 'item')} selected · ${bytes(selBytes())}` : 'Click to select. Shift-click for a range, Ctrl-click to add, Ctrl+A for all.';
    },
    onOpen: (r) => previewSheet(r),
    empty: () => [h('b', {}, 'Nothing here'), h('span', {}, q.search || q.filter !== 'all' ? 'No items match the search or filter.' : 'This album is empty.')],
  });
  table.sort = 'date';
  table.drawHead();
  const load = async (keep) => {
    info = await api.call('album:rows', q);
    sub.textContent = `${plural(info.rows.length, 'item')} · ${bytes(info.bytes)}` + (info.videos ? ` · ${plural(info.videos, 'video')}` : '');
    exportAll.disabled = !info.rows.length;
    table.setRows(info.rows, keep);
  };
  const chips = FILTERS.map(([id, text]) => h('button', { class: 'chip' + (id === 'all' ? ' on' : ''), onclick: (e) => { q.filter = id; chips.forEach((c) => c.classList.remove('on')); e.target.classList.add('on'); load(); } }, text));
  let timer;
  const search = h('input', { class: 'search', placeholder: 'Search name, folder or date', oninput: () => { clearTimeout(timer); timer = setTimeout(() => { q.search = search.value; load(); }, 160); } });
  load();
  const [ic, color] = SMART_ICONS[selection] || ['album', '#49a7ff'];
  return viewBox(h('div', { class: 'head' }, h('div', { class: 'big', style: `background:${color}` }, icon(ic)), h('div', {}, h('h2', {}, meta.title), sub)),
    h('div', { class: 'toolbar' }, chips, search), table.el, h('div', { class: 'actionbar' }, msg, exportSel, exportAll));
}

async function previewSheet(r) {
  const img = h('div', { class: 'dim', style: 'text-align:center;padding:30px' }, 'Loading preview…');
  openModal(h('div', { class: 'sheet preview' }, img, h('h2', {}, r[1]), h('div', { class: 'dim' }, `${r[2]} · ${bytes(r[3])} · ${r[4]} · ${r[5]}`),
    h('div', { class: 'dim', style: 'margin-top:4px' }, `Original name: ${r[6]} · Folder: ${r[7]}`),
    h('div', { class: 'foot' }, h('button', { class: 'btn primary', onclick: closeModal }, 'Close'))));
  const p = await api.call('thumb', r[0]);
  if (p) img.replaceWith(h('img', { src: 'file:///' + p.replace(/\\/g, '/').replace(/^\//, '') }));
  else img.textContent = 'No preview is stored on the device for this item. Export it to see it.';
}

async function exportSheet(meta, query, ids, totalBytes, n) {
  const total = ids ? ids.length : n;
  const defaults = await api.call('defaults');
  let dest = `${defaults.pictures}${state.isWindows ? '\\' : '/'}${meta.title.replace(/[\\/:*?"<>|]/g, '-')}`;
  const destText = h('span', {}), spaceNote = h('div', {});
  const drivesRow = h('div', { class: 'drives' });
  const opt = { includeLiveVideo: false, useOriginalNames: false, subfolder: 'flat', skipExisting: true, setDates: true };
  const refresh = async () => {
    destText.textContent = '‎' + dest;
    const free = await api.call('space', dest);
    spaceNote.replaceChildren();
    if (free != null && totalBytes > 0 && free < totalBytes * 1.02) spaceNote.append(h('div', { class: 'note' }, `This disk has ${bytes(free)} free, but the copy needs ${bytes(totalBytes)}. Choose another place or select fewer items.`));
    else if (free != null) spaceNote.append(h('div', { class: 'dim', style: 'margin-top:6px;font-size:12.5px' }, `${bytes(free)} free on this disk.`));
    const d = drives.find((x) => dest.toLowerCase().startsWith(x.path.toLowerCase()));
    if (d && /^FAT/i.test(d.format)) spaceNote.append(h('div', { class: 'note' }, 'This drive uses the FAT32 format, which cannot hold a file larger than 4 GB. Big videos will fail to copy.'));
  };
  const drives = await api.call('drives');
  for (const d of drives) drivesRow.append(h('button', { class: 'chip', onclick: () => { dest = d.path + (d.path.endsWith('\\') || d.path.endsWith('/') ? '' : '/') + 'Phone Export'; refresh(); } }, `${d.name} · ${bytes(d.free)} free`));
  const check = (key, text) => h('label', {}, h('input', { type: 'checkbox', checked: opt[key], onchange: (e) => (opt[key] = e.target.checked) }), text);
  const more = h('div', { class: 'hidden' },
    check('includeLiveVideo', 'Include the short video of each Live Photo'), check('useOriginalNames', 'Use original file names when the device kept them'),
    check('skipExisting', 'Skip files already in this folder (same name and size)'), check('setDates', 'Set each file’s date to when it was taken'),
    h('label', {}, 'Folders: ', h('select', { onchange: (e) => (opt.subfolder = e.target.value) }, h('option', { value: 'flat' }, 'One folder'), h('option', { value: 'yearMonth' }, 'By month (2026-11)'), h('option', { value: 'iphoneFolder' }, 'By device folder (100APPLE)'))));
  openModal(h('div', { class: 'sheet' }, h('h2', {}, `Copy ${plural(total, 'item')}`), h('div', { class: 'dim' }, `${bytes(totalBytes)} to copy. Nothing is removed from your ${kindWord()}.`),
    h('div', { class: 'stepno' }, h('div', { class: 'num' }, 1), 'Where should they go?'),
    h('div', { class: 'dest' }, icon('folder'), destText, h('button', { class: 'btn', onclick: async () => { const p = await api.call('pick:folder', 'Choose where to copy'); if (p) { dest = p; refresh(); } } }, 'Choose…')),
    drivesRow, spaceNote,
    h('div', { class: 'stepno' }, h('div', { class: 'num' }, 2), 'Copy'),
    h('div', { class: 'dim' }, 'Files already there are recognised and skipped. Nothing is ever overwritten.'),
    h('button', { class: 'btn', style: 'margin-top:10px', onclick: () => more.classList.toggle('hidden') }, 'More options'), more,
    h('div', { class: 'foot' }, h('button', { class: 'btn', onclick: closeModal }, 'Cancel'),
      h('button', { class: 'btn primary', onclick: () => runExport(meta, query, ids, dest, opt) }, icon('down'), 'Copy'))));
  refresh();
}

let progressUI = null;
async function runExport(meta, query, ids, dest, options) {
  const bar = h('progress', { max: 1, value: 0 }), line = h('div', { class: 'dim', style: 'margin-top:10px' }, 'Starting…'), speed = h('div', { class: 'dim' });
  const stop = h('button', { class: 'btn', onclick: () => { stop.disabled = true; stop.textContent = 'Stopping…'; api.call('export:stop'); } }, 'Stop');
  progressUI = (p) => {
    bar.value = p.bytesTotal > 0 ? Math.min(1, p.bytesDone / p.bytesTotal) : (p.total ? (p.copied + p.skipped + p.failed) / p.total : 0);
    line.textContent = `${count(p.copied + p.skipped + p.failed)} of ${count(p.total)} · ${bytes(p.bytesDone)}` + (p.bytesTotal > 0 ? ` of ${bytes(p.bytesTotal)}` : '');
    speed.textContent = p.bytesPerSecond > 0 ? `${bytes(p.bytesPerSecond)}/s` + (p.bytesTotal > p.bytesDone ? ` · ${eta((p.bytesTotal - p.bytesDone) / p.bytesPerSecond)}` : '') : '';
  };
  openModal(h('div', { class: 'sheet' }, h('h2', {}, `Copying from ${state.details.name}`), h('div', { class: 'dim', style: 'margin-bottom:14px' }, `Keep the ${kindWord()} connected and unlocked.`), bar, line, speed, h('div', { class: 'foot' }, stop)));
  const s = await api.call('export:start', { query, ids, dest, options });
  progressUI = null;
  if (!s) return closeModal();
  const title = s.fatalError ? 'The copy could not start' : s.stalled ? `The ${kindWord()} stopped responding` : s.disconnected ? `The ${kindWord()} was disconnected` : s.cancelled ? 'Copy stopped'
    : s.failures.length ? 'Finished, with some items missing' : 'All done';
  const text = s.fatalError ? s.fatalError : s.stalled ? `Everything copied so far is safe. It usually means the ${kindWord()} locked itself: unlock it, then export to the same folder to continue.`
    : s.disconnected ? 'Everything copied so far is safe. Plug it back in and export to the same folder to continue.' : s.cancelled ? 'Everything copied so far is safe. Export to the same folder to continue where it stopped.'
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
  (async () => { apply(await api.call('files:open', appId)); if (pendingFolder) { const p = pendingFolder; pendingFolder = null; open(p); } })();
  return el;
}
let filesProgress = null;

// MARK: backups

let backupProgress = null, backupRunning = false;
function backupView() {
  const list = h('div', {}), folderText = h('span', {}), drivesRow = h('div', { class: 'drives' }), status = h('div', {});
  const bar = h('progress', { max: 1, value: 0, class: 'hidden' });
  const start = h('button', { class: 'btn primary', onclick: () => run(null) }, icon('clock'), 'Back Up Now');
  const stop = h('button', { class: 'btn hidden', onclick: () => { stop.disabled = true; api.call('backup:stop'); } }, 'Stop');
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
      h('div', { class: 'dest' }, icon('folder'), folderText, h('button', { class: 'btn', onclick: async () => { const p = await api.call('pick:folder', 'Choose a backup folder'); if (p) setFolder(p); } }, 'Choose…')), drivesRow),
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
      h('div', { style: 'flex:1;min-width:0;display:flex;flex-direction:column;border-top:1px solid var(--line)' }, h('div', { style: 'display:flex;align-items:center' }, rowSearch, shown), holder)),
    h('div', { class: 'actionbar' }, msg, kind === 'files' ? copyBtn : [groups.length > 1 ? h('button', { class: 'btn', onclick: () => save(true) }, 'Save All…') : null, h('button', { class: 'btn primary', onclick: () => save(false) }, icon('down'), 'Save This…')]));
    pick(groups[0]);
  };
  load(null);
  return viewBox(h('div', { class: 'head' }, h('div', { class: 'big', style: `background:${color}` }, icon(ic)), h('div', {}, h('h2', {}, title), source)), body);
}

// MARK: start

api.on('state', (s) => { state = s; drawSidebar(); drawMain(false); });
api.on('export:progress', (p) => progressUI && progressUI(p));
api.on('files:progress', (t) => filesProgress && filesProgress(t));
api.on('backup:progress', (p) => backupProgress && backupProgress(p));
(async () => {
  state = await api.call('state');
  drawSidebar(); drawMain(true);
  if (api.test.startsWith('select:')) {
    const want = api.test.slice(7);
    const wait = setInterval(() => { if (state.phase === 'ready') { clearInterval(wait); if (want.startsWith('export:')) { go('smart_hidden'); runExport({ title: 'Hidden' }, { album: 'smart_hidden', filter: 'all', search: '', sort: 'date', ascending: false }, null, want.slice(7), {}); } else if (want.startsWith('folder:')) { pendingFolder = want.slice(7); go('nav_files'); } else go(want); } }, 200);
  }
})();

})();
