'use strict';
// Small helpers shared by every screen: element builder, icons, dialogs and the fast table.

/* Window logic. All device work happens in the main process; these files only draw and ask. */
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
