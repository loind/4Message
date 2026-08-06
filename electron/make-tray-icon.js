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
// Bong bóng + 4 chấm 2×2, khớp hình với app icon. Không dùng bolt của Messenger: app có
// 4 kênh nên mang mark riêng của một kênh lên menu bar là sai nghĩa.
//
// 2×2 chứ KHÔNG phải hàng 4 — đo ở cỡ thật thì hàng 4 nhoè thành một vạch.
'use strict'
const { app, BrowserWindow } = require('electron')
const fs = require('fs')
const path = require('path')

// Hình dựng theo ĐÚNG tỉ lệ của app icon (tools/make-icon.swift) để hai asset khớp nhau.
// Các phân số dưới đây lấy từ hình học 1024 của app icon; sửa một bên phải sửa bên kia.
//
//   bubble 470×404  → tỉ lệ 1.163, bo góc 128/470
//   chấm   r 46, gap 132 (theo bề rộng bubble)
//   đuôi   bezier gốc, toạ độ tính theo phần trăm bubble
const R = { ratio: 470 / 404, corner: 128 / 470, dotR: 46 / 470, dotGap: 132 / 470 }
// Đuôi trong hệ CoreGraphics của app icon: (x/566, y/396), y dương là LÊN.
const TAIL = [
  [148 / 566, 64 / 396],
  [136 / 566, -24 / 396], [108 / 566, -74 / 396], [84 / 566, -112 / 396],
  [206 / 566, -52 / 396], [274 / 566, 34 / 396], [338 / 566, 44 / 396],
]
const TAIL_DROP = 112 / 396   // đuôi thò xuống bao nhiêu phần chiều cao bubble

// Glyph phải TRÀN KHUNG: tray không có plate, giữ tỉ lệ của app icon (bubble ~46% khung)
// thì ở 20px bubble chỉ còn ~9px và bốn chấm biến mất.
const PAD = 1.1
const H = (24 - PAD * 2) / (1 + TAIL_DROP)      // chiều cao bubble
const W = H * R.ratio
const BX = (24 - W) / 2
const BY = PAD                                   // canvas: y tăng xuống dưới

const SIZES = { 'tray.png': 20, 'tray@2x.png': 40 }

/** Path bubble + đuôi trong hộp 24 đơn vị, hệ canvas (y xuống). */
function bubbleJS () {
  const r = R.corner * W
  const bottom = BY + H
  // CG y dương là lên, canvas là xuống → đổi dấu quanh mép dưới bubble.
  const P = (fx, fy) => [BX + fx * W, bottom - fy * H]
  let d = ''
  d += `M${BX + r},${BY} h${W - 2 * r} a${r},${r} 0 0 1 ${r},${r} v${H - 2 * r}`
  d += ` a${r},${r} 0 0 1 ${-r},${r} h${-(W - 2 * r)} a${r},${r} 0 0 1 ${-r},${-r}`
  d += ` v${-(H - 2 * r)} a${r},${r} 0 0 1 ${r},${-r} z`
  const [m, c1, c2, e1, c3, c4, e2] = TAIL.map(([x, y]) => P(x, y))
  d += ` M${m[0]},${m[1]} C${c1[0]},${c1[1]} ${c2[0]},${c2[1]} ${e1[0]},${e1[1]}`
  d += ` C${c3[0]},${c3[1]} ${c4[0]},${c4[1]} ${e2[0]},${e2[1]} z`
  return d
}

function dotsJS () {
  const r = R.dotR * W, gap = R.dotGap * W
  const cx = BX + W / 2, cy = BY + H / 2
  const out = []
  for (let row = 0; row < 2; row++) for (let col = 0; col < 2; col++) {
    out.push([cx + (col - 0.5) * gap, cy + (row - 0.5) * gap, r])
  }
  return out
}

app.whenReady().then(async () => {
  const w = new BrowserWindow({ show: false, width: 100, height: 100 })
  await w.loadURL('data:text/html,<canvas id=c></canvas>')

  for (const [name, size] of Object.entries(SIZES)) {
    const dataUrl = await w.webContents.executeJavaScript(`(() => {
      const c = document.getElementById('c'); c.width = c.height = ${size}
      const g = c.getContext('2d'); g.clearRect(0, 0, ${size}, ${size})
      g.scale(${size} / 24, ${size} / 24)
      g.fillStyle = '#000'
      g.fill(new Path2D(${JSON.stringify(bubbleJS())}))
      // destination-out để khoét chấm: vẽ chấm màu trắng sẽ thành khối trắng khi macOS
      // đảo màu, vì template image chỉ đọc alpha.
      g.globalCompositeOperation = 'destination-out'
      for (const [x, y, r] of ${JSON.stringify(dotsJS())}) {
        g.beginPath(); g.arc(x, y, r, 0, 7); g.fill()
      }
      return c.toDataURL('image/png')
    })()`)
    const png = Buffer.from(dataUrl.split(',')[1], 'base64')
    fs.writeFileSync(path.join(__dirname, name), png)
    console.log(`${name} ${size}×${size} ${png.length} bytes`)
  }
  w.destroy()
  app.quit()
})
