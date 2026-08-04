# Bật/tắt kênh lúc chạy + ẩn rail — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bật/tắt từng kênh lúc chạy qua menu (tắt = hủy view để trả RAM), và ẩn rail được bằng ⌘0 độc lập với quy tắc "chỉ còn 1 kênh thì tự ẩn".

**Architecture:** `runtimes[]` vẫn chỉ chứa kênh đang bật, nhưng danh tính kênh đang xem đổi từ `activeIndex` (số) sang `activeId` (chuỗi) — mảng co giãn lúc bật/tắt làm mọi index đang giữ đều lệch. Ba quy tắc thuần (`resolveEnabled`, `railVisible`, load/save prefs) tách ra khỏi `main.js` để `selftest.js` gác được mà không cần GUI, mạng hay login. Vòng đời view kiểm bằng cách chứng minh **process renderer chết**, không bằng cách đo footprint.

**Tech Stack:** Electron 43.2.0, JavaScript thuần (không TypeScript, không test framework). Test = `node:assert` chạy qua `node electron/selftest.js`, đúng cổng build hiện có.

## Global Constraints

- Không thêm dependency. `prefs.json` đọc/ghi bằng `node:fs`.
- `selftest.js` là cổng build (`build-electron.sh` bước 3) — fail là không package.
- Thứ tự rail LUÔN theo thứ tự canonical trong `SERVICES`, không theo thứ tự bấm bật.
- `resolveEnabled` **không bao giờ** trả 0 kênh.
- `FBMESS_SERVICES` là vũ trụ kênh khả dụng; prefs chỉ bật/tắt trong vũ trụ đó.
- Comment tiếng Việt, chỉ viết WHY cho chỗ có invariant hoặc failure mode thật.
- Conventional commit, subject ≤ 72 ký tự.

---

### Task 1: Hai quy tắc thuần trong `services.js`

**Files:**
- Modify: `electron/services.js:158` (thêm export)
- Test: `electron/selftest.js`

**Interfaces:**
- Consumes: `SERVICES` (mảng service object có `.id`), `resolveServices(raw)` — đã có.
- Produces:
  - `resolveEnabled(universe: Service[], prefs: {enabled?: string[]}) → Service[]` — thứ tự canonical theo `universe`, không bao giờ rỗng.
  - `railVisible(enabledCount: number, collapsed: boolean) → boolean`

- [ ] **Step 1: Viết test fail trước**

Thêm vào cuối `electron/selftest.js`, TRƯỚC dòng `console.log`:

```js
const { resolveEnabled, railVisible } = require('./services')

const ALL = SERVICES
const ids = (list) => list.map(s => s.id)

// Thứ tự rail phải canonical, KHÔNG theo thứ tự người dùng bấm bật.
assert.deepStrictEqual(ids(resolveEnabled(ALL, { enabled: ['zalo', 'messenger'] })), ['messenger', 'zalo'])
// Không bao giờ 0 kênh — cửa sổ rỗng là trạng thái không có đường thoát bằng chuột.
assert.deepStrictEqual(ids(resolveEnabled(ALL, { enabled: [] })), ids(ALL))
assert.deepStrictEqual(ids(resolveEnabled(ALL, { enabled: ['nope'] })), ids(ALL))
assert.deepStrictEqual(ids(resolveEnabled(ALL, {})), ids(ALL))
// prefs.json là file người dùng sửa được bằng tay → kiểu sai phải không làm sập.
assert.deepStrictEqual(ids(resolveEnabled(ALL, { enabled: 'messenger' })), ids(ALL))
assert.deepStrictEqual(ids(resolveEnabled(ALL, { enabled: [null, 3] })), ids(ALL))
// Id ngoài vũ trụ FBMESS_SERVICES bị bỏ.
const TWO = resolveServices('messenger,instagram')
assert.deepStrictEqual(ids(resolveEnabled(TWO, { enabled: ['zalo'] })), ids(TWO))
assert.deepStrictEqual(ids(resolveEnabled(TWO, { enabled: ['instagram'] })), ['instagram'])
// Trùng lặp không sinh tile trùng.
assert.deepStrictEqual(ids(resolveEnabled(ALL, { enabled: ['zalo', 'zalo'] })), ['zalo'])

assert.strictEqual(railVisible(1, false), false)
assert.strictEqual(railVisible(2, false), true)
assert.strictEqual(railVisible(2, true), false)
assert.strictEqual(railVisible(1, true), false)
```

- [ ] **Step 2: Chạy test để chắc là nó fail**

Run: `node electron/selftest.js`
Expected: FAIL — `TypeError: resolveEnabled is not a function`

