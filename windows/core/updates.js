'use strict';
// Looks for a newer PortHop on GitHub Releases. The request carries nothing about the computer or the person:
// it only asks GitHub for the latest release of the public repository.
const REPO = 'ARAVINDHRAJA123/porthop';

const parse = (v) => String(v || '').trim().replace(/^v/i, '').split(/[^0-9]+/).filter(Boolean).slice(0, 3).map((n) => parseInt(n, 10) || 0);
const core = (v) => String(v || '').trim().replace(/^v/i, '').split(/[-+ ]/)[0];

/// True when `candidate` is a later version than `current` ("2.10" > "2.9"; a "-beta" of the same number is not later).
function isNewer(candidate, current) {
  const a = parse(core(candidate)), b = parse(core(current));
  for (let i = 0; i < 3; i++) if ((a[i] || 0) !== (b[i] || 0)) return (a[i] || 0) > (b[i] || 0);
  return false;
}

async function latest(fetchImpl = fetch) {
  const res = await fetchImpl(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'PortHop' } });
  if (res.status === 404) return { none: true };   // nothing published yet
  if (!res.ok) throw new Error(`GitHub answered with an error (${res.status})`);
  const j = await res.json();
  const assets = {};
  for (const a of j.assets || []) if (a && a.name && a.browser_download_url) assets[a.name] = String(a.browser_download_url);
  return { version: core(j.tag_name), url: String(j.html_url || `https://github.com/${REPO}/releases`), name: String(j.name || ''), notes: String(j.body || '').slice(0, 1500), assets };
}

// MARK: Installing. Every download is checked against an Ed25519 signature made with the publisher's private key (the public
// half ships inside the app as update-key.pub), the protection Sparkle uses, so a tampered download is never run.
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');

function publicKey(appDir) {
  for (const p of [path.join(appDir, 'update-key.pub'), path.join(__dirname, '..', '..', 'update-key.pub')]) {
    try { const k = Buffer.from(fs.readFileSync(p, 'utf8').trim(), 'base64'); if (k.length === 32) return k; } catch {}
  }
  return null;
}

/// True when `signature` (base64 text, as in the release's .sig file) was made for exactly these bytes with the key's private half.
function verify(data, signature, rawKey) {
  try {
    const key = crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(rawKey)]), format: 'der', type: 'spki' });
    const sig = Buffer.from(String(signature).trim(), 'base64');
    return sig.length === 64 && crypto.verify(null, data, key, sig);
  } catch { return false; }
}

/// The Windows downloads in a release: the installer and the zip, each with its signature.
function windowsAssets(r) {
  const names = Object.keys(r.assets || {});
  const pick = (suffix) => { const n = names.find((x) => x.toLowerCase().endsWith(suffix)); return n && r.assets[n + '.sig'] ? { url: r.assets[n], sig: r.assets[n + '.sig'], name: n } : null; };
  return { setup: pick('-setup.exe'), zip: pick('-windows.zip') };
}

/// Downloads, verifies and starts installing the update. `appDir` is the folder holding PortHop.exe. Resolves to
/// { restart: true } when PortHop should quit now so the update can finish, or { error } (nothing changed then).
async function install(r, appDir, status = () => {}, fetchImpl = fetch) {
  if (process.platform !== 'win32') return { error: 'Updates install by themselves on Windows only.' };
  const key = publicKey(appDir);
  const { setup, zip } = windowsAssets(r);
  const installed = fs.existsSync(path.join(appDir, 'unins000.exe'));
  const asset = installed ? setup : zip;
  if (!key || !asset) return { error: 'This update has to be downloaded from the release page.' };
  status(`Downloading PortHop ${r.version}…`);
  let data, sig;
  try {
    const a = await fetchImpl(asset.url, { headers: { 'User-Agent': 'PortHop' } }), b = await fetchImpl(asset.sig, { headers: { 'User-Agent': 'PortHop' } });
    if (!a.ok || !b.ok) throw new Error('download');
    data = Buffer.from(await a.arrayBuffer()); sig = await b.text();
  } catch { return { error: 'The update could not be downloaded. Check the internet connection and try again.' }; }
  status('Checking the download…');
  if (!verify(data, sig, key)) return { error: "The download did not match the publisher's signature, so it was not installed." };
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'PortHop-update-'));
  const file = path.join(temp, asset.name);
  fs.writeFileSync(file, data);
  status('Installing…');
  if (installed) {
    spawn(file, ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
    return { restart: true };
  }
  // The zip version: unpack next to the download, then a small script waits for PortHop to close, mirrors the new files
  // into this folder and opens PortHop again.
  const unpacked = path.join(temp, 'new');
  const ps = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', `Expand-Archive -LiteralPath '${file.replace(/'/g, "''")}' -DestinationPath '${unpacked.replace(/'/g, "''")}' -Force`], { windowsHide: true });
  const ok = await new Promise((res) => { ps.on('close', (c) => res(c === 0)); ps.on('error', () => res(false)); });
  const inner = path.join(unpacked, 'PortHop');
  if (!ok || !fs.existsSync(path.join(inner, 'PortHop.exe'))) return { error: 'The download was not a complete copy of PortHop.' };
  const script = path.join(temp, 'finish-update.cmd');
  fs.writeFileSync(script, [
    '@echo off',
    `:wait`,
    `tasklist /FI "PID eq ${process.pid}" | find "${process.pid}" >nul && (timeout /t 1 /nobreak >nul & goto wait)`,
    `robocopy "${inner}" "${appDir}" /E /IS /IT /R:3 /W:1 /NFL /NDL /NJH /NJS >nul`,
    `start "" "${path.join(appDir, 'PortHop.exe')}"`,
  ].join('\r\n'));
  spawn('cmd.exe', ['/c', script], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
  return { restart: true };
}

module.exports = { isNewer, latest, REPO, verify, windowsAssets, install, publicKey };
