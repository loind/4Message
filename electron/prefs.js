// Trạng thái người dùng chọn: kênh nào bật, rail có bị ẩn tay.
//
// Không dùng dependency: một object hai field không đáng một thư viện.
'use strict'
const fs = require('fs')
const path = require('path')

const FILE = 'prefs.json'

/** `enabled: null` = chưa chọn gì (dùng toàn bộ vũ trụ). Khác `[]` = chọn rỗng. */
function loadPrefs (dir) {
  try {
    const raw = JSON.parse(fs.readFileSync(path.join(dir, FILE), 'utf8'))
    const enabled = Array.isArray(raw.enabled)
      ? raw.enabled.filter(x => typeof x === 'string')
      : null
    return { enabled, railCollapsed: raw.railCollapsed === true }
  } catch {
    // Thiếu file là bình thường (lần chạy đầu); file rác thì về mặc định còn hơn sập.
    return { enabled: null, railCollapsed: false }
  }
}

function savePrefs (dir, prefs) {
  const body = JSON.stringify({
    enabled: prefs.enabled, railCollapsed: prefs.railCollapsed === true,
  }, null, 2) + '\n'
  // Ghi tạm rồi rename: sập giữa lúc ghi để lại JSON cắt dở, mà loadPrefs sẽ im lặng về
  // mặc định — tức mất sạch lựa chọn kênh của người dùng. rename là atomic.
  const tmp = path.join(dir, FILE + '.tmp')
  fs.writeFileSync(tmp, body)
  fs.renameSync(tmp, path.join(dir, FILE))
}

module.exports = { loadPrefs, savePrefs }
