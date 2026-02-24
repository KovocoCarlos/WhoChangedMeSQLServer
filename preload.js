const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
  testConnection: (config) => ipcRenderer.invoke('test-connection', config),
  connect: (config) => ipcRenderer.invoke('connect', config),
  disconnect: () => ipcRenderer.invoke('disconnect'),
  getDatabases: () => ipcRenderer.invoke('get-databases'),
  getObjects: (database) => ipcRenderer.invoke('get-objects', database),
  checkExistingAudit: (params) => ipcRenderer.invoke('check-existing-audit', params),
  createAudit: (params) => ipcRenderer.invoke('create-audit', params),
  removeAudit: (params) => ipcRenderer.invoke('remove-audit', params),
  readAudit: (params) => ipcRenderer.invoke('read-audit', params),
  getAuditStatus: (params) => ipcRenderer.invoke('get-audit-status', params),
  selectFolder: () => ipcRenderer.invoke('select-folder')
});
