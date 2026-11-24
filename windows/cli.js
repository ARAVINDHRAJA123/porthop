'use strict';
// porthop: PortHop's engine from PowerShell or Command Prompt, for scripts and power users. The same rules as the app:
// nothing on the device is changed, nothing in the destination is overwritten, and running a copy again copies only
// what is new. porthop.cmd (next to PortHop.exe) runs this file with the app's own Electron in Node mode.
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const { locateTools, Job, bytes } = require('./core/shell');
const ios = require('./core/ios'), android = require('./core/android');
const { loadCatalog } = require('./core/catalog');
const { exportAssets, TOKENS } = require('./core/exporter');
const bk = require('./core/backup');
const spyware = require('./core/spyware'), apps = require('./core/apps'), music = require('./core/music');
const version = require('./package.json').version;

const args = process.argv.slice(2);
const flag = (n) => { const i = args.indexOf(n); if (i < 0) return false; args.splice(i, 1); return true; };
const option = (n) => { const i = args.indexOf(n); if (i < 0 || i + 1 >= args.length) return null; const v = args[i + 1]; args.splice(i, 2); return v; };
const fail = (s, code = 2) => { process.stderr.write(s + '\n'); process.exit(code); };
const emit = (v) => console.log(JSON.stringify(v, null, 2));
const usage = `porthop ${version}: copy photos and videos off an iPhone or iPad, from a terminal.

  porthop devices                    the connected devices
  porthop groups                     the photo groups on the device: Library, Hidden, Favorites, albums, people…
  porthop copy <group> <folder>      copy a group (its id or name); running it again copies only what is new
      --pattern "{year}/{month}"     folders inside <folder>
      --names "{year}-{month}-{day} {hour}.{minute}.{second}"   rename the copies
      --heic-to-jpeg  --edited  --live  --original-names  --no-location  --no-report  --no-dates
  porthop backup <folder>            a full backup in the same format as Apple's
  porthop music <folder>             copy the iPhone's songs and ringtones (Artist/Album/01 Title)
  porthop apps                       the apps installed on the iPhone, iPad or Android phone
  porthop indicators [file.stix2]    download the public spyware indicators (or add a file someone sent you)
  porthop check <backup folder>      check an iPhone backup for known spyware (exit code 1 when something matches)
  porthop check                      check a connected Android phone for known spyware and stalkerware
      --password <password>          for an encrypted backup

  Pattern tokens: ${TOKENS}
  Options: --device <id> picks a device when several are connected; --json prints machine-readable results.`;

