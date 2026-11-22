'use strict';
// Files on the device, and backups.

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
