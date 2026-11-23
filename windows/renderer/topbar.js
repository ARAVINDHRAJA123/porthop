'use strict';
// The top bar: device button, settings menu, and the lists the screens share.

// MARK: top bar

const SMART_ICONS = { smart_hidden: ['eye', '#7369ff'], smart_all: ['photo', '#3d8bff'], smart_favorites: ['heart', '#ff6b94'], smart_videos: ['video', '#9e73ff'],
  smart_live: ['live', '#ffa842'], smart_screenshots: ['shot', '#38c7d6'], smart_selfies: ['selfie', '#4dcc85'], smart_trashed: ['trash', '#808ca3'] };
const DATA_KINDS = [['messages', 'Messages', 'msg', '#3ecf74'], ['whatsapp', 'WhatsApp', 'chats', '#2bbf9d'], ['contacts', 'Contacts', 'person', '#8a8894'], ['notes', 'Notes', 'note', '#e0b000'],
  ['calendar', 'Calendar', 'cal', '#ff5d5d'], ['calls', 'Call Log', 'call', '#33a9c9'], ['safari', 'Safari', 'globe', '#3b8cff'],
  ['photos', 'Photos & Videos', 'photo', '#ff6fa8'], ['voiceMemos', 'Voice Memos', 'mic', '#6d6dff'], ['files', 'Backup Files', 'box', '#a8794f']];
const FILE_KINDS = ['files', 'photos', 'voiceMemos'];   // rows are files that can be copied out of the backup
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

async function checkUpdates() {
  const r = await api.call('update:check');
  if (r.version) return updateSheet(r);
  openModal(h('div', { class: 'sheet' }, h('h2', {}, r.error ? 'Couldn’t check for updates' : `PortHop ${r.current} is the latest version`),
    h('p', { class: 'dim' }, r.error ? r.error : 'There is nothing to update.'), h('div', { class: 'foot' }, h('button', { class: 'btn primary', onclick: closeModal }, 'OK'))));
}
function updateSheet(u) {
  openModal(h('div', { class: 'sheet' }, h('h2', {}, `PortHop ${u.version} is available`),
    h('p', { class: 'dim', style: 'white-space:pre-wrap;max-height:240px;overflow:auto' }, (u.notes || '').slice(0, 900) || 'A newer version is on GitHub.'),
    h('div', { class: 'foot' }, h('button', { class: 'btn', onclick: closeModal }, 'Later'),
      h('button', { class: 'btn primary', onclick: () => { closeModal(); api.call('update:open'); } }, icon('down'), 'Download'))));
}

function drawTopBar() {
  const s = state, ready = s.phase === 'ready';
  const back = ready && selection !== 'nav_home' ? h('button', { class: 'tb-btn', title: 'Back to Shores', onclick: () => go('nav_home') }, icon('back')) : null;
  const pill = h('div', { class: 'splitbtn' },
    h('button', { class: 'split-main', disabled: !ready, title: 'Battery and device details', onclick: () => go('nav_device') },
      h('i', { class: 'dot' + (ready ? '' : ' off') }), ready ? s.details.name : 'No device'),
    h('button', { class: 'split-menu', disabled: !ready, title: 'Devices, backups and more', onclick: (e) => { e.currentTarget.classList.add('open'); devicePopover(e.currentTarget); } }, icon('chev')));
  const askWrap = h('div', { class: 'ask' + (ready ? '' : ' off') }, icon('search'), askInput, h('kbd', {}, 'Ctrl K'));
  const settingsBtn = h('button', { class: 'tb-btn', title: 'Settings and licences', onclick: async (e) => {
    const target = e.currentTarget, now = await api.call('appearance'), wifi = await api.call('wifi'), autoUpdate = await api.call('update:auto');
    const mode = (v, label, ic) => [label, now === v ? 'check' : ic, () => api.call('appearance', v)];
    popover(target, [mode('system', 'Match Windows', 'contrast'), mode('light', 'Light', 'sun'), mode('dark', 'Dark', 'moon'),
      [wifi ? 'Stop finding phones on Wi-Fi' : 'Also find phones on Wi-Fi (slower)', wifi ? 'check' : 'globe', () => api.call('wifi', !wifi)],
      ['Check for updates…', 'update', checkUpdates], [autoUpdate ? 'Checking for updates weekly' : 'Check for updates weekly', autoUpdate ? 'check' : 'clock', () => api.call('update:auto', !autoUpdate)],
      ['Open-source licences', 'file', () => api.call('licences')], ['PortHop on GitHub', 'globe', () => api.call('github')]]);
  } }, icon('dots'));
  // A newer release on GitHub shows as a small button.
  const updateBtn = s.update ? h('button', { class: 'chip update-chip', title: 'A newer PortHop is available', onclick: () => updateSheet(s.update) }, icon('update'), `Update to ${s.update.version}`) : null;
  $('#topbar').replaceChildren(h('div', { class: 'tb-left' }, back, pill), askWrap, h('div', { class: 'tb-right' }, updateBtn, badge, settingsBtn));
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