- [ ] **Step 3: Implement tối thiểu**

Thêm vào `electron/services.js` ngay trước `module.exports`:

```js
/**
 * Kênh nào đang bật. `universe` là danh sách khả dụng (từ FBMESS_SERVICES); prefs chỉ
 * bật/tắt TRONG đó.
 *
 * Không bao giờ trả rỗng: cửa sổ 0 kênh không có đường thoát bằng chuột, mà prefs.json là
 * file người dùng sửa được bằng tay nên phải chịu được nội dung rác.
 */
function resolveEnabled (universe, prefs) {
  const want = prefs && Array.isArray(prefs.enabled) ? prefs.enabled : null
  if (!want) return universe.slice()
  const set = new Set(want.filter(x => typeof x === 'string'))
  // Lọc theo `universe` nên thứ tự canonical và tính duy nhất đều có sẵn.
  const picked = universe.filter(s => set.has(s.id))
  return picked.length ? picked : universe.slice()
}

/** Rail chỉ có nghĩa khi có nhiều hơn một kênh để chọn. */
function railVisible (enabledCount, collapsed) {
  return enabledCount > 1 && !collapsed
}
```

Sửa dòng export:

```js
module.exports = {
  SERVICES, INTERNAL_HOSTS, isInternal, isSurface, resolveServices, unreadFromTitle,
  resolveEnabled, railVisible,
}
```

- [ ] **Step 4: Chạy test để chắc là nó pass**

Run: `node electron/selftest.js`
Expected: PASS — in `selftest OK (4 services)`

- [ ] **Step 5: Commit**

```bash
git add electron/services.js electron/selftest.js
git commit -m "feat(electron): quy tắc kênh đang bật và rail có hiện"
```

---

### Task 2: `prefs.js` — đọc/ghi trạng thái

**Files:**
- Create: `electron/prefs.js`
- Test: `electron/selftest.js`

**Interfaces:**
- Produces:
  - `loadPrefs(dir: string) → {enabled: string[]|null, railCollapsed: boolean}` — `enabled: null` nghĩa là "chưa chọn gì", khác với `[]`.
  - `savePrefs(dir: string, prefs: {enabled: string[]|null, railCollapsed: boolean}) → void`

- [ ] **Step 1: Viết test fail trước**

Thêm vào cuối `electron/selftest.js`, TRƯỚC dòng `console.log`:

```js
const os = require('os')
const fs = require('fs')
const path = require('path')
const { loadPrefs, savePrefs } = require('./prefs')

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fbmess-prefs-'))

// Chưa có file → mặc định. enabled=null nghĩa "chưa chọn", khác [] nghĩa "chọn rỗng".
assert.deepStrictEqual(loadPrefs(dir), { enabled: null, railCollapsed: false })

// File rác không được làm sập app.
fs.writeFileSync(path.join(dir, 'prefs.json'), '{ this is not json')
assert.deepStrictEqual(loadPrefs(dir), { enabled: null, railCollapsed: false })

// Kiểu sai từng field cũng phải chịu được.
fs.writeFileSync(path.join(dir, 'prefs.json'), JSON.stringify({ enabled: 'messenger', railCollapsed: 'true' }))
assert.deepStrictEqual(loadPrefs(dir), { enabled: null, railCollapsed: false })
fs.writeFileSync(path.join(dir, 'prefs.json'), JSON.stringify({ enabled: ['messenger', 7, null] }))
assert.deepStrictEqual(loadPrefs(dir), { enabled: ['messenger'], railCollapsed: false })

// Round trip.
savePrefs(dir, { enabled: ['messenger', 'zalo'], railCollapsed: true })
assert.deepStrictEqual(loadPrefs(dir), { enabled: ['messenger', 'zalo'], railCollapsed: true })

// Ghi xong không được để lại file tạm.
assert.deepStrictEqual(fs.readdirSync(dir), ['prefs.json'])

fs.rmSync(dir, { recursive: true, force: true })
```

- [ ] **Step 2: Chạy test để chắc là nó fail**

Run: `node electron/selftest.js`
Expected: FAIL — `Cannot find module './prefs'`

- [ ] **Step 3: Implement tối thiểu**

Tạo `electron/prefs.js`:

```js
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
```

- [ ] **Step 4: Chạy test để chắc là nó pass**

