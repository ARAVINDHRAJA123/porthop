'use strict';
// The Ask PortHop panel under the search field.

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
