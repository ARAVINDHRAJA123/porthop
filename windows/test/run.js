'use strict';
// Engine tests against simulated devices (shared with the Mac app's tests). No real device is touched.
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const { execFileSync } = require('node:child_process');
const macTests = path.join(__dirname, '..', '..', 'Tests');
const T = fs.mkdtempSync(path.join(os.tmpdir(), 'porthop-test-'));
process.env.PHONE_TOOLS_DIR = path.join(macTests, 'fake-tools');
process.env.FAKE_PHONE = path.join(T, 'phone');
execFileSync(path.join(macTests, 'make_fake_phone.sh'), [process.env.FAKE_PHONE], { stdio: 'ignore' });
const { locateTools, Job, fileSize } = require('../core/shell');
const ios = require('../core/ios'), android = require('../core/android');
const { loadCatalog, view } = require('../core/catalog');
const { exportAssets } = require('../core/exporter');
let failures = 0;
const check = (name, ok, detail = '') => { if (!ok) failures++; console.log(ok ? 'PASS' : 'FAIL', name, ok ? '' : detail); };
const s = (x) => JSON.stringify({ copied: x.copied, skipped: x.skipped, failed: x.failures.length, live: x.liveVideos, notStarted: x.notAttempted, stalled: x.stalled, disc: x.disconnected });

