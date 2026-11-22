'use strict';
// Messages, WhatsApp, contacts and the rest, read out of a backup.

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
    h('div', { class: 'actionbar' }, msg, kind === 'files' ? copyBtn : [groups.length > 1 ? h('button', { class: 'btn', onclick: () => save(true) }, 'Save All…') : null,
      kind === 'messages' || kind === 'whatsapp' ? h('button', { class: 'btn', title: 'A page you can open in any browser, with the photos and files from this chat', onclick: async () => {
        const folder = await api.call('pick:folder', 'Choose where to save the page'); if (!folder) return;
        msg.textContent = 'Saving…';
        const r = await api.call('data:page', { id: current.id, folder });
        msg.textContent = !r || !r.page ? 'The page could not be written to that folder.' : r.attachments ? 'Saved, with its attachments that are in the backup.' : 'Saved.';
      } }, 'Save as Web Page…') : null, h('button', { class: 'btn primary', onclick: () => save(false) }, icon('down'), 'Save This…')]));
    pick(groups[0]);
  };
  load(null);
  return viewBox(h('div', { class: 'head' }, h('div', { class: 'big', style: `background:${color}` }, icon(ic)), h('div', {}, h('h2', {}, title), source)), body);
}
