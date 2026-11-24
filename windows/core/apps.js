'use strict';
// Lists, installs and removes the user's apps. iPhone: through PortHop's helper (installation service); only apps signed for
// that iPhone install (your own builds, ad-hoc and company apps; App Store apps cannot be). Android: through adb. Same as the Mac.
const path = require('node:path');
const { run } = require('./shell');
const android = require('./android');

const net = (d) => (d.isNetwork ? ['-n'] : []);

function parseIOS(text) {
  return String(text).split(/\r?\n/).map((l) => l.split('\t')).filter((f) => f.length >= 2 && f[0] && !f[0].startsWith('ERROR'))
    .map((f) => ({ id: f[0], name: f[1], version: f[2] || '', bytes: Number(f[3]) || 0 }))
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }));
}

/// Android lists only package names; versions come from the package manager's report and sizes from the storage report.
function parseAndroid(packages, versions, diskstats) {
  const ids = String(packages).split('\n').map((l) => l.trim()).filter((t) => t.startsWith('package:')).map((t) => t.slice(8).split(' ')[0]);
  const version = {};
  let current = null;
  for (const line of String(versions).split('\n')) {
    const t = line.trim();
    const m = t.match(/^Package \[([^\]]+)\]/);
    if (m) current = m[1];
    else if (t.startsWith('versionName=') && current && version[current] == null) version[current] = t.slice(12);
  }
  const array = (key) => {
    const line = String(diskstats).split('\n').find((l) => l.startsWith(key + ': ['));
    return line ? line.slice(line.indexOf('[') + 1, line.lastIndexOf(']')).split(',').map((v) => v.trim().replace(/^"|"$/g, '')) : [];
  };
  const names = array('Package Names'), app = array('App Sizes'), data = array('App Data Sizes'), size = {};
  names.forEach((n, i) => { size[n] = (Number(app[i]) || 0) + (Number(data[i]) || 0); });
  return ids.map((id) => ({ id, name: id, version: version[id] || '', bytes: size[id] || 0 })).sort((a, b) => (a.id < b.id ? -1 : 1));
}

async function list(device, tools) {
  if (device.kind === 'android') {
    const packages = await android.shell('pm list packages -3', device, tools, 60);
    if (packages == null) return null;
    return parseAndroid(packages, (await android.shell('dumpsys package packages', device, tools, 90)) || '', (await android.shell('dumpsys diskstats', device, tools, 60)) || '');
  }
  if (!tools.applist) return null;
  const r = await run(tools.applist, [device.udid, ...net(device), '--all'], { timeout: 60 });
  return r.ok ? parseIOS(r.output) : null;
}

const KNOWN = [
  ['ApplicationVerificationFailed', 'This app is not signed for this iPhone. Only apps signed for it (your own builds, ad-hoc or company apps) can be installed; App Store apps cannot.'],
  ['MismatchedApplicationIdentifierEntitlement', 'A different version of this app, from another developer, is already installed. Remove it first.'],
  ['DeviceOSVersionTooLow', 'This app needs a newer iOS version than the iPhone has.'],
  ['IncorrectArchitecture', 'This app was not built for this iPhone.'],
  ['PackageInspectionFailed', 'This is not a valid .ipa file.'],
  ['PackageExtractionFailed', 'This is not a valid .ipa file.'],
  ['UninstallProhibited', 'This app cannot be removed (it may be managed by an organisation).'],
  ['INSTALL_FAILED_VERSION_DOWNGRADE', 'A newer version of this app is already installed.'],
  ['INSTALL_FAILED_UPDATE_INCOMPATIBLE', 'The installed copy was signed by someone else. Remove it first, then install.'],
  ['INSTALL_FAILED_INSUFFICIENT_STORAGE', 'The phone is out of space.'],
  ['INSTALL_FAILED_USER_RESTRICTED', 'The phone blocked the install. Allow “Install via USB” in Developer options, or tap Allow on the phone.'],
  ['INSTALL_FAILED_OLDER_SDK', 'This app needs a newer Android version.'],
  ['INSTALL_FAILED_NO_MATCHING_ABIS', "This app was not built for this phone's processor."],
  ['INSTALL_PARSE_FAILED', 'This is not a valid .apk file.'],
  ['DELETE_FAILED_INTERNAL_ERROR', 'This app cannot be removed (it may be part of the system).'],
  ['DELETE_FAILED_DEVICE_POLICY_MANAGER', "This app is a device administrator. Turn that off in the phone's Settings first."],
  ['device not found', 'The phone is not connected.'],
];
/// Turns the installers' error names into something a person can act on.
function explain(raw) {
  raw = String(raw || '');
  for (const [code, text] of KNOWN) if (raw.includes(code)) return text;
  const line = raw.split(/\r?\n/).reverse().find((l) => l.includes('ERROR') || l.includes('Failure')) || raw;
  const t = line.trim();
  return t ? t.replace('ERROR: ', '') : 'The phone did not accept the request.';
}

/// Installs an .ipa (iPhone) or .apk (Android). Resolves to null when it worked, or a plain-language reason.
async function install(file, device, tools, progress = () => {}) {
  const ext = path.extname(file).slice(1).toLowerCase();
  if (device.kind === 'android') {
    if (ext !== 'apk') return 'Android apps install from an .apk file. Split bundles (.apks, .xapk) are not supported.';
    if (!tools.adb) return 'adb could not be started.';
    const r = await run(tools.adb, [...android.args(device), 'install', '-r', file], { timeout: 600 });
    return r.output.includes('Success') ? null : explain(r.output);
  }
  if (ext !== 'ipa') return 'iPhone apps install from an .ipa file.';
  if (!tools.applist) return 'The app helper is missing from PortHop. Download PortHop again.';
  const r = await run(tools.applist, [device.udid, ...net(device), '--install', file], {
    onOutput: (chunk) => { for (const m of chunk.matchAll(/PROGRESS (\d+)/g)) progress(Number(m[1])); } });
  return r.ok && r.output.includes('OK') ? null : explain(r.output);
}

async function uninstall(id, device, tools) {
  if (device.kind === 'android') {
    if (!tools.adb) return 'adb could not be started.';
    const r = await run(tools.adb, [...android.args(device), 'uninstall', id], { timeout: 120 });
    return r.output.includes('Success') ? null : explain(r.output);
  }
  if (!tools.applist) return 'The app helper is missing from PortHop. Download PortHop again.';
  const r = await run(tools.applist, [device.udid, ...net(device), '--uninstall', id], { timeout: 300 });
  return r.ok && r.output.includes('OK') ? null : explain(r.output);
}

/// "Show this iPhone when on Wi-Fi" (needed for Wi-Fi backups): reads it, or sets it first. null when the iPhone could not be asked.
async function wifiSync(device, tools, set = null) {
  if (device.kind === 'android' || !tools.applist) return null;
  const r = await run(tools.applist, [device.udid, ...net(device), '--wifi', ...(set == null ? [] : [set ? 'on' : 'off'])], { timeout: 20 });
  if (!r.ok) return null;
  const t = r.output.trim();
  return t === 'on' ? true : t === 'off' ? false : null;
}

module.exports = { list, install, uninstall, explain, parseIOS, parseAndroid, wifiSync };