Run: `node electron/selftest.js`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add electron/prefs.js electron/selftest.js
git commit -m "feat(electron): lưu lựa chọn kênh vào prefs.json"
```

---

### Task 3: Đổi danh tính kênh đang xem từ index sang `id`

Đây là task refactor thuần, hành vi không đổi. Làm riêng để nếu vỡ thì biết chắc là do
refactor, không lẫn với tính năng mới.

**Files:**
- Modify: `electron/main.js:25` (`activeIndex` → `activeId`), `:51-58` (`layout`), `:60-71` (`pushRailState`), `:73-81` (`updateBadge`), `:141-150` (`select`), `:169` (`createWindow`), `:200`, `:205` (`buildTray`), `:224-226` (`buildMenu`), `:245` (ipc), `:276` (probe)

**Interfaces:**
- Consumes: `runtimes` — mảng `{service, view, unread}` chỉ chứa kênh đang bật.
- Produces:
  - `activeId: string|null` — id kênh đang xem
  - `active() → {service, view, unread}|undefined`
  - `activeIdx() → number` — vị trí trong `runtimes`, `-1` nếu không có
  - `selectId(id: string) → void` — thay `select(i)`

- [ ] **Step 1: Viết test fail trước**

`--probe` là test cho tầng runtime, nhưng hiện nó chỉ IN ra để người đọc tự so. Test không
assert thì không fail được — thêm helper assert dùng chung cho mọi probe mode.

Thêm vào `electron/main.js` ngay sau `const probeOpened = []`:

```js
let probeFailed = 0

/** Assert cho probe mode: in PASS/FAIL và đếm, để process exit code phản ánh kết quả. */
function check (label, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected)
  if (!ok) probeFailed++
  console.log(`${ok ? 'PASS' : 'FAIL'} ${label}: ${JSON.stringify(actual)}${ok ? '' : ' — kỳ vọng ' + JSON.stringify(expected)}`)
}

/** Thoát với code khác 0 khi có assert fail — không thì CI coi như pass. */
function probeExit () {
  console.log(probeFailed ? `${probeFailed} assert FAIL` : 'tất cả assert PASS')
  app.isQuitting = true
  app.exit(probeFailed ? 1 : 0)
}
```

Sửa khối probe (`:264-266`) — thay `console.log` bằng assert thật:

```js
    check('rail tiles', tiles, services.length)
    check('activeId', activeId, services[0].id)
```

Và thay cuối khối `--probe`:

```js
    app.isQuitting = true
    app.quit()
```

bằng:

```js
    probeExit()
```

- [ ] **Step 2: Chạy để chắc là nó fail**

Run: `cd electron && ./node_modules/.bin/electron . --probe 2>&1 | grep -E "^(PASS|FAIL)"; echo "exit=$?"`
Expected: FAIL — `FAIL activeId: null — kỳ vọng "messenger"` vì `activeId` chưa được gán

- [ ] **Step 3: Implement tối thiểu**

`electron/main.js:25` — thay:

```js
let activeIndex = 0
```

bằng:

```js
// Danh tính kênh đang xem là `id`, KHÔNG phải index: runtimes[] co giãn khi bật/tắt kênh
// nên mọi index đang giữ đều lệch một cách im lặng.
let activeId = null

function active () { return runtimes.find(r => r.service.id === activeId) }
function activeIdx () { return runtimes.findIndex(r => r.service.id === activeId) }
```

`:56` trong `layout()` — thay `const rt = runtimes[activeIndex]` bằng `const rt = active()`

`:63` trong `pushRailState()` — thay `active: activeIndex,` bằng `active: activeIdx(),`

`:74` trong `updateBadge()` — thay `const rt = runtimes[activeIndex]` bằng `const rt = active()`

`:141-150` — thay toàn bộ `function select (i)` bằng:

```js
function selectId (id) {
  const next = runtimes.find(r => r.service.id === id)
  if (!next || !win) return
  const prev = active()
  if (prev && prev !== next) win.contentView.removeChildView(prev.view)
  activeId = id
  win.contentView.addChildView(next.view)
  layout()
  pushRailState()
  updateBadge()
}
```

`:169` trong `createWindow()` — thay:

```js
  win.contentView.addChildView(runtimes[0].view)
  layout()
```

bằng:

```js
  activeId = runtimes[0].service.id
  win.contentView.addChildView(runtimes[0].view)
  layout()
```

`:200` trong `buildTray()` — thay `checked: i === activeIndex,` bằng `checked: r.service.id === activeId,`

`:200-202` — thay `click: () => { select(i); win.show() },` bằng `click: () => { selectId(r.service.id); win.show() },`

`:205` — thay `runtimes[activeIndex].view` bằng `active().view`

`:220-221` trong `buildMenu()` — thay:

```js
        ...runtimes.map((r, i) => ({
          label: r.service.title, accelerator: `Cmd+${i + 1}`, click: () => select(i),
        })),
