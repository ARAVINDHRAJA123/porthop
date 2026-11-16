'use strict';
// Builds the Windows app folder and a zip of it into ./dist. Run `python3 fetch-tools.py` first.
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const { execFileSync } = require('node:child_process');
const { packager } = require('@electron/packager');

(async () => {
  const toolsSrc = path.join(__dirname, 'tools-win');
  if (!fs.existsSync(path.join(toolsSrc, 'afcclient.exe'))) throw new Error('Run "python3 fetch-tools.py" first: tools-win is missing.');
  const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'pae-pack-'));
  const tools = path.join(stage, 'tools');
  fs.cpSync(toolsSrc, tools, { recursive: true });
  const [out] = await packager({
    dir: __dirname, name: 'Phone Album Extractor', platform: 'win32', arch: 'x64', out: path.join(__dirname, 'dist'), overwrite: true,
    icon: path.join(__dirname, 'icon.ico'), extraResource: [tools], prune: true, asar: true,
    ignore: [/^\/(test|dist|tools-win|\.msys-cache|fetch-tools\.py|package-win\.js|README\.md|\.gitignore)/],
    appCopyright: 'Bundled device tools are open source; see resources/tools/licenses.',
    win32metadata: { CompanyName: 'Phone Album Extractor', FileDescription: 'Phone Album Extractor', ProductName: 'Phone Album Extractor' },
  });
  fs.copyFileSync(path.join(__dirname, 'README.md'), path.join(out, 'READ ME FIRST.txt'));
  const zip = path.join(__dirname, 'dist', 'Phone-Album-Extractor-Windows.zip');
  fs.rmSync(zip, { force: true });
  execFileSync('zip', ['-r', '-q', '-X', zip, path.basename(out)], { cwd: path.dirname(out) });
  fs.rmSync(stage, { recursive: true, force: true });
  console.log('Built', out, '\nZip', zip, Math.round(fs.statSync(zip).size / 1e6) + ' MB');
})().catch((e) => { console.error(e.message); process.exit(1); });
