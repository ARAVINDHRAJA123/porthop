'use strict';
// Phase 7 engine checks against the simulated iPhone and Android phone, with the cases shared with the Mac app (../Tests/golden).
const fs = require('node:fs'), path = require('node:path');
const { execFileSync } = require('node:child_process');
const { Job, fileSize } = require('../core/shell');
const android = require('../core/android');
const bk = require('../core/backup');
const spyware = require('../core/spyware');
const music = require('../core/music');
const apps = require('../core/apps');
const cleanup = require('../core/cleanup');
const report = require('../core/report');
const updates = require('../core/updates');
const { exportAssets } = require('../core/exporter');
const { AnnexB } = require('../renderer/h264');

module.exports = async function phase7({ T, check, macTests, tools, dev, hidden, ad, droid }) {
  let failures = 0;
  const ok = (name, cond, detail = '') => { if (!cond) failures++; check(name, cond, detail); };
  const golden = path.join(macTests, 'golden');
  const read = (p) => JSON.parse(fs.readFileSync(path.join(golden, p), 'utf8'));
  const rows = (list) => new Set((list || []).map((r) => r.join('|')));
  const same = (a, b) => a.size === b.size && [...a].every((x) => b.has(x));
  process.env.FAKE_ANDROID = droid;
  process.env.FAKE_ANDROID_LOG = path.join(T, 'adb.log');

  // Spyware check: a backup with planted traces, a clean backup, and the Android phone.
  const x = read('spyware/expect.json');
  const set = new spyware.Indicators();
  for (const i of spyware.parseSTIX(fs.readFileSync(path.join(golden, 'spyware/indicators.stix2')), 'Test lab')) set.add(i);
  const index = spyware.parseIndex(fs.readFileSync(path.join(golden, 'spyware/index.yaml'), 'utf8')).map((s) => [s.name, s.url]);
  execFileSync(path.join(macTests, 'make_fake_backup.py'), [path.join(T, 'spybackup', '0000-SPY')], { env: { ...process.env, SPYWARE: '1' } });
  execFileSync(path.join(macTests, 'make_fake_backup.py'), [path.join(T, 'cleanbackup', '0000-TEST')]);
  let found = new Set(), html = '', clean = false;
  let o = await bk.BackupReader.open(path.join(T, 'spybackup', '0000-SPY'), null);
  if (o.reader) {
    const rep = await spyware.scanBackup(o.reader, set);
    found = new Set(rep.findings.map((f) => `${f.area}|${f.found}|${f.indicator.malware}`));
    html = spyware.html(rep, 'Test iPhone', 'from a backup');
    o.reader.close();
  }
  o = await bk.BackupReader.open(path.join(T, 'cleanbackup', '0000-TEST'), null);
  if (o.reader) { clean = (await spyware.scanBackup(o.reader, set)).findings.length === 0; o.reader.close(); }
  process.env.PORTHOP_INDICATORS_DIR = path.join(T, 'indicators');
  const added = spyware.addFile(path.join(golden, 'spyware/indicators.stix2')) === null && spyware.load().count === 17
    && spyware.addFile(path.join(golden, 'spyware/expect.json')) !== null;
  ok('spyware check of an iPhone backup (shared cases)', set.count === x.indicators && JSON.stringify(index) === JSON.stringify(x.index) && same(found, rows(x.backup))
    && clean && added && html.includes('14 matches') && html.includes('securitylab.amnesty.org'),
  JSON.stringify({ count: set.count, missing: [...rows(x.backup)].filter((r) => !found.has(r)), extra: [...found].filter((r) => !rows(x.backup).has(r)) }));
  const a = await spyware.scanAndroid(ad, tools, set);
  const review = Object.fromEntries(a.review.map((g) => [g.title, g.apps]));
  ok('spyware check of an Android phone: apps, programs, special access', same(new Set(a.findings.map((f) => `${f.area}|${f.found}|${f.indicator.malware}`)), rows(x.android))
    && JSON.stringify(review) === JSON.stringify(x.androidReview) && a.warnings.length === x.androidWarnings, JSON.stringify(a));

  // The phone screen: the stream split into frames in odd-sized pieces, as it arrives.
  const sx = read('screen/expect.json');
  const stream = fs.readFileSync(path.join(golden, 'screen', sx.file));
  const p = new AnnexB();
  const frames = [];
  for (let i = 0; i < stream.length; i += sx.chunk) frames.push(...p.append(stream.subarray(i, i + sx.chunk)));
  frames.push(...p.finish());
  ok('phone screen: stream split into whole frames (shared case)', frames.length === sx.frames && frames.filter((f) => f.isKey).length === sx.keyFrames
    && AnnexB.codec(p.sps) === sx.codec && frames.every((f) => f.data[0] === 0 && f.data[3] === 1), `${frames.length} ${AnnexB.codec(p.sps)}`);

  // Music: the library read, copied by artist and album, sent to the Android phone.
  const want = read('music/expect.json').songs.map((s) => `${s.title}|${s.savedPath}|${s.canCopy}|${s.size}`);
  const lib = await music.load(dev, tools);
  const got = lib.songs.map((s) => `${s.title}|${s.savedPath}|${s.canCopy}|${s.size}`);
  const out = path.join(T, 'music-out'), job = new Job();
  const first = await music.copy(lib.songs, out, dev, tools, job), again = await music.copy(lib.songs, out, dev, tools, job);
  const sent = await music.send(lib.songs.filter((s) => s.title === 'Morning' || s.title === 'Old Phone'), dev, ad, tools, job);
  ok('music: library read, copied by artist and album, sent to Android (shared cases)', !lib.problem && JSON.stringify(got) === JSON.stringify(want)
    && first.copied === 5 && first.failed.length === 2 && again.skipped === 5 && again.copied === 0
    && fileSize(path.join(out, 'AC-DC', 'Live- Wire-', '2-07 Back in Black.m4a')) === 61000 && sent.copied === 2
    && fs.existsSync(path.join(droid, 'Music', 'Asha Band', 'First Light', '02 Morning.mp3')) && fs.existsSync(path.join(droid, 'Ringtones', 'Old Phone.m4r')),
  JSON.stringify({ got, first, again, sent }));

  // Apps on both kinds of phone, and the iPhone's Wi-Fi setting.
  const ios = (await apps.list(dev, tools)) || [];
  for (const f of ['My App.ipa', 'unsigned.ipa', 'app.apk', 'old.apk']) fs.writeFileSync(path.join(T, f), 'x');
  const percents = [];
  const i1 = await apps.install(path.join(T, 'My App.ipa'), dev, tools, (n) => percents.push(n)), i2 = await apps.install(path.join(T, 'unsigned.ipa'), dev, tools);
  const u1 = await apps.uninstall('com.example.player', dev, tools), u2 = await apps.uninstall('com.example.reader', dev, tools);
  const droidApps = (await apps.list(ad, tools)) || [];
  const a1 = await apps.install(path.join(T, 'app.apk'), ad, tools), a2 = await apps.install(path.join(T, 'old.apk'), ad, tools), a3 = await apps.install(path.join(T, 'My App.ipa'), ad, tools);
  const a4 = await apps.uninstall('com.fake.stalker2', ad, tools), a5 = await apps.uninstall('com.android.chrome', ad, tools);
  const w0 = await apps.wifiSync(dev, tools), w1 = await apps.wifiSync(dev, tools, true), w2 = await apps.wifiSync(dev, tools);
  ok('apps: list, install and remove on iPhone and Android; Wi-Fi backup setting', ios.map((x) => x.name).join() === 'Book Reader,Movie Player,Tabs & Notes'
    && ios.find((x) => x.id === 'com.example.player').bytes === 1048576 && i1 === null && percents[percents.length - 1] === 100 && /not signed for this iPhone/.test(i2 || '')
    && u1 === null && /cannot be removed/.test(u2 || '') && droidApps.map((x) => x.id).join() === 'com.example.app,com.fake.stalker2' && droidApps[0].version === '1.2'
    && droidApps[0].bytes === 2020 && a1 === null && /newer version/.test(a2 || '') && /\.apk/.test(a3 || '') && a4 === null && /cannot be removed/.test(a5 || '')
    && w0 === false && w1 === true && w2 === true, JSON.stringify({ ios, i1, percents, i2, u1, u2, droidApps, a1, a2, a3, a4, a5, w0, w1, w2 }));

  // Removing copied items: the same matching rules as the Mac, and Android files removed only where the copy matches.
  const asset = (id, directory, filename, fileSize, isLivePhoto = false) => ({ id, directory, filename, fileSize, isLivePhoto });
  const b1 = asset(1, 'DCIM/100APPLE', 'IMG_0001.HEIC', 1000), b2 = asset(2, 'DCIM/100APPLE', 'IMG_0002.JPG', 500), b3 = asset(3, 'DCIM/101APPLE', 'IMG_0003.HEIC', 800, true), b4 = asset(4, 'DCIM/100APPLE', 'IMG_0004.JPG', 700);
  const files = [{ folder: '100APPLE', name: 'IMG_0001.JPG', size: 640 }, { folder: '100APPLE', name: 'IMG_0002.JPG', size: 500 }, { folder: '101APPLE', name: 'IMG_0003.HEIC', size: 800 },
    { folder: '101APPLE', name: 'IMG_0003.MOV', size: 90 }, { folder: '100APPLE', name: 'IMG_0004.JPG', size: 699 }, { folder: '101APPLE', name: 'IMG_0002.JPG', size: 500 }];
  const pick1 = cleanup.deletable([b1, b2, b3, b4], files, true).map((f) => `${f.folder}/${f.name}`), pick2 = cleanup.deletable([b3], files, false).map((f) => `${f.folder}/${f.name}`);
  const pick3 = cleanup.deletable([asset(5, 'DCIM/102APPLE', 'IMG_0005.HEIC', 900)], [{ folder: '102APPLE', name: 'IMG_0005.HEIC', size: 900 }, { folder: '102APPLE', name: 'IMG_0005.JPG', size: 300 }], false).map((f) => f.name);
  fs.mkdirSync(path.join(droid, 'DCIM', 'Trip', 'sub'), { recursive: true });
  fs.writeFileSync(path.join(droid, 'DCIM', 'Trip', 'a.jpg'), Buffer.alloc(300)); fs.writeFileSync(path.join(droid, 'DCIM', 'Trip', 'sub', 'b.jpg'), Buffer.alloc(400));
  const trip = path.join(T, 'trip-copy');
  const pulled = await android.pull({ path: '/sdcard/DCIM/Trip', isDirectory: true }, trip, ad, tools);
  fs.writeFileSync(path.join(trip, 'sub', 'b.jpg'), Buffer.alloc(10));
  const sure = (await cleanup.androidConfirmed([{ remote: '/sdcard/DCIM/Trip', local: trip }], ad, tools)).map((e) => e.path);
  const gone = await android.remove(sure, ad, tools);
  ok('removing copied items: only confirmed copies, matched to the phone\'s own files', pick1.join() === '100APPLE/IMG_0001.JPG,100APPLE/IMG_0002.JPG,101APPLE/IMG_0003.HEIC,101APPLE/IMG_0003.MOV'
    && pick2.join() === '101APPLE/IMG_0003.HEIC' && pick3.join() === 'IMG_0005.HEIC' && pulled && sure.join() === '/sdcard/DCIM/Trip/a.jpg' && gone.join() === sure.join()
    && !fs.existsSync(path.join(droid, 'DCIM', 'Trip', 'a.jpg')) && fs.existsSync(path.join(droid, 'DCIM', 'Trip', 'sub', 'b.jpg')), JSON.stringify({ pick1, pick2, sure, gone }));

  // iPhone to Android: copied off the iPhone into a temporary folder, then sent to the phone's camera folder.
  const staging = path.join(T, 'hop-staging');
  const few = hidden.filter((a) => a.filename.startsWith('IMG_00') && !a.isVideo).slice(0, 5);
  const r = await exportAssets({ assets: few, dest: staging, options: { convertHEIC: true, saveReport: false }, device: dev, tools, job: new Job() });
  const s1 = await android.sendFolder(staging, '/sdcard/DCIM/PortHop/Hidden', ad, tools, new Job()), s2 = await android.sendFolder(staging, '/sdcard/DCIM/PortHop/Hidden', ad, tools, new Job());
  const onPhone = fs.readdirSync(path.join(droid, 'DCIM', 'PortHop', 'Hidden')).filter((n) => !n.startsWith('.')).length;
  const scans = fs.readFileSync(path.join(T, 'adb.log'), 'utf8').split('scan /sdcard/DCIM/PortHop/Hidden/').length - 1;
  ok('iPhone to Android: copied off the iPhone, sent to the phone\'s camera folder, Gallery told', r.copied === 5 && s1.sent === 5 && s1.already === 0
    && s2.sent === 0 && s2.already === 5 && onPhone === 5 && scans === 5, JSON.stringify({ copied: r.copied, s1, s2, onPhone, scans }));

  // The phone report and signed update downloads.
  const page = report.phoneReport({ name: "Asha's iPhone", info: [['Model', 'iPhone17,1'], ['IMEI', '35 000000 000000 0']], health: 91, cycles: 312,
    totalBytes: 256e9, freeBytes: 56e9, battery: null }, false);
  const key = Buffer.from(fs.readFileSync(path.join(golden, 'update/test-key.pub'), 'utf8').trim(), 'base64');
  const sample = fs.readFileSync(path.join(golden, 'update/sample.bin')), sig = fs.readFileSync(path.join(golden, 'update/sample.bin.sig'), 'utf8');
  const tampered = Buffer.from(sample); tampered[10] ^= 1;
  const other = require('node:crypto').generateKeyPairSync('ed25519').publicKey.export({ format: 'der', type: 'spki' }).subarray(12);
  const rel = { version: '9.9.9', assets: { 'PortHop-9.9.9-windows.zip': 'https://x/a.zip', 'PortHop-9.9.9-windows.zip.sig': 'https://x/a.zip.sig', 'PortHop-9.9.9-setup.exe': 'https://x/s.exe' } };
  const picked = updates.windowsAssets(rel);
  ok('phone report; signed update downloads (shared case)', page.includes('91% of its original capacity') && page.includes('<td>312</td>') && !page.includes('35 000000')
    && page.includes('Parts and Service History') && updates.verify(sample, sig, key) && !updates.verify(tampered, sig, key) && !updates.verify(sample, sig, other)
    && !updates.verify(sample, 'junk', key) && picked.zip && picked.zip.name === 'PortHop-9.9.9-windows.zip' && picked.setup === null);

  // The command line's new commands.
  const cli = (...a) => { try { return { code: 0, out: execFileSync(process.execPath, [path.join(__dirname, '..', 'cli.js'), ...a], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }) }; } catch (e) { return { code: e.status, out: String(e.stdout || '') }; } };
  const k1 = cli('indicators', path.join(golden, 'spyware/indicators.stix2')), k2 = cli('check', path.join(T, 'spybackup', '0000-SPY'), '--json');
  const k3 = cli('check', path.join(T, 'cleanbackup', '0000-TEST')), k4 = cli('check', '--device', 'FAKEANDROID01', '--json');
  const k5 = cli('music', path.join(T, 'cli-music'), '--json'), k6 = cli('apps');
  ok('porthop command line: indicators, check, music, apps', k1.out.includes('17 indicators from 1 source') && k2.code === 1 && k2.out.includes('"spyware": "StalkTest"')
    && k3.code === 0 && k4.code === 1 && k4.out.includes('"found": "droidspyd"') && k5.code === 0 && k5.out.includes('"copied": 5') && k6.out.includes('com.example.notes\tTabs & Notes'),
  JSON.stringify([k1, k2.code, k3, k4.code, k5, k6]));
  return failures;
};
