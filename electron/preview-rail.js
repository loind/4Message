// Render rail.html ra PNG cả light lẫn dark để soi bằng mắt trước khi ship.
//
//   ./node_modules/.bin/electron preview-rail.js /tmp/rail
//
// Cần vì máy build không có GUI session — screencapture chỉ ra desktop trống. Đây là cách
// duy nhất kiểm được rail "có đẹp không" mà không phải cài lên máy khác.
//
// Render cả ba số tile 1/2/4 (không chỉ 4): số kênh bật đổi được lúc chạy (menu Kênh) nên
// rail 1 và 2 tile là trạng thái thật, không phải trạng thái giả định.
'use strict'
const { app, BrowserWindow, nativeTheme } = require('electron')
const path = require('path')
const fs = require('fs')
const { SERVICES } = require('./services')

const out = process.argv[2] || '/tmp/rail'
const ZOOM = 3

// Hình học mirror #rail/.tile trong rail.html (padding 12px trên/dưới, tile 48px, gap 10px).
// WHY tính theo SERVICES.length thay vì hằng số: chiều cao cố định 210px có từ thời 3 kênh
// và đã âm thầm cắt tile thứ 4 — công cụ dùng để soi rail lại che mất chính trạng thái cần
// soi. Tính theo số kênh thật thì thêm kênh thứ 5 sau này không lặp lại lỗi đó.
const RAIL_PAD_Y = 12
const TILE = 48
const GAP = 10
const railHeight = (n) => RAIL_PAD_Y * 2 + n * TILE + Math.max(0, n - 1) * GAP

const state = (n) => ({
  active: 0,
  items: SERVICES.slice(0, n).map((s, i) => ({
    id: s.id, title: s.title, tint: s.tint,
    unread: i === 1 ? '3' : (i === 2 ? '12' : null),
  })),
})

app.whenReady().then(async () => {
  const w = new BrowserWindow({
    // frame:false: có title bar thì width/height truyền vào là kích thước NGOÀI, còn ảnh
    // chụp lại là content bên trong — hai bên lệch nhau một hằng số OS không đoán trước
    // được, tính railHeight() xong vẫn có thể hụt. Bỏ frame thì width/height khớp thẳng
    // content, khỏi phải đoán thêm hằng số nào khác ngoài hình học của rail.
    width: 68 * ZOOM, height: railHeight(SERVICES.length) * ZOOM, show: false, frame: false,
    webPreferences: { zoomFactor: ZOOM },
  })
  await w.loadFile(path.join(__dirname, 'rail.html'))
  for (const theme of ['light', 'dark']) {
    nativeTheme.themeSource = theme
    for (const n of [1, 2, 4]) {
      await w.webContents.executeJavaScript(`window.render(${JSON.stringify(state(n))})`)
      await new Promise(r => setTimeout(r, 400))
      fs.writeFileSync(`${out}-${theme}-${n}.png`, (await w.webContents.capturePage()).toPNG())
    }
  }
  console.log(`${out}-{light,dark}-{1,2,4}.png`)
  w.destroy()
  app.quit()
})