```

bằng:

```js
        ...runtimes.map((r, i) => ({
          label: r.service.title, accelerator: `Cmd+${i + 1}`,
          click: () => selectId(r.service.id),
        })),
```

`:224-226` — thay cả ba lần `runtimes[activeIndex]` bằng `active()`

`:245` — thay:

```js
  ipcMain.on('rail:select', (_e, i) => select(i))
```

bằng:

```js
  // Rail gửi vị trí tile; đổi ngay sang id vì index chỉ đúng tại thời điểm render.
  ipcMain.on('rail:select', (_e, i) => {
    const rt = runtimes[i]
    if (rt) selectId(rt.service.id)
  })
```

`:276` trong probe — thay `const wc = runtimes[0].view.webContents` bằng `const wc = active().view.webContents`

- [ ] **Step 4: Chạy để chắc là nó pass**

```bash
node electron/selftest.js
cd electron && ./node_modules/.bin/electron . --probe > /tmp/probe.log 2>&1; echo "exit=$?"
grep -E "^(PASS|FAIL)|assert" /tmp/probe.log
```
Expected: `exit=0` và `tất cả assert PASS`. **Exit code là cổng** — grep chỉ để đọc.

- [ ] **Step 5: Commit**

```bash
git add electron/main.js
git commit -m "refactor(electron): kênh đang xem nhận theo id, không theo index"
```

---

### Task 4: Bật/tắt kênh — vòng đời view

**Files:**
- Modify: `electron/main.js` (thêm `setEnabled`, sửa `layout`, `createWindow`)

**Interfaces:**
- Consumes: `resolveEnabled`, `railVisible` (Task 1); `loadPrefs`, `savePrefs` (Task 2); `activeId`, `active()`, `selectId` (Task 3).
- Produces:
  - `setEnabled(id: string, on: boolean) → void`
  - `enabledIds() → string[]`
  - `persist() → void`
  - `railCollapsed: boolean` (module-level)

- [ ] **Step 1: Viết test fail trước**

Thêm mode `--probe-toggle` vào `electron/main.js`, ngay sau khối `if (probe)` trong
`app.whenReady()`. Test kiểm điều mạnh nhất: **process renderer của kênh bị tắt phải chết.**
Process chết là RAM đã trả về OS — không phải suy đoán như đo footprint, nơi bmalloc trả page
chậm và từng làm số liệu bản WKWebView vô nghĩa.

```js
  if (process.argv.includes('--probe-toggle')) setTimeout(async () => {
    const pids = new Map(runtimes.map(r => [r.service.id, r.view.webContents.getOSProcessId()]))
    console.log(`bật ${runtimes.length} kênh: ${[...pids.entries()].map(([k, v]) => k + '=' + v).join(' ')}`)

    const keep = runtimes[0].service.id
    for (const id of [...pids.keys()].filter(x => x !== keep)) setEnabled(id, false)
    // Process chết không đồng bộ với close() — chờ rồi mới kiểm liveness.
    await new Promise(r => setTimeout(r, 3000))

    check('còn bật', runtimes.length, 1)
    check('activeId sau khi tắt kênh đang xem', activeId, keep)

    // Điều kiện MẠNH NHẤT của thiết kế: process renderer của kênh tắt phải CHẾT.
    // Process chết là RAM đã trả về OS — khác với đo footprint, nơi bmalloc trả page chậm
    // và từng làm số liệu bản WKWebView vô nghĩa.
    const alive = (pid) => { try { process.kill(pid, 0); return true } catch { return false } }
    const leaked = [...pids.entries()].filter(([id, pid]) => id !== keep && alive(pid)).map(([id]) => id)
    check('process kênh đã tắt còn sống', leaked, [])

    check('rail hiện khi còn 1 kênh', railVisible(runtimes.length, railCollapsed), false)

    // Tắt kênh cuối cùng phải là no-op: cửa sổ rỗng không có đường thoát bằng chuột.
    setEnabled(keep, false)
    check('còn bật sau khi thử tắt kênh cuối', runtimes.length, 1)

    // Bật lại phải vào đúng vị trí canonical. Bật services[3] TRƯỚC services[1] để chứng
    // minh chèn giữa — nếu chỉ append thì thứ tự sẽ là [0],[3],[1] và assert này fail.
    setEnabled(services[3].id, true)
    setEnabled(services[1].id, true)
    check('thứ tự canonical sau khi bật lại',
      runtimes.map(r => r.service.id),
      [services[0].id, services[1].id, services[3].id])

    persist()
    probeExit()
  }, 20000)