(async () => {
  const tools = locateTools(null);
  const dev = (await ios.findDevices(tools))[0];
  const info = await ios.details(dev, tools);
  check('device details', info && info.name && info.totalBytes > 0 && info.info.length >= 3, JSON.stringify(info));
  const dbPath = await ios.fetchCatalog(dev, tools, path.join(T, 'db'));
  const cat = loadCatalog(dbPath);
  const hidden = cat.smart[0].assets, ids = new Set(hidden.map((a) => a.id));
  check('catalog', hidden.length === 39 && cat.user.length === 2, `${hidden.length} ${cat.user.length}`);
  check('hidden items appear only in Hidden', ![...cat.smart.slice(1), ...cat.user].some((al) => al.id !== 'smart_trashed' && al.assets.some((a) => ids.has(a.id))));
  const bySize = view(hidden, { sort: 'size', ascending: false }), byName = view(hidden, { sort: 'name', ascending: true, filter: 'videos' });
  check('sort and filter', bySize[0].fileSize >= bySize[5].fileSize && byName.every((a) => a.isVideo) && view(hidden, { search: 'zzzz' }).length === 0);
  const go = (dest, options = {}, job = new Job(), extra = {}) => exportAssets({ assets: hidden, dest: path.join(T, dest), options, device: dev, tools, job, ...extra });
  let r = await go('out1'); check('first export', r.copied === 38 && r.skipped === 0 && r.failures.length === 1, s(r));
  r = await go('out1'); check('run again', r.copied === 0 && r.skipped === 38 && r.failures.length === 1, s(r));
  check('edited and iCloud-only flags', hidden.filter((a) => a.isEdited).map((a) => a.filename).sort().join() === 'IMG_0002.JPG,IMG_0003.JPG'
    && hidden.filter((a) => a.isCloudOnly).map((a) => a.filename).join() === 'IMG_9000.HEIC');
  r = await go('edited', { editedVersions: true });
  check('edited versions', r.copied === 38 && fs.readFileSync(path.join(T, 'edited', 'IMG_0002.jpg')).subarray(-6).toString() === 'EDITED'
    && fs.existsSync(path.join(T, 'edited', 'IMG_0003.JPG')), s(r));
  r = await go('pattern', { subfolder: 'custom', folderPattern: '{album}/{year}/{month} {monthName}', albumName: 'Hidden' });
  const years = fs.readdirSync(path.join(T, 'pattern', 'Hidden'));
  const months = fs.readdirSync(path.join(T, 'pattern', 'Hidden', years[0]));
  check('custom folder pattern', r.copied === 38 && years.every((y) => /^\d{4}$/.test(y)) && months.some((m) => /^\d\d [A-Z][a-z]+$/.test(m)), years.join() + ' ' + months.join());
  check('people named in Photos become groups', JSON.stringify(cat.people.map((p) => [p.title, p.assets.length])) === '[["Mum",4],["Ravi Kumar",3]]' && cat.people[0].id === 'person:mum',
    JSON.stringify(cat.people.map((p) => [p.title, p.assets.length])));
  r = await go('named', { namePattern: '{year}-{month}-{day} {hour}.{minute}.{second}', removeLocation: true, albumName: 'Hidden', deviceName: 'Test Phone' });
  const named = fs.readdirSync(path.join(T, 'named')).filter((f) => /^\d{4}-\d\d-\d\d \d\d\.\d\d\.\d\d( \(\d+\))?\.(JPG|MOV|HEIC)$/i.test(f));
  const reports = fs.readdirSync(path.join(T, 'named', 'PortHop Reports'));
  const csv = fs.readFileSync(path.join(T, 'named', 'PortHop Reports', reports[0]), 'utf8');
  check('file-name pattern + copy report', r.copied === 38 && named.length === 38 && reports.length === 1 && csv.includes('Copied,38') && csv.includes('Only in iCloud,1')
    && csv.includes('IMG_9000.HEIC') && !!r.reportPath, `${s(r)} ${named.length} ${reports.join()}`);
  r = await go('named', { namePattern: '{year}-{month}-{day} {hour}.{minute}.{second}', albumName: 'Hidden' });
  check('renamed copies are recognised next time', r.copied === 0 && r.skipped === 38 && fs.readdirSync(path.join(T, 'named', 'PortHop Reports')).length === 2, s(r));
  fs.rmSync(path.join(T, 'out1', '.porthop-manifest.json'));
  r = await go('out1'); check('adopt earlier export', r.copied === 1 && r.skipped === 37 && r.failures.length === 1, s(r));
  r = await go('out2', { includeLiveVideo: true, subfolder: 'yearMonth', useOriginalNames: true });
  check('live photos + by month', r.copied === 38 && r.failures.length === 1 && r.liveVideos === 5, s(r));
  process.env.FAKE_DELAY = '0.05';
  const job = new Job(); setTimeout(() => job.cancel(), 400);
  r = await go('out3', {}, job); const first = r.copied;
  check('cancel', r.cancelled && r.copied > 0 && r.copied < 38 && r.failures.length === 0 && r.copied + r.notAttempted === 39, s(r));
  process.env.FAKE_DELAY = '0';
  r = await go('out3'); check('resume after cancel', r.copied + first === 38 && r.skipped === first && r.failures.length === 1, s(r));
  check('no leftover staging', !['out1', 'out2', 'out3'].some((d) => fs.readdirSync(path.join(T, d)).some((f) => f.includes('staging'))));
  const listing = await ios.list('/DCIM/100APPLE', null, dev, tools);
  check('file listing', listing.length > 5 && listing[0].name.startsWith('IMG_') && listing[0].size > 0, JSON.stringify(listing.slice(0, 2)));
  const apps = await ios.apps(dev, tools);
  check('app list', apps.length === 2 && apps[0].name === 'Book Reader', JSON.stringify(apps));
  const xml = '<plist><array><dict><key>CFBundleIdentifier</key><string>a.b</string><key>CFBundleDisplayName</key><string>Tom &amp; Co</string><key>X</key><dict><key>UIFileSharingEnabled</key><false/></dict><key>UIFileSharingEnabled</key><true/></dict><dict><key>CFBundleIdentifier</key><string>c.d</string></dict></array></plist>';
  check('app list from installer output', JSON.stringify(ios.parseAppList(xml)) === '[{"id":"a.b","name":"Tom & Co"}]', JSON.stringify(ios.parseAppList(xml)));
  const app = 'com.example.player', local = path.join(T, 'phone/DCIM/100APPLE/IMG_0001.JPG');
  const names = new Set((await ios.list('/Documents', app, dev, tools)).map((e) => e.name));
  const p1 = await ios.put(local, '/Documents', names, app, dev, tools), p2 = await ios.put(local, '/Documents', names, app, dev, tools);
  const made = await ios.mkdir('/Documents/New Stuff', app, dev, tools);
  const after = await ios.list('/Documents', app, dev, tools);
  const got = path.join(T, 'back.jpg');
  const pulled = await ios.pull(after.find((e) => e.name === 'IMG_0001.JPG'), got, app, dev, tools);
  check('send to app and back (no overwrite)', p1 && p2 && made && pulled && fileSize(got) === fileSize(local) && after.some((e) => e.name === 'IMG_0001 (2).JPG'), JSON.stringify(after));
  process.env.FAKE_DELAY = '30';
  r = await go('out5', {}, new Job(), { stallLimit: 1.5 });
  process.env.FAKE_DELAY = '0';
  check('stalled device is abandoned, not waited on', r.stalled && r.copied === 0 && r.elapsed < 12 && r.failures.length === 0, s(r));

  // The porthop command line (cli.js), against the same simulated iPhone.
  const cli = (...a) => { try { return { code: 0, out: execFileSync(process.execPath, [path.join(__dirname, '..', 'cli.js'), ...a], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }) }; } catch (e) { return { code: e.status, out: String(e.stdout || '') }; } };
  const c1 = cli('devices', '--json'), c2 = cli('groups'), c3 = cli('copy', 'Hidden', path.join(T, 'cli-out'), '--pattern', '{year}/{month}', '--names', '{year}-{month}-{day} {hour}.{minute}.{second}');
  const c4 = cli('copy', 'smart_hidden', path.join(T, 'cli-out'), '--pattern', '{year}/{month}', '--names', '{year}-{month}-{day} {hour}.{minute}.{second}', '--json'), c5 = cli('copy', 'No Such Album', path.join(T, 'cli-out'));
  check('porthop command line', c1.out.includes('"kind": "ios"') && c2.out.includes('smart_hidden\tHidden\t39 items') && c2.out.includes('person:mum')
    && c3.code === 1 && c3.out.includes("Copied 38, already there 0, couldn't copy 1") && c4.out.includes('"skipped": 38') && c5.code === 2, JSON.stringify([c1, c2.out.slice(0, 200), c3, c4.out.slice(0, 200), c5.code]));
  const droid = path.join(T, 'android');
  for (const d of ['DCIM/Camera', 'Download', "Pictures/It's here"]) fs.mkdirSync(path.join(droid, d), { recursive: true });
  fs.copyFileSync(local, path.join(droid, 'DCIM/Camera/PXL 0001.jpg')); fs.copyFileSync(local, path.join(droid, "Pictures/It's here/a.jpg"));
  const none = (await android.findDevices(tools)).length === 0;
  process.env.FAKE_ANDROID = droid; process.env.FAKE_ANDROID_LOCKED = '1';
  const locked = (await android.findDevices(tools))[0]?.unauthorized === true;
  delete process.env.FAKE_ANDROID_LOCKED;
  const ad = (await android.findDevices(tools))[0], ai = await android.details(ad, tools);
  check('android device details', none && locked && ai.name === 'Pixel 8' && ai.modelName === 'Google Pixel 8' && ai.battery === 76 && ai.charging === true && ai.cycles === 212 && ai.totalBytes === 119771136 * 1024, JSON.stringify(ai));
  const top = await android.list('/sdcard', ad, tools), cam = await android.list('/sdcard/DCIM/Camera', ad, tools);
  check('android listing', top.map((e) => e.name).join() === 'DCIM,Download,Pictures' && cam.length === 1 && cam[0].name === 'PXL 0001.jpg' && cam[0].size === fileSize(local)
    && (await android.list("/sdcard/Pictures/It's here", ad, tools)).length === 1, JSON.stringify(cam));
  const ma = await android.mediaAlbums(ad, tools);
  check('android albums from MediaStore', ma.map((x) => x.path).sort().join('|') === "/sdcard/DCIM/Camera|/sdcard/Pictures/It's here"
    && ma.every((x) => x.count === 1 && x.bytes === fileSize(local))
    && android.parseMediaAlbums('Row: 0 _data=/storage/1234-ABCD/DCIM/x.jpg, _size=5\nRow: 1 _data=/sdcard/Movies/a, b.mp4, _size=9').map((x) => x.name).join() === 'Movies', JSON.stringify(ma));
  const w1 = await android.wireless({ pair: '192.168.1.20:37001', code: '123 456', address: '192.168.1.20:41235' }, tools);
  const w2 = await android.wireless({ pair: '192.168.1.20:37001', code: '111111', address: '192.168.1.20:41235' }, tools);
  const w3 = await android.wireless({ address: '192.168.1.20:5555' }, tools), w4 = await android.wireless({ address: 'not an address; rm -rf' }, tools);
  check('android wireless debugging pair and connect', w1 === null && /Pairing didn/.test(w2 || '') && /didn’t answer/.test(w3 || '') && /Enter the address/.test(w4 || ''), JSON.stringify([w1, w2, w3, w4]));
  const a1 = await android.pull(cam[0], path.join(T, 'pulled.jpg'), ad, tools), a2 = await android.pull(cam[0], path.join(T, 'pulled.jpg'), ad, tools);
  const dn = new Set();
  const s1 = await android.push(local, '/sdcard/Download', dn, ad, tools), s2 = await android.push(local, '/sdcard/Download', dn, ad, tools);
  const m1 = await android.mkdir('/sdcard/Download/New Stuff', ad, tools), m2 = await android.mkdir('/sdcard/Download/New Stuff', ad, tools);
  const dl = (await android.list('/sdcard/Download', ad, tools)).map((e) => e.name);
  check('android copy both ways (no overwrite)', a1 && !a2 && s1 && s2 && m1 && !m2 && dl.length === 3 && dl.includes('IMG_0001 (2).JPG'), JSON.stringify(dl));
  if (fs.existsSync(path.join(__dirname, 'backup.js'))) failures += await require('./backup')(T, check, macTests);
  failures += await require('./phase7')({ T, check, macTests, tools, dev, hidden, ad, droid });
  fs.rmSync(T, { recursive: true, force: true });
  console.log(failures === 0 ? 'ALL PASSED' : `${failures} FAILED`);
  process.exit(failures === 0 ? 0 : 1);
})();