(async () => {
  const json = flag('--json'), wanted = option('--device');
  const command = args.shift();
  if (!command || ['-h', '--help', 'help'].includes(command)) { console.log(usage); return; }
  if (command === 'version' || command === '--version') { console.log(`porthop ${version}`); return; }
  // Prints a spyware check and exits: 0 when nothing matched, 1 when something did.
  const report = (r) => {
    if (json) {
      emit({ matches: r.findings.map((f) => ({ area: f.area, found: f.found, spyware: f.indicator.malware, source: f.indicator.source, when: f.when })),
        checked: r.checked, notAvailable: r.missing, indicators: r.indicatorCount, warnings: r.warnings, review: r.review.map((g) => ({ title: g.title, apps: g.apps })) });
    } else {
      console.log(r.findings.length ? `${r.findings.length} match(es) with known spyware:` : `No known spyware found (checked against ${r.indicatorCount} indicators).`);
      for (const f of r.findings) console.log(`  ${f.area}: ${f.found}  [${f.indicator.malware}, ${f.indicator.source}]${f.when ? '  ' + f.when : ''}`);
      for (const w of r.warnings) console.log(`Warning: ${w}`);
      for (const g of r.review) console.log(`${g.title}: ${g.apps.join(', ')}`);
      if (r.findings.length) console.log('A match can be a false alarm, but get expert help: securitylab.amnesty.org, accessnow.org/help');
    }
    process.exit(r.findings.length ? 1 : 0);
  };
  const indicators = () => { const set = spyware.load(); if (set.isEmpty) fail('No spyware indicators yet. Run: porthop indicators', 3); return set; };
  if (command === 'indicators') {
    if (args[0]) { const problem = spyware.addFile(path.resolve(args[0])); if (problem) fail(problem); }
    else {
      const problem = await spyware.download();
      if (problem && spyware.load().isEmpty) fail(problem, 1);
      if (problem) process.stderr.write(problem + '\n');
    }
    const n = spyware.load().count, sources = spyware.sources().length;
    if (json) emit({ indicators: n, sources }); else console.log(`${n} indicators from ${sources} source${sources === 1 ? '' : 's'}.`);
    return;
  }
  const password = option('--password');
  if (command === 'check' && args[0]) {
    const set = indicators();
    const o = await bk.BackupReader.open(path.resolve(args[0]), password);
    if (o.needsPassword) fail('This backup is encrypted: add --password <its password>.');
    if (o.wrongPassword) fail("That password didn't open the backup.");
    if (!o.reader) fail("That folder isn't a readable backup (it should hold Manifest.db).", 3);
    let r;
    try { r = await spyware.scanBackup(o.reader, set); } finally { o.reader.close(); }
    report(r);
  }
  const tools = locateTools(path.join(path.dirname(process.execPath), 'resources'), true);
  if (!tools.hasApple && !tools.adb) fail('The device tools were not found. Run porthop.cmd from the PortHop folder.');
  const found = [...await ios.findDevices(tools), ...await android.findDevices(tools)];
  if (command === 'devices') {
    const list = [];
    for (const d of found) {
      const info = d.kind === 'android' ? await android.details(d, tools) : await ios.details(d, tools);
      list.push({ id: d.udid, kind: d.kind === 'android' ? 'android' : 'ios', name: info ? info.name : (d.unauthorized ? '(not allowed yet)' : '(locked)'), wifi: !!d.isNetwork });
    }
    if (json) emit(list); else if (!list.length) console.log('No device. Plug one in, unlock it and tap Trust (or Allow on Android).');
    else for (const d of list) console.log(`${d.kind}\t${d.name}\t${d.id}`);
    return;
  }
  const androidToo = ['apps', 'check'].includes(command);
  const device = wanted ? found.find((d) => d.udid === wanted) : (found.find((d) => d.kind !== 'android') || (androidToo ? found[0] : null));
  if (!device) fail(wanted ? `No connected device has the id ${wanted}.` : 'No iPhone or iPad. Plug it in, unlock it and tap Trust.', 3);
  if (device.kind === 'android' && !androidToo) fail('Android phones are copied from the app for now; the command line copies from iPhones and iPads.');
  if (command === 'check') {
    if (device.kind !== 'android') fail('Give the backup folder to check: porthop check <backup folder>. Make one with: porthop backup <folder>');
    report(await spyware.scanAndroid(device, tools, indicators()));
  }
  if (command === 'apps') {
    const list = await apps.list(device, tools);
    if (!list) fail('The app list could not be read. Unlock the device.', 3);
    if (json) emit(list.map((a) => ({ id: a.id, name: a.name, version: a.version, bytes: a.bytes })));
    else for (const a of list) console.log(`${a.id}\t${a.name}\t${a.version}`);
    return;
  }
  if (command === 'music') {
    if (!args[0]) fail('Usage: porthop music <folder>');
    const lib = await music.load(device, tools);
    if (lib.problem) fail(lib.problem, 3);
    const o = await music.copy(lib.songs, path.resolve(args[0]), device, tools, new Job(), (n, all, title) => { if (!json) process.stderr.write(`\r${n + 1}/${all} ${title}                    `); });
    const locked = lib.songs.filter((s) => !s.canCopy).length;
    if (json) emit({ copied: o.copied, skipped: o.skipped, failed: o.failed.length - locked, notCopyable: locked });
    else console.log(`\nCopied ${o.copied}, already there ${o.skipped}` + (locked ? `, ${locked} not copyable (Apple Music or only in the cloud)` : '') + (o.failed.length > locked ? `, ${o.failed.length - locked} failed.` : '.'));
    process.exit(o.failed.length > locked ? 1 : 0);
  }

  const catalog = async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'PortHop-cli-'));
    try {
      const db = await ios.fetchCatalog(device, tools, dir);
      if (!db) fail('The photo library could not be read. Unlock the device and tap Trust.', 3);
      let cat = loadCatalog(db);
      if (cat.error) { for (const f of [db + '-wal', db + '-shm']) fs.rmSync(f, { force: true }); cat = loadCatalog(db); }
      if (cat.error) fail('This version of iOS stores its photo library in a way PortHop can’t read yet.', 3);
      return cat;
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  };
  const total = (g) => g.assets.reduce((n, a) => n + Math.max(0, a.fileSize), 0);

  if (command === 'groups') {
    const cat = await catalog();
    const groups = [...cat.smart.filter((g) => g.assets.length || g.id === 'smart_hidden'), ...cat.user, ...(cat.people || [])];
    if (json) emit(groups.map((g) => ({ id: g.id, title: g.title, count: g.assets.length, bytes: total(g) })));
    else for (const g of groups) console.log(`${g.id}\t${g.title}\t${g.assets.length} items\t${bytes(total(g))}`);
    return;
  }
  if (command === 'copy') {
    if (args.length < 2) fail('Usage: porthop copy <group> <folder>   (see porthop help)');
    const options = { skipExisting: true, subfolder: 'flat', setDates: !flag('--no-dates'), convertHEIC: flag('--heic-to-jpeg'), editedVersions: flag('--edited'),
      includeLiveVideo: flag('--live'), useOriginalNames: flag('--original-names'), removeLocation: flag('--no-location'), saveReport: !flag('--no-report') };
    const pattern = option('--pattern'), names = option('--names');
    if (pattern) { options.subfolder = 'custom'; options.folderPattern = pattern; }
    if (names) options.namePattern = names;
    const [want, folder] = args;
    const cat = await catalog();
    const all = [...cat.smart, ...cat.user, ...(cat.people || [])];
    const group = all.find((g) => g.id === want) || all.find((g) => g.title.toLowerCase() === want.toLowerCase());
    if (!group) fail(`No group called “${want}”. See the list with: porthop groups`);
    options.albumName = group.title;
    const info = await ios.details(device, tools);
    options.deviceName = info ? info.name : 'iPhone';
    const job = new Job();
    process.on('SIGINT', () => { process.stderr.write('\nStopping…\n'); job.cancel(); });
    let last = 0;
    const s = await exportAssets({ assets: group.assets, dest: path.resolve(folder), options, device, tools, job, onProgress: (p) => {
      if (json || Date.now() - last < 500) return;
      last = Date.now();
      process.stderr.write(`\r${p.copied + p.skipped + p.failed}/${p.total} · ${bytes(p.bytesDone)} of ${bytes(p.bytesTotal)}${p.bytesPerSecond ? ` · ${bytes(p.bytesPerSecond)}/s` : ''}   `);
    } });
    if (!json) process.stderr.write('\n');
    const clean = !s.failures.length && !s.cancelled && !s.disconnected && !s.stalled && !s.fatalError;
    if (json) {
      emit({ copied: s.copied, skipped: s.skipped, failed: s.failures.map((f) => ({ file: f.filename, reason: f.reason })), notCopied: s.notAttempted, bytes: s.bytesCopied,
        report: s.reportPath || null, stopped: s.cancelled || s.disconnected || s.stalled, error: s.fatalError || null });
    } else {
      if (s.fatalError) fail(s.fatalError, 1);
      console.log(`Copied ${s.copied}, already there ${s.skipped}, couldn't copy ${s.failures.length}${s.notAttempted ? `, not copied ${s.notAttempted}` : ''} · ${bytes(s.bytesCopied)}`);
      for (const f of s.failures.slice(0, 10)) console.log(`  ${f.filename}: ${f.reason}`);
      if (s.failures.length > 10) console.log(`  …and ${s.failures.length - 10} more`);
      if (s.reportPath) console.log(`Report: ${s.reportPath}`);
    }
    process.exit(clean ? 0 : 1);
  }
  if (command === 'backup') {
    const folder = args[0];
    if (!folder) fail('Usage: porthop backup <folder>');
    process.stderr.write('Backing up… enter the passcode on the device if it asks.\n');
    const problem = await bk.runBackup(device, tools, path.resolve(folder), new Job(), (percent, phase) => { if (percent != null && !json) process.stderr.write(`\r${phase} ${Math.round(percent * 100)}%   `); });
    if (json) emit({ ok: !problem, error: problem || null }); else console.log(problem ? '\n' + problem : '\nBackup complete.');
    process.exit(problem ? 1 : 0);
  }
  fail(`Unknown command “${command}”.\n\n${usage}`);
})().catch((e) => fail(String(e && e.message ? e.message : e), 1));