```

- [ ] **Step 2: Chạy để chắc là nó fail**

Run: `cd electron && ./node_modules/.bin/electron . --probe-toggle > /tmp/pt.log 2>&1; echo "exit=$?"; grep -E "^(PASS|FAIL)|assert" /tmp/pt.log`
Expected: FAIL — `ReferenceError: setEnabled is not defined`, `exit` khác 0

- [ ] **Step 3: Implement tối thiểu**

`electron/main.js` — sửa import ở đầu file:

```js
const {
  isInternal, isSurface, resolveServices, unreadFromTitle, resolveEnabled, railVisible,
} = require('./services')
const { loadPrefs, savePrefs } = require('./prefs')
```

Thêm ngay sau `const runtimes = []`:

```js
let prefs = { enabled: null, railCollapsed: false }
let railCollapsed = false

function enabledIds () { return runtimes.map(r => r.service.id) }

function persist () {
  savePrefs(app.getPath('userData'), { enabled: enabledIds(), railCollapsed })
}

/** Vị trí canonical: đếm số kênh đang bật đứng trước `id` trong `services`. */
function canonicalSlot (id) {
  const rank = (sid) => services.findIndex(s => s.id === sid)
  return runtimes.filter(r => rank(r.service.id) < rank(id)).length
}

function setEnabled (id, on) {
  const svc = services.find(s => s.id === id)
  if (!svc || !win) return
  const at = runtimes.findIndex(r => r.service.id === id)
  if (on === (at >= 0)) return

  if (on) {
    runtimes.splice(canonicalSlot(id), 0, { service: svc, view: makeServiceView(svc), unread: null })
  } else {
    // Không cho tắt kênh cuối: cửa sổ rỗng không có đường thoát bằng chuột.
    if (runtimes.length <= 1) return
    const rt = runtimes[at]
    // Đổi active TRƯỚC khi hủy view, không thì active trỏ vào webContents đã chết.
    if (rt.service.id === activeId) {
      activeId = (runtimes[at + 1] || runtimes[at - 1]).service.id
    }
    win.contentView.removeChildView(rt.view)
    rt.view.webContents.close()
    runtimes.splice(at, 1)
  }

  persist()
  selectId(activeId)
  buildMenu()
  layout()
  pushRailState()
  updateBadge()
}
```

`layout()` — thay dòng `const railW = services.length > 1 ? RAIL_WIDTH : 0` bằng:

```js
  const railW = railVisible(runtimes.length, railCollapsed) ? RAIL_WIDTH : 0
