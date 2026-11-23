'use strict';
// Inside a group, the timeline, and the copy dialog and summary.

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
  const opt = { includeLiveVideo: false, useOriginalNames: false, subfolder: 'flat', skipExisting: true, setDates: true,
    editedVersions: false, convertHEIC: false, folderPattern: '{year}/{month}', albumName: meta.title, namePattern: '', removeLocation: false, saveReport: true };
  const [drives, facts] = await Promise.all([api.call('drives'), api.call('export:facts', { query, ids })]);
  // A whole group (no selection, no filter or search) can be saved as a one-click hop.
  const whole = !ids && query.filter === 'all' && !query.search && !query.from && !query.minBytes;
  let saveHop = false, hopName = '', autoHop = false;
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
  const patternRow = h('div', { class: 'hidden pattern' },
    h('input', { class: 'search', style: 'margin:6px 0 4px;width:100%', value: opt.folderPattern, oninput: (e) => (opt.folderPattern = e.target.value) }),
    h('div', { class: 'dim', style: 'font-size:12px' }, 'Use {year} {month} {monthName} {day} {hour} {minute} {second} {album} {folder} {device} {kind}; “\\” or “/” makes a folder inside a folder.'));
  const nameExample = h('div', { class: 'dim', style: 'font-size:12px' }, 'Keep the device’s names, or use e.g. {year}-{month}-{day} {hour}.{minute}.{second} or {device} {name}.');
  const nameRow = h('label', { class: 'name-row' }, 'File names: ', h('input', { class: 'search', placeholder: `Keep the ${kindWord()}'s names`, style: 'flex:1;margin:0',
    oninput: (e) => { opt.namePattern = e.target.value; nameExample.textContent = opt.namePattern.trim() ? 'Same-second shots get (2), (3)… at the end.' : 'Keep the device’s names, or use e.g. {year}-{month}-{day} {hour}.{minute}.{second} or {device} {name}.'; } }));
  const autoRow = h('label', { class: 'hidden' }, h('input', { type: 'checkbox', onchange: (e) => (autoHop = e.target.checked) }), `Run it by itself whenever this ${kindWord()} is plugged in (copies only what’s new, then lets you know)`);
  const hopName_ = h('input', { class: 'search hidden', style: 'margin:6px 0 0;width:100%', oninput: (e) => (hopName = e.target.value) });
  const top = [
    facts.edited ? check('editedVersions', `Copy edited versions (${plural(facts.edited, 'item')} edited in Photos)`) : null,
    facts.cloud ? h('div', { class: 'note' }, `${plural(facts.cloud, 'item')} ${facts.cloud === 1 ? 'is' : 'are'} stored only in iCloud, not on the ${kindWord()}, so ${facts.cloud === 1 ? 'it' : 'they'} can't be copied over USB. Turn off “Optimise Storage” in the ${kindWord()}'s Photos settings to bring ${facts.cloud === 1 ? 'it' : 'them'} back first.`) : null,
    whole ? h('label', {}, h('input', { type: 'checkbox', onchange: (e) => { saveHop = e.target.checked; hopName_.classList.toggle('hidden', !saveHop); autoRow.classList.toggle('hidden', !saveHop);
      if (!hopName) { hopName = `${meta.title} → ${dest.split(/[\\/]/).filter(Boolean).pop()}`; hopName_.value = hopName; } } }), 'Save as a one-click hop (next time it copies only what’s new)') : null,
    hopName_, autoRow];
  const more = h('div', { class: 'hidden' },
    facts.heic ? check('convertHEIC', `Convert HEIC photos to JPEG (${plural(facts.heic, 'photo')})`) : null,
    check('includeLiveVideo', 'Include the short video of each Live Photo'), check('useOriginalNames', 'Use original file names when the device kept them'),
    check('skipExisting', 'Skip files already in this folder (same name and size)'), check('setDates', 'Set each file’s date to when it was taken'),
    check('removeLocation', 'Remove location from the copies (nothing is re-encoded)'), check('saveReport', 'Save a copy report (a list of what was and wasn’t copied, in “PortHop Reports”)'),
    nameRow, nameExample,
    h('label', {}, 'Folders: ', h('select', { onchange: (e) => { opt.subfolder = e.target.value; patternRow.classList.toggle('hidden', opt.subfolder !== 'custom'); } }, h('option', { value: 'flat' }, 'One folder'), h('option', { value: 'yearMonth' }, 'By month (2026-11)'), h('option', { value: 'iphoneFolder' }, 'By device folder (100APPLE)'), h('option', { value: 'custom' }, 'Custom pattern…'))), patternRow);
  openModal(h('div', { class: 'sheet' }, h('h2', {}, `Copy ${plural(total, 'item')} from ${meta.title}`), h('div', { class: 'dim' }, `${bytes(totalBytes)} to copy. Nothing is removed from your ${kindWord()}.`),
    h('div', { class: 'stepno' }, h('div', { class: 'num' }, 1), 'Where should they go?'),
    h('div', { class: 'dest-row' }, icon('folder'), destText, h('button', { class: 'btn', onclick: async () => { const p = await api.call('pick:folder', 'Choose where to copy'); if (p) { dest = p; refresh(); } } }, 'Choose…')),
    drivesRow, spaceNote,
    h('div', { class: 'stepno' }, h('div', { class: 'num' }, 2), 'Copy'),
    h('div', { class: 'dim' }, 'Files already there are recognised and skipped. Nothing is ever overwritten.'), ...top,
    h('button', { class: 'btn', style: 'margin-top:10px', onclick: () => more.classList.toggle('hidden') }, 'More options'), more,
    h('div', { class: 'foot' }, h('button', { class: 'btn', onclick: () => { pendingFlight = null; closeModal(); } }, 'Cancel'),
      h('button', { class: 'btn primary', onclick: async () => {
        if (saveHop) await api.call('presets:save', { name: hopName || meta.title, albumID: query.album, dest, options: opt, auto: autoHop });
        runExport(meta, query, ids, dest, opt);
      } }, icon('arrow'), 'Copy'))));
  refresh();
}

/// Copies and shows the result. A quiet run (a hop that ran by itself) only opens the result when something went wrong.
async function runExport(meta, query, ids, dest, options, quiet = false) {
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
  if (!s) return null;
  if (quiet && !s.failures.length && !s.fatalError && !s.disconnected && !s.stalled) return s;
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
      s.reportPath ? h('button', { class: 'btn', onclick: () => api.call('reveal', s.reportPath) }, icon('file'), 'Copy Report') : null,
      h('button', { class: 'btn', onclick: () => api.call('reveal', s.destination) }, icon('folder'), 'Show Folder'), h('button', { class: 'btn primary', onclick: closeModal }, 'Done'))));
  return s;
}
