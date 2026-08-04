// Render rail.html ra PNG cả light lẫn dark để soi bằng mắt trước khi ship.
//
//   ./node_modules/.bin/electron preview-rail.js /tmp/rail
//
// Cần vì máy build không có GUI session — screencapture chỉ ra desktop trống. Đây là cách
// duy nhất kiểm được rail "có đẹp không" mà không phải cài lên máy khác.
'use strict'
const { app, BrowserWindow, nativeTheme } = require('electron')
const path = require('path')
const fs = require('fs')
const { SERVICES } = require('./services')

const out = process.argv[2] || '/tmp/rail'
const ZOOM = 3

const state = {
  active: 0,
  items: SERVICES.map((s, i) => ({
    id: s.id, title: s.title, tint: s.tint,
    unread: i === 1 ? '3' : (i === 2 ? '12' : null),
  })),
}

app.whenReady().then(async () => {
  const w = new BrowserWindow({
    width: 68 * ZOOM, height: 210 * ZOOM, show: false,
    webPreferences: { zoomFactor: ZOOM },
  })
  await w.loadFile(path.join(__dirname, 'rail.html'))
  await w.webContents.executeJavaScript(`window.render(${JSON.stringify(state)})`)
  for (const theme of ['light', 'dark']) {
    nativeTheme.themeSource = theme
    await new Promise(r => setTimeout(r, 400))
    fs.writeFileSync(`${out}-${theme}.png`, (await w.webContents.capturePage()).toPNG())
  }
  w.destroy()
  console.log(`${out}-light.png ${out}-dark.png`)
  app.quit()
})