```

`createWindow()` — thay vòng dựng view và điều kiện dựng rail:

```js
  for (const s of services) {
    runtimes.push({ service: s, view: makeServiceView(s), unread: null })
  }

  if (services.length > 1) {
```

bằng:

```js
  prefs = loadPrefs(app.getPath('userData'))
  railCollapsed = prefs.railCollapsed
  // Chỉ dựng view cho kênh đang bật — kênh tắt không tạo view rồi hủy.
  for (const s of resolveEnabled(services, prefs)) {
    runtimes.push({ service: s, view: makeServiceView(s), unread: null })
  }

  // Rail dựng khi vũ trụ có nhiều hơn 1 kênh, còn hiện hay không thì layout() quyết —
  // vì số kênh bật đổi được lúc chạy, không thể quyết một lần lúc khởi động.
  if (services.length > 1) {
```

- [ ] **Step 4: Chạy để chắc là nó pass**

```bash
node electron/selftest.js
cd electron && ./node_modules/.bin/electron . --probe-toggle > /tmp/pt.log 2>&1; echo "exit=$?"
grep -E "^(PASS|FAIL)|assert" /tmp/pt.log
```
Expected: `exit=0`, `tất cả assert PASS` — cả 6 assert PASS. **Exit code là cổng.**

Nếu `FAIL process kênh đã tắt còn sống` liệt kê id nào → `webContents.close()` không hủy
process. Thử `rt.view.webContents.destroy()`. Nếu vẫn không chết thì **giả định cốt lõi của
thiết kế sai** — báo BLOCKED, dừng, và lùi về phương án "chỉ ẩn tile" trong `design.md`.
Không tự ý đổi thiết kế.

- [ ] **Step 5: Commit**

```bash
git add electron/main.js
git commit -m "feat(electron): bật/tắt kênh lúc chạy, tắt là hủy view"
```

---

### Task 5: Menu "Kênh" + ⌘0 ẩn rail

**Files:**
- Modify: `electron/main.js:186-213` (`buildTray`), `:215-235` (`buildMenu`)

**Interfaces:**
- Consumes: `setEnabled`, `railCollapsed`, `persist`, `railVisible`, `enabledIds`.
- Produces: `toggleRail() → void`

- [ ] **Step 1: Viết test fail trước**

Thêm vào cuối khối `--probe-toggle` (Task 4), TRƯỚC `app.isQuitting = true`:

```js
    // ⌘0 phải độc lập với quy tắc "còn 1 kênh": 3 kênh bật mà ẩn tay thì rail vẫn phải ẩn.
    // Đó là toàn bộ lý do có hai trạng thái tách rời.
    toggleRail()
    check('ẩn tay: railCollapsed', railCollapsed, true)
    check('ẩn tay: rail hiện', railVisible(runtimes.length, railCollapsed), false)
    toggleRail()
    check('hiện lại: railCollapsed', railCollapsed, false)
    check('hiện lại: rail hiện', railVisible(runtimes.length, railCollapsed), true)

    const kenh = Menu.getApplicationMenu().items.find(i => i.label === 'Kênh')
    check('có menu Kênh', !!kenh, true)
    // 4 kênh + separator + ẩn/hiện cột
    check('số item menu Kênh', kenh.submenu.items.length, services.length + 2)
    check('kênh đang tick',
      kenh.submenu.items.filter(i => i.type === 'checkbox' && i.checked).map(i => i.label).sort(),
      runtimes.map(r => r.service.title).sort())
    check('nhãn ẩn/hiện cột', kenh.submenu.items[services.length + 1].label, 'Ẩn cột kênh')
```

- [ ] **Step 2: Chạy để chắc là nó fail**

Run: `cd electron && ./node_modules/.bin/electron . --probe-toggle > /tmp/pt.log 2>&1; echo "exit=$?"; grep -E "^(PASS|FAIL)" /tmp/pt.log`
Expected: FAIL — `ReferenceError: toggleRail is not defined`, `exit` khác 0

- [ ] **Step 3: Implement tối thiểu**

Thêm sau `function setEnabled`:

```js
function toggleRail () {
  railCollapsed = !railCollapsed
  persist()
  layout()
  buildMenu()
}

/** Item bật/tắt kênh, dùng chung cho app menu và tray menu. */
function serviceToggleItems () {
  const only = runtimes.length <= 1
  return services.map(s => {
    const on = runtimes.some(r => r.service.id === s.id)
    return {
      label: s.title, type: 'checkbox', checked: on,
      // Tắt kênh cuối cùng để lại cửa sổ rỗng — disable thay vì im lặng bỏ qua, để
      // người dùng thấy được vì sao không bấm được.
      enabled: !(on && only),
      click: () => setEnabled(s.id, !on),
    }
  })
}
```

`buildMenu()` — thêm menu `Kênh` sau menu app, và ⌘0 vào menu app. Thay toàn bộ
`Menu.buildFromTemplate([...])` bằng:

```js
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    {
      label: app.getName(),
      submenu: [
        ...runtimes.map((r, i) => ({
          label: r.service.title, accelerator: `Cmd+${i + 1}`,
          click: () => selectId(r.service.id),
        })),
        { type: 'separator' },
        { label: 'Về trang chính', accelerator: 'Cmd+Shift+H', click: () => active().view.webContents.loadURL(active().service.url) },
        { label: 'Quay lại', accelerator: 'Cmd+[', click: () => { const wc = active().view.webContents; if (wc.navigationHistory.canGoBack()) wc.navigationHistory.goBack() } },
        { label: 'Tải lại', accelerator: 'Cmd+R', click: () => active().view.webContents.reload() },
        { type: 'separator' },
        { label: 'Ẩn cửa sổ', accelerator: 'Cmd+W', click: () => win.hide() },
        { label: 'Thoát', accelerator: 'Cmd+Q', click: () => { app.isQuitting = true; app.quit() } },
      ],
    },
    {
      label: 'Kênh',
      submenu: [
        ...serviceToggleItems(),
        { type: 'separator' },
        {
          label: railCollapsed ? 'Hiện cột kênh' : 'Ẩn cột kênh',
          accelerator: 'Cmd+0',
          enabled: runtimes.length > 1,
          click: toggleRail,
        },
      ],
    },
    { label: 'Sửa', submenu: [
      { role: 'undo' }, { role: 'redo' }, { type: 'separator' },
      { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' },
    ] },
  ]))
```

`buildTray()` — trong `rebuild()`, thêm mục bật/tắt kênh sau danh sách radio. Thay:

```js
      { type: 'separator' },
      { label: 'Hiện/ẩn cửa sổ', accelerator: 'Cmd+Shift+M', click: toggleWindow },
```

bằng:

```js
      { type: 'separator' },
      { label: 'Kênh', submenu: serviceToggleItems() },
      { label: railCollapsed ? 'Hiện cột kênh' : 'Ẩn cột kênh', click: toggleRail },
      { type: 'separator' },
      { label: 'Hiện/ẩn cửa sổ', accelerator: 'Cmd+Shift+M', click: toggleWindow },
