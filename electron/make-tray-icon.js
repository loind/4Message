// Sinh tray.png + tray@2x.png cho icon menu bar.
//
//   ./node_modules/.bin/electron make-tray-icon.js
//
// Phải là TEMPLATE IMAGE (đen + alpha): macOS tự đảo màu theo menu bar sáng/tối và theo
// trạng thái được chọn. Đặt màu cứng là sai ở một trong hai theme.
//
// Vẽ qua canvas rồi lấy toDataURL, KHÔNG dùng capturePage: capturePage cần cửa sổ
// transparent mới giữ được alpha, mà thiếu alpha thì template image thành khối đen đặc.
//
// Bong bóng + 3 chấm, không phải bolt của Messenger. Hai lý do, đã so ở cỡ thật:
//   1. Bolt ở 18px thành một khối đen tròn — cái đuôi bong bóng biến mất.
//   2. App có 4 kênh, mang mark riêng của Messenger lên menu bar là sai nghĩa.
'use strict'
const { app, BrowserWindow } = require('electron')
const fs = require('fs')
const path = require('path')

const BUBBLE_24 = 'M5 3h14a3 3 0 0 1 3 3v8a3 3 0 0 1-3 3h-7l-5 4v-4H5a3 3 0 0 1-3-3V6a3 3 0 0 1 3-3z'

// 20pt: 22 chật kín thanh menu bar, 18 thì chấm bị nhoè. Đã render cả ba để so.
const SIZES = { 'tray.png': 20, 'tray@2x.png': 40 }

app.whenReady().then(async () => {
  const w = new BrowserWindow({ show: false, width: 100, height: 100 })
  await w.loadURL('data:text/html,<canvas id=c></canvas>')

  for (const [name, size] of Object.entries(SIZES)) {
    const dataUrl = await w.webContents.executeJavaScript(`(() => {
      const c = document.getElementById('c'); c.width = c.height = ${size}
      const g = c.getContext('2d'); g.clearRect(0, 0, ${size}, ${size})
      g.scale(${size} / 24, ${size} / 24)
      g.fillStyle = '#000'
      g.fill(new Path2D(${JSON.stringify(BUBBLE_24)}))
      // destination-out để khoét chấm: vẽ chấm màu trắng sẽ thành khối trắng khi macOS
      // đảo màu, vì template image chỉ đọc alpha.
      g.globalCompositeOperation = 'destination-out'
      for (const x of [7.5, 12, 16.5]) { g.beginPath(); g.arc(x, 10, 1.7, 0, 7); g.fill() }
      return c.toDataURL('image/png')
    })()`)
    const png = Buffer.from(dataUrl.split(',')[1], 'base64')
    fs.writeFileSync(path.join(__dirname, name), png)
    console.log(`${name} ${size}×${size} ${png.length} bytes`)
  }
  w.destroy()
  app.quit()
})
