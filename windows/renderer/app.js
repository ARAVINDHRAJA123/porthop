'use strict';
// Start-up and error reporting.

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
    const wait = setInterval(() => { if (state.phase === 'ready') { clearInterval(wait); if (want.startsWith('ask:')) { askInput.value = want.slice(4); askInput.focus(); askPanel.classList.remove('hidden'); api.call('destinations').then((d) => { destCache = d; drawAskPanel(); }); } else if (want.startsWith('hop:')) { const [al, ...rest] = want.slice(4).split(':'); const dest = rest.join(':'); api.call('destinations').then((d) => { destCache = d; go('nav_home'); setTimeout(() => runExport({ title: al }, { album: al, filter: 'all', search: '', sort: 'date', ascending: false }, null, dest, {}), 800); }); } else if (want.startsWith('sheet:')) { const [al, ...rest] = want.slice(6).split(':'); const p = rest.join(':'); go('nav_home'); setTimeout(() => exportSheet({ title: 'Hidden' }, { album: al, filter: 'all', search: '', sort: 'date', ascending: false }, null, 6.7e6, 39, p), 800); } else if (want.startsWith('export:')) { go('smart_hidden'); runExport({ title: 'Hidden' }, { album: 'smart_hidden', filter: 'all', search: '', sort: 'date', ascending: false }, null, want.slice(7), {}); } else if (want.startsWith('folder:')) { pendingFolder = want.slice(7); go('nav_files'); } else go(want); } }, 200);
  }
})();
