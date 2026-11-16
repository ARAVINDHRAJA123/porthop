'use strict';
const fs = require('node:fs'), path = require('node:path');
const { execFileSync } = require('node:child_process');
const bk = require('../core/backup');
module.exports = async function (T, check, macTests) {
  const before = process.exitCode;
  let failed = 0;
  const ck = (n, ok, d) => { if (!ok) failed++; check(n, ok, d); };
  const plain = path.join(T, 'backup', '0000-TEST'), secure = path.join(T, 'backup', '0000-SECURE');
  execFileSync(path.join(macTests, 'make_fake_backup.py'), [plain]);
  execFileSync(path.join(macTests, 'encrypt_fake_backup.py'), [plain, secure, 'correct horse']);
  const list = bk.existing(path.join(T, 'backup'));
  ck('backup list', list.length === 2 && list.filter((b) => b.encrypted).length === 1 && list[0].deviceName === 'Test iPhone' && list[0].osVersion === '27.2', JSON.stringify(list));
  for (const [label, folder, pw] of [['plain', plain, null], ['encrypted', secure, 'correct horse']]) {
    const { reader } = await bk.BackupReader.open(folder, pw);
    if (!reader) { ck(`${label} backup opens`, false); continue; }
    const g = async (k) => (await reader.load(k)).groups;
    const msg = await g('messages');
    ck(`${label} backup messages`, msg.length === 2 && msg[0].title === 'Weekend Trip' && msg[0].rows[0][1] === 'Sam Lee' && msg[0].rows.length === 2 && msg[0].rows[1][2].length === 70005 && msg[1].title === 'Asha Rao' && msg[1].rows.length === 5
      && msg[1].rows[1][1] === 'Me' && msg[1].rows[2][2] === 'From the archive' && msg[1].rows[3][2].length === 309 && msg[1].rows[4][2] === '(attachment)' && msg[1].rows[0][0].startsWith('2025-'), JSON.stringify(msg).slice(0, 600));
    const wa = await g('whatsapp');
    ck(`${label} backup whatsapp`, wa.length === 2 && wa[0].title === 'Family' && wa[0].rows[0][1] === 'Uncle Ravi' && wa[0].rows[1][2].startsWith('(photo') && wa[1].rows[1][2] === 'Yes', JSON.stringify(wa));
    const people = (await g('contacts'))[0].rows, notes = (await g('notes'))[0].rows, cals = await g('calendar'), web = await g('safari');
    ck(`${label} backup contacts, notes, calendar, safari`, people.length === 3 && people.some((p) => p.join('|') === 'Asha Rao||(415) 555-0101|asha@example.com') && notes.map((n) => n[0]).join() === 'Ideas,Shopping'
      && cals.length === 2 && cals.find((c) => c.title === 'Home').rows[0][2] === 'All day' && web.map((w) => w.title).join() === 'Bookmarks,History' && web[1].rows.length === 2, JSON.stringify([people, notes, cals, web]).slice(0, 600));
    const calls = await reader.load('calls'), fg = await g('files'), roll = fg.find((x) => x.subtitle === 'CameraRollDomain');
    const out = path.join(T, `bkout-${label}`); fs.mkdirSync(out);
    const e1 = await reader.extract(roll, [0], out), e2 = await reader.extract(roll, [0], out);
    const text = bk.csv(msg[1]);
    ck(`${label} backup files, extract, csv`, calls.groups.length === 0 && calls.note.length > 10 && fg.length === 6 && roll.title === 'Camera Roll' && e1.length === 1 && e2.length === 1 && e1[0] !== e2[0]
      && fs.readFileSync(e1[0]).equals(Buffer.from('jpegbytes'.repeat(100))) && text.startsWith('"Date","From","Message"\r\n') && text.includes('"Hi ""Asha"", how are you?"'), JSON.stringify([calls, e1, e2]));
    const temp = reader.temp; reader.close();
    ck(`${label} backup working copies removed`, !fs.existsSync(temp));
  }
  const a = await bk.BackupReader.open(secure, null), b = await bk.BackupReader.open(secure, 'wrong one');
  ck('encrypted backup refuses a missing or wrong password', a.needsPassword === true && b.wrongPassword === true
    && !fs.readFileSync(path.join(secure, 'Manifest.db')).subarray(0, 15).equals(Buffer.from('SQLite format 3')), JSON.stringify([a, b]));
  const dev = { udid: 'x', isNetwork: false }, { locateTools, Job } = require('../core/shell');
  const seen = [];
  const problem = await bk.runBackup(dev, locateTools(null), path.join(T, 'newbackup'), new Job(), (p) => seen.push(p));
  ck('run a backup', problem === null && seen.includes(1) && bk.existing(path.join(T, 'newbackup')).length === 1, JSON.stringify([problem, seen.slice(-3)]));
  const tools = locateTools(null), entries = bk.existing(path.join(T, 'backup'));
  const pe = entries.find((e) => e.path.endsWith('0000-TEST')), se = entries.find((e) => e.path.endsWith('0000-SECURE')), pcts = [];
  const asked = () => fs.readFileSync(path.join(T, 'backup', 'restore-request.txt'), 'utf8');
  const r1 = await bk.runRestore(pe, dev, tools, null, new Job(), (p) => p != null && pcts.push(p)), a1 = asked();
  const r2 = await bk.runRestore(se, dev, tools, null, new Job(), () => {});
  const r3 = await bk.runRestore(se, dev, tools, 'correct horse', new Job(), () => {}), a3 = asked();
  process.env.FAKE_FINDMY = '1';
  const r4 = await bk.runRestore(pe, dev, tools, null, new Job(), () => {});
  delete process.env.FAKE_FINDMY;
  process.env.FAKE_REFUSED = '1';
  const r5 = await bk.runRestore(pe, dev, tools, null, new Job(), () => {});
  delete process.env.FAKE_REFUSED;
  ck('restore asks the tool correctly and explains failures', r1 === null && pcts.at(-1) === 1 && a1.includes('--source 0000-TEST restore --system --settings --reboot') && a1.includes('password=none')
    && !a1.includes('--remove') && /password/.test(r2) && r3 === null && a3.includes('password=correct horse') && !a3.split(' | ')[0].includes('correct horse') && /Find My/.test(r4) && /ErrorCode 211/.test(r5) && /Find My/.test(r5), JSON.stringify([r1, pcts, a1, r2, r3, a3, r4]));
  return failed;
};
