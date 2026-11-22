'use strict';
const { contextBridge, ipcRenderer, webUtils } = require('electron');
const calls = ['state', 'refresh', 'switch', 'album:rows', 'pick:folder', 'pick:files', 'drives', 'space', 'defaults', 'reveal', 'copy',
  'export:start', 'export:stop', 'files:open', 'files:list', 'files:upload', 'files:download', 'files:mkdir', 'files:stop', 'power',
  'backup:list', 'backup:folder', 'backup:start', 'backup:restore', 'backup:stop', 'data:open', 'data:rows', 'data:save', 'data:extract', 'thumb', 'adb:setup', 'folders:copy', 'album:months', 'destinations', 'dest:remember', 'licences', 'github', 'appearance', 'export:facts', 'presets:list', 'presets:save', 'presets:delete', 'wifi', 'data:page'];
const events = ['state', 'export:progress', 'files:progress', 'backup:progress'];
contextBridge.exposeInMainWorld('bridge', {
  call: (name, arg) => (calls.includes(name) ? ipcRenderer.invoke(name, arg) : Promise.reject(new Error('unknown call'))),
  on: (name, fn) => { if (events.includes(name)) ipcRenderer.on(name, (_e, payload) => fn(payload)); },
  pathOf: (file) => webUtils.getPathForFile(file),
  test: (process.argv.find((a) => a.startsWith('--pae-ui-test=')) || '').slice('--pae-ui-test='.length),
});
