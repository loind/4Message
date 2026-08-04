// Rail chạy trong WebContentsView riêng nên cần bridge để bấm được sang main process.
const { contextBridge, ipcRenderer } = require('electron')
contextBridge.exposeInMainWorld('rail', {
  select: (i) => ipcRenderer.send('rail:select', i),
})
