'use strict';
// A one-page report about the phone (for selling it, or for a repair shop): model, storage, software, battery health.
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const SKIP = new Set(['Phone number', 'IMEI', 'Wi-Fi address', 'Bluetooth address', 'Identifier (UDID)', 'Time zone']);
const size = (n) => { const u = ['bytes', 'KB', 'MB', 'GB', 'TB']; let i = 0, v = n; while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; } return (i ? v.toFixed(v >= 100 ? 0 : 1) : v) + ' ' + u[i]; };

function phoneReport(d, isAndroid) {
  const rows = (d.info || []).filter(([label]) => !SKIP.has(label));
  if (d.totalBytes > 0) rows.push(['Storage', `${size(d.totalBytes)} (${size(d.totalBytes - d.freeBytes)} used)`]);
  if (d.health != null) rows.push(['Battery health', `${d.health}% of its original capacity`]);
  if (d.cycles != null) rows.push(['Battery charge cycles', String(d.cycles)]);
  if (d.battery != null) rows.push(['Charge now', `${d.battery}%`]);
  let b = `<!doctype html><meta charset=utf-8><title>${esc(d.name)} report</title><style>body{font:14px -apple-system,Segoe UI,sans-serif;margin:36px;color:#1d2433}h1{font-size:24px;margin:0}table{border-collapse:collapse;width:100%;margin:18px 0}td{border-bottom:1px solid #dde;padding:7px 8px}td:first-child{color:#667;width:38%}.dim{color:#667;font-size:12.5px}</style>`;
  b += `<h1>${esc(d.name)}</h1><div class=dim>Phone report made by PortHop on ${esc(new Date().toLocaleString())}, read from the phone over USB.</div><table>`;
  for (const [k, v] of rows) b += `<tr><td>${esc(k)}</td><td>${esc(v)}</td></tr>`;
  b += '</table>';
  b += isAndroid ? '<p class=dim>Battery health is what the phone reports about itself. Android does not report whether parts were replaced.</p>'
    : "<p class=dim>Battery health is read from the battery's own report (design capacity against today's full charge). Whether parts are genuine Apple parts is shown only on the iPhone itself, in Settings › General › About › Parts and Service History; Apple does not make it readable over USB.</p>";
  return b;
}

module.exports = { phoneReport };
