'use strict';
// The phone tools: the phone's screen, apps, music and ringtones, the spyware check, sending a group to an Android phone,
// and removing copied files from an Android phone. The main-process side is tools-main.js.

/// Calls the main process; a failure there comes back as { error } instead of leaving the screen waiting.
const call = (name, arg) => api.call(name, arg).catch((e) => ({ error: String((e && e.message) || e).replace(/^Error invoking remote method '[^']+': (Error: )?/, '') }));

// MARK: on the device screen

function toolsCard() {
  const msg = h('span', { class: 'dim' });
  return h('div', { class: 'card wide' }, h('h3', {}, 'Phone tools'), h('div', { style: 'display:flex;gap:10px;flex-wrap:wrap;align-items:center' },
    isAndroid() ? h('button', { class: 'btn', onclick: () => go('nav_screen') }, icon('screen'), 'Screen') : null,
    h('button', { class: 'btn', onclick: () => go('nav_apps') }, icon('app'), 'Apps'),
    isAndroid() ? null : h('button', { class: 'btn', onclick: () => go('nav_music') }, icon('music'), 'Music & Ringtones'),
    h('button', { class: 'btn', onclick: () => go('nav_check') }, icon('shield'), 'Spyware Check'),
    h('button', { class: 'btn', onclick: async () => { const p = await call('report:phone'); msg.textContent = p && p.error ? p.error : p ? 'Report saved.' : ''; } }, icon('report'), 'Save Phone Report…'), msg));
}

// MARK: the phone's screen (Android over USB; an iPhone's screen needs a Mac)

function screenView() {
  const canvas = h('canvas', { class: 'screen-canvas' });
  const status = h('div', { class: 'screen-status' }, h('div', { class: 'spinner' }), h('div', {}, 'Waiting for the phone’s screen… unlock it if it is locked.'));
  const wrap = h('div', { class: 'screen-wrap' }, canvas, status);
  const note = h('div', { class: 'dim', style: 'min-height:20px' });
  const recordBtn = h('button', { class: 'btn primary', disabled: true }, icon('record'), 'Record');
  const shotBtn = h('button', { class: 'btn', disabled: true }, icon('camera'), 'Screenshot');
  const parser = new AnnexB();
  let decoder = null, codec = '', size = null, recorder = null, recordStart = 0, timer = null;
  const g = canvas.getContext('2d');
  const fit = () => {
    if (!size) return;
    const r = wrap.getBoundingClientRect(), scale = Math.min(r.width / size.w, r.height / size.h);
    if (!(scale > 0)) return;
    canvas.style.width = Math.floor(size.w * scale) + 'px';
    canvas.style.height = Math.floor(size.h * scale) + 'px';
  };
  const resize = new ResizeObserver(fit);
  resize.observe(wrap);
  const setLive = () => { status.classList.add('hidden'); recordBtn.disabled = false; shotBtn.disabled = false; };
  const configure = () => {
    if (decoder) { try { decoder.close(); } catch {} }
    codec = AnnexB.codec(parser.sps);
    decoder = new VideoDecoder({
      output: (frame) => {
        if (!size || size.w !== frame.displayWidth || size.h !== frame.displayHeight) {
          size = { w: frame.displayWidth, h: frame.displayHeight };
          canvas.width = size.w; canvas.height = size.h;
          fit();
          setLive();
        }
        g.drawImage(frame, 0, 0);
        frame.close();
      },
      error: () => { decoder = null; },
    });
    decoder.configure({ codec, optimizeForLatency: true });   // no description: the frames stay in Annex B form
  };
  let t = 0;
  const offData = api.on('screen:data', (chunk) => {
    for (const f of parser.append(new Uint8Array(chunk))) {
      if (f.isKey && (!decoder || decoder.state === 'closed' || AnnexB.codec(parser.sps) !== codec)) configure();
      if (!decoder || decoder.state !== 'configured') continue;
      if (decoder.decodeQueueSize > 8 && !f.isKey) continue;   // fall behind? skip to the next whole picture
      try { decoder.decode(new EncodedVideoChunk({ type: f.isKey ? 'key' : 'delta', timestamp: (t += 33333), data: f.data })); } catch {}
    }
  });
  const offEnd = api.on('screen:end', (why) => { status.classList.remove('hidden'); status.replaceChildren(h('div', {}, why)); recordBtn.disabled = true; shotBtn.disabled = true; });
  const stopRecording = () => new Promise((resolve) => {
    if (!recorder) return resolve();
    const r = recorder;
    recorder = null;
    clearInterval(timer);
    r.onstop = async () => {
      const blob = new Blob(r.chunks, { type: r.mimeType });
      const out = await call('screen:save', { data: await blob.arrayBuffer(), ext: r.mimeType.includes('mp4') ? 'mp4' : 'webm' });
      note.textContent = out && !out.error ? 'Recording saved in Videos › PortHop.' : (out && out.error) || 'The recording could not be saved.';
      recordBtn.replaceChildren(icon('record'), 'Record');
      resolve();
    };
    r.stop();
  });
  recordBtn.onclick = async () => {
    if (recorder) return stopRecording();
    const type = ['video/mp4;codecs=avc1.42E01E', 'video/webm;codecs=vp9', 'video/webm'].find((x) => MediaRecorder.isTypeSupported(x));
    const r = new MediaRecorder(canvas.captureStream(30), { mimeType: type, videoBitsPerSecond: 8e6 });
    r.chunks = [];
    r.ondataavailable = (e) => { if (e.data.size) r.chunks.push(e.data); };
    r.start(1000);
    recorder = r;
    recordStart = Date.now();
    api.call('screen:restart');   // the stream starts again with a whole picture
    const tick = () => { const s = Math.round((Date.now() - recordStart) / 1000); recordBtn.replaceChildren(icon('stop'), `Stop ${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`); };
    tick(); timer = setInterval(tick, 1000);
  };
  shotBtn.onclick = async () => { note.textContent = 'Taking a screenshot…'; const p = await call('screen:shot'); note.textContent = p && !p.error ? 'Screenshot saved in Pictures › PortHop.' : (p && p.error) || 'The phone did not send a screenshot.'; };
  // Click to tap, drag to swipe.
  let down = null;
  canvas.addEventListener('pointerdown', (e) => { down = { x: e.offsetX, y: e.offsetY }; });
  canvas.addEventListener('pointerup', (e) => {
    if (!down || !size) return;
    const w = canvas.clientWidth, hgt = canvas.clientHeight;
    const a = { x: down.x / w, y: down.y / hgt }, b = { x: e.offsetX / w, y: e.offsetY / hgt };
    if (Math.hypot(e.offsetX - down.x, e.offsetY - down.y) < 6) api.call('screen:tap', { x: a.x, y: a.y, w: size.w, h: size.h });
    else api.call('screen:swipe', { x1: a.x, y1: a.y, x2: b.x, y2: b.y, w: size.w, h: size.h });
    down = null;
  });
  const key = (code, ic, label) => h('button', { class: 'btn', title: label, 'aria-label': label, onclick: () => api.call('screen:key', code) }, icon(ic));
  const session = `${Date.now()}-${Math.random()}`;
  onLeave(async () => { resize.disconnect(); offData(); offEnd(); await stopRecording(); api.call('screen:stop', session); if (decoder) { try { decoder.close(); } catch {} } });
  api.call('screen:start', session).then((r) => {
    if (r && r.error) { status.replaceChildren(h('div', {}, r.error)); }
  });
  return viewBox(h('div', { class: 'pad screen-page' },
    h('div', { class: 'tool-head' }, h('div', {}, h('h1', {}, `${state.details.name} screen`),
      h('div', { class: 'dim' }, isAndroid() ? 'Live over USB. Click to tap, drag to swipe.' : '')),
    h('div', { class: 'tool-actions' }, isAndroid() ? [key(4, 'back', 'Back'), key(3, 'circle', 'Home'), key(187, 'square', 'Recent apps')] : null, shotBtn, recordBtn)),
    wrap, note));
}

// MARK: apps

function appsView() {
  let list = [], search = '';
  const rows = h('div', { class: 'tool-list' }, h('div', { class: 'dim', style: 'padding:14px' }, 'Reading the app list…'));
  const sub = h('div', { class: 'dim' }, 'Reading the app list…');
  const msg = h('div', { class: 'dim', style: 'min-height:20px' });
  const draw = () => {
    const q = search.trim().toLowerCase();
    const shown = q ? list.filter((a) => a.name.toLowerCase().includes(q) || a.id.toLowerCase().includes(q)) : list;
    rows.replaceChildren(...shown.map((a) => h('div', { class: 'tool-row' },
      h('span', { class: 'tile', style: `background:hsl(${[...a.id].reduce((n, c) => n + c.charCodeAt(0), 0) % 360} 55% 52%)` }, h('b', { style: 'color:#fff' }, a.name.slice(0, 1).toUpperCase())),
      h('div', { class: 'tool-main' }, h('b', {}, a.name), h('small', { class: 'dim' }, a.version ? `${a.id} · ${a.version}` : a.id)),
      a.bytes ? h('span', { class: 'dim' }, bytes(a.bytes)) : null,
      h('button', { class: 'btn', onclick: async () => {
        if (!await confirmBox(`Remove ${a.name}?`, `This deletes ${a.name} and everything it stores on ${state.details.name}. It can't be undone from PortHop.`, 'Remove App and Its Data', true)) return;
        msg.textContent = `Removing ${a.name}…`;
        const r = await call('apps:remove', a.id);
        if (r && !r.problem && !r.error) { list = list.filter((x) => x.id !== a.id); draw(); }
        msg.textContent = !r ? 'Another job is running.' : r.error || r.problem || `Removed ${a.name} and its data.`;
      } }, icon('trash'), 'Remove'))));
    sub.textContent = `${plural(list.length, 'app')} you installed`;
  };
  const load = async () => { const r = await call('apps:list'); list = Array.isArray(r) ? r : []; if (!Array.isArray(r)) msg.textContent = (r && r.error) || 'The app list could not be read. Unlock the phone and try again.'; draw(); };
  const offProgress = api.on('apps:progress', (p) => { msg.textContent = `Installing… ${p}%`; });
  onLeave(() => offProgress());
  load();
  return viewBox(h('div', { class: 'pad tool-page' },
    h('div', { class: 'tool-head' }, h('div', {}, h('h1', {}, `Apps on ${state.details.name}`), sub),
      h('div', { class: 'tool-actions' }, h('input', { class: 'search', placeholder: 'Search apps', oninput: (e) => { search = e.target.value; draw(); } }),
        h('button', { class: 'btn', title: 'Refresh', 'aria-label': 'Refresh', onclick: load }, icon('refresh')),
        h('button', { class: 'btn primary', onclick: async () => {
          msg.textContent = 'Choose the app file…';
          const r = await call('apps:install');
          if (!r) { msg.textContent = ''; return; }
          if (r.list) { list = r.list; draw(); }
          msg.textContent = r.error || r.problem || `Installed ${r.name}.`;
        } }, icon('install'), 'Install App…'))),
    msg, rows,
    h('div', { class: 'dim', style: 'font-size:12.5px' }, isAndroid() ? 'Installs .apk files. Removing an app deletes everything it stores on the phone.'
      : 'Installs .ipa files that are signed for this iPhone: your own builds, ad-hoc and company apps. App Store apps can’t be installed this way. Removing an app deletes everything it stores on the iPhone.')));
}

// MARK: music and ringtones (iPhone)

function musicView() {
  let songs = [], chosen = new Set(), search = '';
  const rows = h('div', { class: 'tool-list' }, h('div', { class: 'dim', style: 'padding:14px' }, 'Reading the music library…'));
  const sub = h('div', { class: 'dim' }, 'Reading the music library…');
  const msg = h('div', { class: 'dim', style: 'min-height:20px' });
  const time = (s) => (s > 0 ? `${Math.floor(s / 60)}:${String(Math.round(s % 60)).padStart(2, '0')}` : '');
  const draw = () => {
    const q = search.trim().toLowerCase();
    const shown = q ? songs.filter((s) => `${s.title} ${s.artist} ${s.album}`.toLowerCase().includes(q)) : songs;
    rows.replaceChildren(...shown.map((s) => h('label', { class: 'tool-row' },
      h('input', { type: 'checkbox', checked: chosen.has(s.id), onchange: (e) => { if (e.target.checked) chosen.add(s.id); else chosen.delete(s.id); } }),
      icon(s.isRingtone ? 'bell' : 'music'),
      h('div', { class: 'tool-main' }, h('b', {}, s.title), h('small', { class: 'dim' }, [s.albumArtist || s.artist, s.album].filter(Boolean).join(' · '))),
      h('span', { class: 'dim' }, !s.onPhone ? 'In the cloud' : s.isProtected ? 'Apple Music' : time(s.seconds)),
      h('span', { class: 'dim', style: 'width:70px;text-align:right' }, s.size ? bytes(s.size) : ''))));
    const tones = songs.filter((s) => s.isRingtone).length;
    sub.textContent = `${plural(songs.length - tones, 'song')} and videos · ${plural(tones, 'ringtone')} on ${state.details.name}`;
  };
  const ids = () => (chosen.size ? [...chosen] : null);
  const stop = h('button', { class: 'btn hidden', onclick: () => api.call('music:stop') }, 'Stop');
  const offProgress = api.on('music:progress', (t) => { msg.textContent = t; stop.classList.remove('hidden'); });
  onLeave(() => offProgress());
  const finish = (text) => { stop.classList.add('hidden'); msg.textContent = text; };
  call('music:list').then((r) => { songs = (r && r.songs) || []; msg.textContent = (r && (r.error || r.problem)) || ''; draw(); });
  const result = (o, to) => (!o ? '' : o.error ? o.error : `${o.cancelled ? 'Stopped. ' : ''}${to ? 'Sent' : 'Copied'} ${count(o.copied)}${o.skipped ? `, ${count(o.skipped)} already there` : ''}`
    + (o.failed.length ? `, ${count(o.failed.length)} couldn't be copied (protected by Apple Music, or only in the cloud)` : '') + (to ? ` to ${to}.` : '.'));
  return viewBox(h('div', { class: 'pad tool-page' },
    h('div', { class: 'tool-head' }, h('div', {}, h('h1', {}, 'Music & Ringtones'), sub),
      h('div', { class: 'tool-actions' }, h('input', { class: 'search', placeholder: 'Search', oninput: (e) => { search = e.target.value; draw(); } }),
        h('button', { class: 'btn', onclick: () => ringtoneSheet() }, icon('bell'), 'Make a Ringtone…'))),
    h('div', { class: 'tool-actions', style: 'justify-content:flex-start' },
      h('button', { class: 'btn primary', onclick: async () => { const o = await call('music:copy', { ids: null }); finish(result(o)); } }, icon('down'), 'Copy All to PC…'),
      h('button', { class: 'btn', onclick: async () => { if (!chosen.size) { msg.textContent = 'Tick the songs to copy first.'; return; } const o = await call('music:copy', { ids: ids() }); finish(result(o)); } }, 'Copy Ticked…'),
      state.peer ? h('button', { class: 'btn', onclick: async () => { const o = await call('music:send', { ids: ids() }); finish(o ? result(o, o.to) : ''); } }, icon('send'), `Send to ${state.peer.name}`) : null,
      stop),
    msg, rows,
    h('div', { class: 'dim', style: 'font-size:12.5px' }, 'Copies songs synced from a computer or bought in the iTunes Store, and ringtones. Apple Music downloads play only in the Music app, and songs not downloaded to the iPhone stay in the cloud; both are listed but not copied. Adding music to an iPhone needs Apple Devices or iTunes.')));
}

function ringtoneSheet() {
  let buffer = null, duration = 0, name = '';
  const note = h('div', { class: 'dim', style: 'min-height:20px' });
  const startIn = h('input', { type: 'range', min: 0, max: 0, step: 0.5, value: 0, style: 'width:100%' });
  const lenIn = h('input', { type: 'range', min: 5, max: 40, step: 1, value: 30, style: 'width:100%' });
  const startText = h('div', {}), lenText = h('div', {});
  const fmt = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
  const sync = () => { startText.textContent = `Starts at ${fmt(Number(startIn.value))} of ${fmt(duration)}`; lenText.textContent = `Lasts ${lenIn.value} seconds`; };
  startIn.oninput = sync; lenIn.oninput = sync;
  const toPhone = h('input', { type: 'checkbox', checked: true });
  const target = isAndroid() ? state.details.name : state.peer ? state.peer.name : null;
  const file = h('input', { type: 'file', accept: 'audio/*,video/*', onchange: async (e) => {
    const f = e.target.files[0];
    if (!f) return;
    name = f.name.replace(/\.[^.]+$/, '') + ' ringtone';
    buffer = await f.arrayBuffer();
    try {
      duration = (await new AudioContext().decodeAudioData(buffer.slice(0))).duration;
      startIn.max = Math.max(0, duration - 1); lenIn.max = Math.min(40, Math.max(5, Math.floor(duration)));
      note.textContent = '';
    } catch { buffer = null; note.textContent = 'This file can’t be played here (it may be protected by Apple Music).'; }
    sync();
  } });
  const save = h('button', { class: 'btn primary', onclick: async () => {
    if (!buffer) { note.textContent = 'Choose a song or sound file first.'; return; }
    save.disabled = true; note.textContent = 'Making the ringtone…';
    try {
      const bytesOut = await makeRingtoneBytes(buffer.slice(0), Number(startIn.value), Number(lenIn.value));
      const r = await api.call('music:saveTone', { data: bytesOut.buffer, name, toAndroid: !!target && toPhone.checked });
      if (r) {
        closeModal();
        lastCopyNote = r.sent ? 'Ringtone saved, and put on the Android phone: pick it in Settings › Sound › Ringtone.'
          : 'Ringtone saved. To put it on an iPhone, drag it onto the iPhone in Apple Devices (or iTunes › Tones), then pick it in Settings › Sounds & Haptics.';
        updateLive();
        return;
      }
      note.textContent = '';
    } catch { note.textContent = 'The ringtone could not be made from this file.'; }
    save.disabled = false;
  } }, 'Save Ringtone…');
  openModal(h('div', { class: 'sheet' }, h('h2', {}, 'Make a Ringtone'),
    h('div', { class: 'dim' }, 'Pick a song or sound file on this PC (songs from the iPhone can be copied over first). Ringtones are up to 40 seconds.'),
    file, startText, startIn, lenText, lenIn,
    target ? h('label', {}, toPhone, `Also put it on ${target}`) : null, note,
    h('div', { class: 'foot' }, h('button', { class: 'btn', onclick: closeModal }, 'Cancel'), save)));
  sync();
}

// MARK: spyware check

function spywareView() {
  const sourcesBox = h('div', {}), checkBox = h('div', {}), resultBox = h('div', {});
  const msg = h('span', { class: 'dim' });
  const pw = h('input', { class: 'search hidden', type: 'password', placeholder: 'Backup password', style: 'width:240px;margin:0' });
  const drawSources = (list) => {
    const total = list.reduce((n, s) => n + (s.count || 0), 0);
    const newest = list.map((s) => s.updated).filter(Boolean).sort().pop();
    sourcesBox.replaceChildren(list.length
      ? h('div', {}, h('div', { class: 'dim' }, `${count(total)} indicators from ${plural(list.length, 'investigation')}${newest ? `, updated ${new Date(newest).toLocaleDateString()}` : ''}`),
        h('div', { class: 'chips', style: 'margin-top:8px' }, list.map((s) => h('span', { class: 'chip' }, s.name.replace(' Indicators of Compromise', '')))))
      : h('div', { class: 'dim' }, 'None yet. Download the public list (about 2 MB from GitHub), or add a file an investigator sent you.'));
  };
  const drawCheck = async () => {
    if (isAndroid()) { checkBox.replaceChildren(h('div', { class: 'dim' }, 'Reads the installed apps, the programs running now, and which apps have powerful access.')); return; }
    const got = await call('spy:backup'), b = got && !got.error ? got : null;
    checkBox.replaceChildren(b ? h('div', { class: 'dim' }, `Reads the backup made ${new Date(b.date).toLocaleString()}${b.encrypted ? ' (encrypted)' : ''}. For the most complete check, make an encrypted backup first: it includes more.`)
      : h('div', { class: 'dim' }, `There is no backup of ${state.details.name} yet. The check reads a backup, so make one first. `, h('a', { href: '#', onclick: (e) => { e.preventDefault(); go('nav_backup'); } }, 'Go to Backups')));
  };
  const show = (r) => {
    const rep = r.report;
    resultBox.replaceChildren(h('div', { class: 'card wide spy-result' },
      h('div', { class: 'tool-head' }, h('div', { style: 'display:flex;gap:12px;align-items:center' },
        h('span', { class: 'spy-ic ' + (rep.findings.length ? 'bad' : 'ok') }, icon(rep.findings.length ? 'warn' : 'shield')),
        h('div', {}, h('h2', { style: 'margin:0' }, rep.findings.length ? `${rep.findings.length} match${rep.findings.length === 1 ? '' : 'es'} with known spyware` : 'No known spyware found'),
          h('div', { class: 'dim' }, rep.findings.length ? 'A match can be a false alarm, but take it seriously and get expert help.'
            : `Checked against ${count(rep.indicatorCount)} indicators. This finds only spyware that has been publicly documented.`))),
      h('button', { class: 'btn', onclick: () => api.call('spy:save') }, icon('down'), 'Save Report…')),
      rep.findings.map((f) => h('div', { class: 'spy-row' }, icon('warn'), h('div', {}, h('b', {}, f.found),
        h('small', { class: 'dim' }, `${f.area} · linked to ${f.indicator.malware} (${f.indicator.source})${f.when ? ' · ' + f.when : ''}`)))),
      rep.findings.length ? h('div', { style: 'display:flex;gap:14px;margin-top:8px' },
        h('a', { href: '#', onclick: (e) => { e.preventDefault(); api.call('open:link', 'https://securitylab.amnesty.org/get-help/'); } }, 'Amnesty Security Lab'),
        h('a', { href: '#', onclick: (e) => { e.preventDefault(); api.call('open:link', 'https://www.accessnow.org/help/'); } }, 'Access Now Helpline')) : null,
      rep.warnings.map((w) => h('div', { class: 'note' }, w)),
      rep.review.map((g) => h('div', { style: 'margin-top:10px' }, h('b', {}, g.title), h('div', { class: 'dim' }, g.detail + ' Check you recognise each one.'),
        h('div', { style: 'font-family:Consolas,monospace;font-size:12.5px;margin-top:4px' }, g.apps.join(', ')))),
      h('div', { class: 'dim', style: 'font-size:12.5px;margin-top:10px' }, `Checked: ${rep.checked.join(', ')}.` + (rep.missing.length ? ` Not available: ${rep.missing.join(', ')}.` : ''))));
  };
  const run = async (password) => {
    msg.textContent = isAndroid() ? `Checking ${state.details.name}…` : 'Reading the backup…';
    const r = await call('spy:check', { password });
    if (r && r.error) { msg.textContent = r.error; return; }
    pw.classList.toggle('hidden', !(r && r.needsPassword));
    msg.textContent = r && r.report ? '' : (r && r.message) || '';
    if (r && r.report) show(r);
  };
  api.call('spy:sources').then(drawSources);
  drawCheck();
  pw.addEventListener('keydown', (e) => { if (e.key === 'Enter' && pw.value) run(pw.value); });
  return viewBox(h('div', { class: 'scroll' }, h('div', { class: 'pad', style: 'max-width:940px' },
    h('h1', {}, 'Spyware check'),
    h('div', { class: 'dim', style: 'max-width:760px' }, 'Looks for traces of known spyware: the websites, programs, accounts and apps that investigators at Amnesty International, Citizen Lab and others have published for Pegasus, Predator, stalkerware and more. '
      + (isAndroid() ? 'An Android phone is checked live over USB; nothing is installed or changed on it.' : 'An iPhone is checked through its newest backup, so nothing on the iPhone is touched.')),
    h('div', { class: 'cards' },
      h('div', { class: 'card wide' }, h('div', { class: 'tool-head' }, h('h3', { style: 'margin:0' }, 'Known spyware indicators'),
        h('div', { class: 'tool-actions' },
          h('button', { class: 'btn', onclick: async () => { const r = await call('spy:add'); if (r) { if (r.sources) drawSources(r.sources); msg.textContent = r.error || r.problem || 'Added.'; } } }, icon('plus'), 'Add File…'),
          h('button', { class: 'btn', onclick: async (e) => { const b = e.currentTarget; b.disabled = true; msg.textContent = 'Downloading the latest indicator files…';
            const r = await call('spy:download'); b.disabled = false; if (r.sources) drawSources(r.sources); msg.textContent = r.error || r.problem || 'Indicators updated.'; } }, icon('down'), 'Download Latest'))),
      sourcesBox, h('div', { class: 'dim', style: 'font-size:12.5px;margin-top:8px' }, 'From the Mobile Verification Toolkit project’s public index. Downloaded only when you ask; nothing about you or your phone is sent.')),
      h('div', { class: 'card wide' }, h('h3', {}, `Check ${state.details.name}`), checkBox,
        h('div', { style: 'display:flex;gap:10px;align-items:center;margin-top:10px;flex-wrap:wrap' }, pw,
          h('button', { class: 'btn primary', onclick: () => run(pw.value || null) }, icon('shield'), 'Check Now'), msg))),
    resultBox)));
}

// MARK: an iPhone group straight to the Android phone plugged in next to it

function androidTargetCard(piles) {
  const el = h('div', { class: 'dest android-dest', title: 'Photos and videos go into the phone’s DCIM › PortHop folder, where its Gallery shows them.' },
    h('span', { class: 'dest-ic' }, icon('phone')),
    h('div', { class: 'dest-text' }, h('b', {}, state.peer.name), h('small', { 'data-text': 'Android phone · drop a group here' }, 'Android phone · drop a group here')),
    h('span', { class: 'dest-arrow' }, icon('send')));
  el.addEventListener('dragover', (e) => { if (e.dataTransfer.types.includes('text/porthop-pile')) { e.preventDefault(); el.classList.add('targeted'); } });
  el.addEventListener('dragleave', () => el.classList.remove('targeted'));
  el.addEventListener('drop', (e) => {
    e.preventDefault(); el.classList.remove('targeted');
    const p = piles.find((x) => x.id === e.dataTransfer.getData('text/porthop-pile'));
    if (p && !p.path) androidSheet(p, el);
  });
  el.addEventListener('click', () => popover(el, [[null, `Send to ${state.peer.name}`], ...piles.filter((p) => !p.path).map((p) => [p.title, p.icon, () => androidSheet(p, el), p.count != null ? count(p.count) : null])]));
  return el;
}

function androidSheet(p, el) {
  if (live.export) return;
  const pileEl = document.querySelector(`.pile[data-pile="${CSS.escape(p.id)}"]`);
  const query = { album: p.id, filter: 'all', search: '', sort: 'date', ascending: false };
  const opt = { convertHEIC: true, includeLiveVideo: false, setDates: true, subfolder: 'flat', useOriginalNames: false, removeLocation: false };
  const check = (key, text) => h('label', {}, h('input', { type: 'checkbox', checked: opt[key], onchange: (e) => (opt[key] = e.target.checked) }), text);
  openModal(h('div', { class: 'sheet' }, h('h2', {}, `Send ${plural(p.count || 0, 'item')} from ${p.title} to ${state.peer.name}`),
    h('div', { class: 'dim' }, `Into DCIM › PortHop › ${p.title.replace(/[\\/:*?"<>|]/g, '-')} on the phone, where its Gallery and Google Photos find them. Nothing is removed from your ${kindWord()}.`),
    check('convertHEIC', 'Convert HEIC photos to JPEG (every Android phone can show JPEG)'), check('includeLiveVideo', 'Include the short video of each Live Photo'),
    check('removeLocation', 'Remove location from the copies'),
    h('div', { class: 'foot' }, h('button', { class: 'btn', onclick: closeModal }, 'Cancel'),
      h('button', { class: 'btn primary', onclick: async () => {
        closeModal();
        pendingFlight = pileEl && el ? [pileEl, el] : null;
        live.export = { copied: 0, skipped: 0, failed: 0, total: p.count || 0, bytesDone: 0, bytesTotal: 0, bytesPerSecond: 0 };
        live.destName = state.peer.name;
        updateLive(); launchFlight();
        let s;
        try { s = await call('hop:android', { query, ids: null, options: opt, albumName: p.title }); } finally { live.export = null; updateLive(); }
        if (!s) return;
        if (s.error) { lastCopyNote = s.error; updateLive(); return; }
        const stat = (v, label) => h('div', { class: 'stat' }, h('b', {}, count(v)), h('small', {}, label));
        openModal(h('div', { class: 'sheet' }, h('h2', {}, s.cancelled ? 'Stopped' : s.sendFailures.length || s.failures.length ? 'Sent, with problems' : 'Sent'),
          h('div', { class: 'dim' }, `To ${s.sentTo}.`),
          h('div', { class: 'stats' }, stat(s.sentCount, 'sent'), stat(s.sentAlready, 'already on the phone'), stat(s.failures.length + s.sendFailures.length, 'could not be sent')),
          s.failures.length ? h('div', { class: 'fails' }, s.failures.slice(0, 200).map((f) => h('div', {}, `${f.filename} — ${f.reason}`))) : null,
          h('div', { class: 'foot' }, h('button', { class: 'btn primary', onclick: closeModal }, 'Done'))));
      } }, icon('send'), 'Send'))));
}

// MARK: removing what was copied from an Android phone

function removeCopiedButton() {
  if (!isAndroid() || !state.androidCopied) return null;
  return h('button', { class: 'btn', title: 'Removes the copied files from the phone, only where the copy on this PC is complete', onclick: async (e) => {
    if (!await confirmBox(`Remove the copied files from ${state.details.name}?`, 'Each file is checked against its copy on this PC first; files whose copy is missing or incomplete stay on the phone. Removed files can’t be brought back by PortHop.', 'Remove from Phone', true)) return;
    e.currentTarget.disabled = true;
    const r = await call('android:removeCopied');
    lastCopyNote = r && r.error ? r.error : r ? `Removed ${plural(r.removed, 'file')} from the phone (only ones whose copy matched).` : 'Nothing was removed.';
    updateLive();
  } }, icon('trash'), 'Remove from Phone…');
}