```

- [ ] **Step 4: Chạy để chắc là nó pass**

```bash
node electron/selftest.js
cd electron && ./node_modules/.bin/electron . --probe-toggle > /tmp/pt.log 2>&1; echo "exit=$?"
grep -E "^(PASS|FAIL)|assert" /tmp/pt.log
```
Expected: `exit=0`, `tất cả assert PASS` — 14 assert PASS (6 của Task 4 + 8 của Task 5)

- [ ] **Step 5: Commit**

```bash
git add electron/main.js
git commit -m "feat(electron): menu Kênh bật/tắt và Cmd+0 ẩn cột kênh"
```

---

### Task 6: Chứng minh trạng thái sống qua lần chạy sau

**Files:**
- Modify: `electron/main.js` (thêm `--probe-prefs`)

**Interfaces:**
- Consumes: toàn bộ Task 1-5.

- [ ] **Step 1: Viết test fail trước**

Thêm mode đọc trạng thái đã lưu, sau khối `--probe-toggle`:

```js
  if (process.argv.includes('--probe-prefs')) setTimeout(() => {
    // Kỳ vọng đọc từ prefs.json mà --probe-toggle vừa ghi, KHÔNG hardcode: test này chứng
    // minh loadPrefs được nối vào createWindow, nên phải so với file trên đĩa.
    const saved = loadPrefs(app.getPath('userData'))
    check('kênh bật khớp prefs.json', enabledIds(), saved.enabled)
    check('railCollapsed khớp prefs.json', railCollapsed, saved.railCollapsed)
    check('không dùng cả vũ trụ', enabledIds().length < services.length, true)
    probeExit()
  }, 15000)
```

- [ ] **Step 2: Chạy để chắc là nó fail**

Xoá trạng thái rồi chạy ngay `--probe-prefs`, chưa qua `--probe-toggle`:

```bash
rm -f "$HOME/Library/Application Support/FBMessElectron/prefs.json"
cd electron && ./node_modules/.bin/electron . --probe-prefs > /tmp/pp.log 2>&1; echo "exit=$?"
grep -E "^(PASS|FAIL)" /tmp/pp.log
```
Expected: FAIL — `FAIL không dùng cả vũ trụ`, vì chưa có prefs.json nên app bật cả 4 kênh.
Đúng như thiết kế, nhưng chưa chứng minh được đường persist.

- [ ] **Step 3: Tạo trạng thái khác mặc định rồi đọc lại**

`--probe-toggle` (Task 4-5) kết thúc với 3 kênh bật và gọi `persist()` trước `app.quit()`.
`savePrefs` đồng bộ (`writeFileSync` + `renameSync`) nên gọi xong là chắc chắn đã trên đĩa.

```bash
cd electron
./node_modules/.bin/electron . --probe-toggle 2>&1 | grep "thứ tự sau"
cat "$HOME/Library/Application Support/FBMessElectron/prefs.json"
```
Expected: `prefs.json` chứa đúng 3 id đó, không phải 4

- [ ] **Step 4: Chạy để chắc là nó pass**

```bash
cd electron && ./node_modules/.bin/electron . --probe-prefs > /tmp/pp.log 2>&1; echo "exit=$?"
grep -E "^(PASS|FAIL)|assert" /tmp/pp.log
```
Expected: `exit=0`, cả 3 assert PASS. Đây là chỗ DUY NHẤT chứng minh `loadPrefs` thật sự được
nối vào `createWindow` — quên nối thì app vẫn chạy bình thường với đủ 4 kênh, không lỗi nào nổi
lên, và chỉ assert `không dùng cả vũ trụ` bắt được.

- [ ] **Step 5: Đưa trạng thái về mặc định rồi commit**

```bash
rm -f "$HOME/Library/Application Support/FBMessElectron/prefs.json"
git add electron/main.js
git commit -m "test(electron): chứng minh lựa chọn kênh sống qua lần chạy sau"
```

---

### Task 7: Rail 1/2/4 tile ở cả hai theme + docs

**Files:**
- Modify: `electron/preview-rail.js`, `electron/README.md`, `README.md`

- [ ] **Step 1: Viết test fail trước**

`electron/preview-rail.js` hiện chỉ render đủ 4 tile. Sửa để render cả ba trạng thái —
rail 1 tile là trạng thái mới mà thiết kế nói phải bị ẩn, nên phải xem nó trông thế nào nếu
lỡ hiện:

```js
const state = (n) => ({
  active: 0,
  items: SERVICES.slice(0, n).map((s, i) => ({
    id: s.id, title: s.title, tint: s.tint,
    unread: i === 1 ? '3' : (i === 2 ? '12' : null),
  })),
})

