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
  return { version: core(j.tag_name), url: String(j.html_url || `https://github.com/${REPO}/releases`), name: String(j.name || ''), notes: String(j.body || '').slice(0, 1500) };
}

module.exports = { isNewer, latest, REPO };
