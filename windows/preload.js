'use strict';
const { contextBridge, ipcRenderer, webUtils } = require('electron');
const calls = ['state', 'refresh', 'switch', 'album:rows', 'pick:folder', 'pick:files', 'drives', 'space', 'defaults', 'reveal', 'copy',
  'export:start', 'export:stop', 'files:open', 'files:list', 'files:upload', 'files:download', 'files:mkdir', 'files:stop', 'power',
  'backup:list', 'backup:folder', 'backup:start', 'backup:restore', 'backup:stop', 'data:open', 'data:rows', 'data:save', 'data:extract', 'thumb', 'adb:setup', 'folders:copy', 'album:months', 'destinations', 'dest:remember', 'licences', 'github', 'appearance', 'export:facts', 'presets:list', 'presets:save', 'presets:delete', 'wifi', 'data:page', 'store', 'update:check', 'update:auto', 'update:open', 'presets:setAuto', 'presets:auto', 'notify', 'data:pdf', 'data:allChats', 'data:standard', 'data:extractAll', 'backup:auto', 'backup:autoDue', 'adb:wireless'];
const events = ['state', 'export:progress', 'files:progress', 'backup:progress'];
contextBridge.exposeInMainWorld('bridge', {
  call: (name, arg) => (calls.includes(name) ? ipcRenderer.invoke(name, arg) : Promise.reject(new Error('unknown call'))),
  // Returns a function that removes the listener again.
  on: (name, fn) => {
    if (!events.includes(name)) return () => {};
    const listener = (_e, payload) => fn(payload);
    ipcRenderer.on(name, listener);
    return () => ipcRenderer.removeListener(name, listener);
  },
  pathOf: (file) => webUtils.getPathForFile(file),
  test: (process.argv.find((a) => a.startsWith('--porthop-ui-test=')) || '').slice('--porthop-ui-test='.length),
});