app.whenReady().then(async () => {
  const w = new BrowserWindow({
    width: 68 * ZOOM, height: 210 * ZOOM, show: false,
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
```

- [ ] **Step 2: Chạy để chắc là nó fail**

Run: `cd electron && ./node_modules/.bin/electron preview-rail.js /tmp/rail && ls /tmp/rail-*.png | wc -l`
Expected: FAIL trước khi sửa — chỉ ra 2 file thay vì 6

- [ ] **Step 3: Xem 6 ảnh, xác nhận không lỗi hiển thị**

Mở từng ảnh. Kiểm: tile không dính nhau, badge không bị cắt, glyph trắng rõ trên cả hai
theme, và rail 1 tile không có gì lạ.

- [ ] **Step 4: Cập nhật docs**

`electron/README.md` — thêm vào bảng "Dùng":

```markdown
| `⌘0` | Ẩn/hiện cột kênh. Nhớ qua lần chạy sau |
| Menu **Kênh** | Bật/tắt từng kênh. Tắt là hủy view — **kênh tắt không báo tin nữa** |
```

Thêm mục mới sau "Session tách riêng với bản Swift":

```markdown
## Bật/tắt kênh

Menu **Kênh** (thanh menu trên) và menu tray đều bật/tắt được từng kênh. Tắt một kênh là
`webContents.close()` — process renderer của nó chết, RAM trả về OS. Đánh đổi: **kênh tắt
không báo tin nữa** và bật lại phải load lại.

Vì vậy ⌘0 tách rời: nó chỉ ẩn cột, cả 4 kênh vẫn sống và vẫn báo tin.

Không cho tắt kênh cuối cùng — cửa sổ rỗng không có đường thoát bằng chuột. Menu item bị
disable, không im lặng bỏ qua.

Trạng thái ở `~/Library/Application Support/FBMessElectron/prefs.json`. File hỏng hoặc thiếu
→ về mặc định (bật tất cả), không crash. `FBMESS_SERVICES` vẫn là vũ trụ kênh khả dụng;
prefs chỉ bật/tắt trong đó.

Kiểm không cần nhìn màn hình:

```bash
./FBMessElectron.app/Contents/MacOS/FBMessElectron --probe-toggle   # tắt 3 kênh, chứng minh process chết
./FBMessElectron.app/Contents/MacOS/FBMessElectron --probe-prefs    # in trạng thái đã lưu
```
```

`electron/README.md` mục "File" — thêm hai dòng:

```
  prefs.js            đọc/ghi prefs.json (kênh nào bật, rail có ẩn tay)
```

`README.md` gốc, bảng khác biệt Swift ↔ Electron — sửa dòng `Thu gọn rail (⌘0)` từ
`chưa có` thành `có`.

- [ ] **Step 5: Chạy cổng docs rồi commit**

```bash
./docs-check.sh
git add electron/preview-rail.js electron/README.md README.md
git commit -m "docs(electron): menu Kênh, Cmd+0 và preview rail 1/2/4 tile"
```

---

### Task 8: Build, verify trên bundle, phát hành

**Files:** không sửa file nào — đây là cổng cuối.

- [ ] **Step 1: Build**

Run: `./build-electron.sh`
Expected: `selftest OK`, in `build <N>` và commit sạch (không `DIRTY`)

- [ ] **Step 2: Verify trên bundle đã package, không phải từ source**

```bash
./FBMessElectron.app/Contents/MacOS/FBMessElectron --probe
./FBMessElectron.app/Contents/MacOS/FBMessElectron --probe-toggle
```
Expected: `rail tiles` khớp số kênh bật, `process chưa chết: không (đúng)`, cả hai case link
policy đúng, `tray icon: {"width":20,"height":20} template=true`

Bundle mới có thêm `prefs.js` trong asar — nếu thiếu thì `--probe` sập ngay ở
`require('./prefs')`. Đó là lý do phải chạy trên bundle chứ không chỉ từ source.

- [ ] **Step 3: Phát hành**

Run: `./release-electron.sh`
Expected: tạo `electron-b<N>` với asset `.tar.xz`

- [ ] **Step 4: Đo trên máy dùng**

Trên MacBook: `./install-electron.sh`, login, tắt 2 kênh, rồi `./measure.sh FBMessElectron`.
Expected: footprint giảm theo số kênh tắt. Đây là phép đo trả lời câu duy nhất mà máy build
không trả lời được: **tắt kênh có thật sự nhẹ máy hay không.**
