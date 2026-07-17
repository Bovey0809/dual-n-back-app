const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('lockAPI', {
  getState: () => ipcRenderer.invoke('lock:get-state'),
  sendHeartbeat: (payload) => ipcRenderer.send('lock:heartbeat', payload),
  requestSkip: (phrase) => ipcRenderer.invoke('lock:request-skip', { phrase }),
  onStateChanged: (cb) => ipcRenderer.on('lock:state-changed', (_e, s) => cb(s)),
  getAgentStatus: () => ipcRenderer.invoke('agent:get-status'),
  setAgentEnabled: (enabled) => ipcRenderer.invoke('agent:set-enabled', { enabled }),
});
