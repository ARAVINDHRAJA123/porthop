'use strict';
// Switching between screens.

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
