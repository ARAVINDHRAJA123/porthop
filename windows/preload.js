'use strict';
const { contextBridge, ipcRenderer, webUtils } = require('electron');
const calls = ['state', 'refresh', 'switch', 'album:rows', 'pick:folder', 'pick:files', 'drives', 'space', 'defaults', 'reveal', 'copy',
  'export:start', 'export:stop', 'files:open', 'files:list', 'files:upload', 'files:download', 'files:mkdir', 'files:stop', 'power',
  'backup:list', 'backup:folder', 'backup:start', 'backup:restore', 'backup:stop', 'data:open', 'data:rows', 'data:save', 'data:extract', 'thumb', 'adb:setup', 'folders:copy', 'album:months', 'destinations', 'dest:remember', 'licences', 'github', 'appearance', 'export:facts', 'presets:list', 'presets:save', 'presets:delete', 'wifi', 'data:page', 'store', 'update:check', 'update:auto', 'update:open', 'presets:setAuto', 'presets:auto', 'notify', 'data:pdf', 'data:allChats', 'data:standard', 'data:extractAll', 'backup:auto', 'backup:autoDue', 'adb:wireless',
  'spy:sources', 'spy:download', 'spy:add', 'spy:backup', 'spy:check', 'spy:save', 'report:phone', 'apps:list', 'apps:install', 'apps:remove',
  'music:list', 'music:copy', 'music:send', 'music:stop', 'screen:start', 'screen:restart', 'screen:stop', 'screen:shot', 'screen:tap', 'screen:swipe',
  'screen:key', 'screen:save', 'hop:android', 'android:removeCopied', 'backup:wifi', 'update:install', 'music:saveTone', 'open:link'];
const events = ['state', 'export:progress', 'files:progress', 'backup:progress', 'screen:data', 'screen:end', 'apps:progress', 'music:progress', 'update:status'];
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
