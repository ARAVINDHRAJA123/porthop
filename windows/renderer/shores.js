'use strict';
// Shores, the home screen: groups on the left, places on the right, the channel between.

// MARK: shores

function shoresView() {
  const s = state;
  const piles = isAndroid()
    ? ANDROID_FOLDERS.map(([title, ic, p]) => ({ id: 'android:' + p, title, icon: ic, color: '#5a8cff', path: p }))
    : SMART_ORDER.map((id) => s.smart.find((a) => a.id === id)).filter((a) => a && (a.count || a.id === 'smart_hidden'))
      .map((a) => ({ id: a.id, title: a.title, icon: SMART_ICONS[a.id][0], color: SMART_ICONS[a.id][1], count: a.count, bytes: a.bytes, thumbs: a.thumbs, blur: a.id === 'smart_hidden' }));
  const albums = isAndroid()
    ? (s.androidAlbums || []).map((a) => ({ id: 'android:' + a.path, title: a.name, icon: 'album', color: '#5aa2ff', count: a.count, bytes: a.bytes, path: a.path, compact: true }))
    : s.user.map((a) => ({ id: a.id, title: a.title, icon: 'album', color: '#5aa2ff', count: a.count, bytes: a.bytes, compact: true }));
  const people = isAndroid() ? [] : (s.people || []).map((a) => ({ id: a.id, title: a.title, icon: 'person', color: '#b07cff', count: a.count, bytes: a.bytes, compact: true }));
  const all = [...piles, ...albums, ...people];

  const left = h('div', { class: 'shore' },
    deviceHero(),
    h('div', { class: 'label' }, isAndroid() ? `Folders on your ${kindWord()}` : `On your ${kindWord()}`),
    h('div', { class: 'piles' }, piles.map(pileCard)),
    isAndroid() ? h('button', { class: 'btn', style: 'align-self:flex-start', onclick: () => go('nav_files') }, icon('folder'), 'Browse all storage') : null,
    albums.length ? [h('div', { class: 'label' }, 'Your albums'), h('div', { class: 'piles' }, albums.map(pileCard))] : null,
    people.length ? [h('div', { class: 'label' }, 'People'), h('div', { class: 'piles' }, people.map(pileCard))] : null,
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
    isAndroid() ? null : hopsBlock(),
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

/// Saved hops: one click copies whatever is new in that group to that folder.
function hopsBlock() {
  const box = h('div', { class: 'hops' });
  const draw = async () => {
    const list = await api.call('presets:list');
    box.replaceChildren(...(list.length ? [h('div', { class: 'label', style: 'margin-top:8px' }, 'Your hops'), ...list.map((p) => {
      const ready = p.onDevice && p.reachable;
      return h('div', { class: 'hop-row' },
        h('span', { class: 'tile big shape-cookie6' }, icon(p.auto ? 'bolt' : 'refresh')),
        h('div', { class: 'hop-text' }, h('b', {}, p.name),
          h('small', {}, !p.onDevice ? `Not on this ${kindWord()}` : !p.reachable ? 'Folder not connected' : `${count(p.count)} items · ${p.auto ? 'runs when plugged in' : "copies only what's new"}`)),
        h('button', { class: 'tb-btn' + (p.auto ? ' on' : ''), title: p.auto ? 'Runs by itself when this device is plugged in. Click to stop that.' : 'Run by itself whenever this device is plugged in',
          onclick: async () => { await api.call('presets:setAuto', { id: p.id, on: !p.auto }); draw(); } }, icon('bolt')),
        h('button', { class: 'tb-btn', title: 'Remove this hop', onclick: async () => { await api.call('presets:delete', p.id); draw(); } }, icon('trash')),
        h('button', { class: 'btn primary', disabled: !ready || !!live.export, title: 'Hop now', onclick: () =>
          runExport({ title: p.title }, { album: p.albumID, filter: 'all', search: '', sort: 'date', ascending: false }, null, p.dest, { ...p.options, skipExisting: true, albumName: p.title }) }, icon('arrow')));
    })] : []));
  };
  draw();
  return box;
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
