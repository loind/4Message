# FB Mess (Electron) — hướng dẫn build

Bản dùng engine Blink của cùng app: Messenger + Instagram DM + Threads DM trong một cửa sổ,
rail chọn kênh, ẩn chrome không liên quan tới chat, link ngoài surface mở browser, tray
resident, ⌘⇧M bật/tắt cửa sổ, badge unread ở Dock + menu bar.

Lý do tồn tại: WKWebView bùng 60–100% CPU theo đợt làm nội dung đóng băng — `sample` cho
thấy thời gian nằm hết ở layout của WebCore, không phải CSS của app và không phải memory
pressure. Đo cùng trang Messenger, Blink trung bình 0.58% qua 14 giờ. Chi tiết:
`plans/2026-08-03-engine-swap/`.

## Yêu cầu

| Thứ | Vì sao | Kiểm |
| --- | --- | --- |
| `node` + `npm` | Chạy script build, `@electron/packager` | `node -v` |
| Mạng | Lần đầu tải Electron binary + packager | |
| `Resources/AppIcon.icns` | Icon bundle. Đã commit trong repo | `ls Resources/AppIcon.icns` |

Không cần Xcode. Chỉ khi `Resources/AppIcon.icns` bị mất thì `build-electron.sh` gọi
`make-icon.sh`, lúc đó mới cần `swift`.

## Build

```bash
./build-electron.sh          # chạy ở GỐC repo, không phải trong electron/
```

Ra hai thứ ở gốc repo:

- `FBMessElectron.app` (276 MB) — chạy được ngay trên máy build
- `FBMessElectron-arm64.zip` (129 MB) — để copy sang máy khác

```bash
./build-electron.sh --run                    # build xong mở luôn
FBMESS_ARCH=universal ./build-electron.sh    # kèm slice x86, nếu cần chạy trên Intel
NPM_CACHE=/tmp/mycache ./build-electron.sh   # đổi npm cache
```

Mặc định `arm64` thôi. Universal gấp đôi dung lượng (488 MB) cho một slice x86 không ai chạy.

### Script làm gì, theo thứ tự

| Bước | Việc | Vì sao đúng thứ tự này |
| --- | --- | --- |
| 1 | Sinh `electron/build-info.json` (commit + dirty + timestamp) | Phải TRƯỚC khi package, không thì bundle mang info của lần build cũ |
| 2 | `npm install --save-dev electron` nếu thiếu | `--save-dev`: là devDependency thì packager prune khỏi bundle; là dependency thì nó gói cả runtime 250 MB vào `.app` rồi app tự load Electron trong Electron |
| 3 | `node electron/selftest.js` | Cổng build. Fail là dừng, không package ra bundle sai |
| 4 | `@electron/packager` → `.app` | |
| 5 | `codesign --sign -` (ad-hoc) | Không sign thì Gatekeeper chặn và entitlement (notification) im lặng fail |
| 6 | `ditto` → `.zip` | `--sequesterRsrc --keepParent` giữ nguyên metadata bundle; `zip` thường làm hỏng symlink trong framework |
| 7 | In `--version` | Xác nhận bundle vừa ra đúng commit |

`dirty` tính bằng `git status --porcelain`, không phải `git diff --quiet HEAD` — cái sau bỏ
qua file untracked nên báo clean khi cây đang có file mới.

## Cài lên máy khác

```bash
# trên máy đích, sau khi copy zip sang
unzip FBMessElectron-arm64.zip
mv FBMessElectron.app /Applications/
xattr -dr com.apple.quarantine /Applications/FBMessElectron.app
open /Applications/FBMessElectron.app
```

Bỏ quarantine vì bundle chỉ ad-hoc sign (không có Developer ID, không notarize). Không chạy
lệnh đó thì lần đầu mở macOS chặn — vẫn mở được qua **Cài đặt Hệ thống → Bảo mật → Mở bằng
mọi cách**, chỉ là thêm bước.

## Kiểm tra

Bốn cách, không cái nào cần nhìn màn hình:

```bash
node electron/selftest.js                                     # logic surface/unread thuần
./FBMessElectron.app/Contents/MacOS/FBMessElectron --version   # commit + electron + chromium
./FBMessElectron.app/Contents/MacOS/FBMessElectron --probe     # wiring thật, cần mạng
cd electron && ./node_modules/.bin/electron preview-rail.js /tmp/rail   # rail ra PNG
```

`--probe` in ra số tile của rail, URL + title + trạng thái login của từng kênh, và hai case
link policy (link ngoài phải ra browser, link surface phải giữ trong app). Tự thoát sau ~25s.

`preview-rail.js` sinh `/tmp/rail-light.png` + `/tmp/rail-dark.png` từ chính `rail.html`.
Soi **cả hai** theme: bug rail chỉ hiện ở một theme đã xảy ra rồi (`docs/ui-discipline.md`).

Cả hai công cụ này cần thiết vì máy build không có GUI session — `screencapture` ở đó chỉ ra
desktop trống, không soi bằng mắt được.

## Env

| Biến | Tác dụng |
| --- | --- |
| `FBMESS_SERVICES=messenger,instagram` | Chọn và sắp thứ tự kênh. Id lạ bị bỏ, trùng bị loại |
| `FBMESS_KEEP_FB_CHROME=1` | Không inject CSS ẩn chrome — chạy A/B khi rule nghi phá layout |
| `FBMESS_ARCH` | `arm64` (mặc định) hoặc `universal`. Chỉ ảnh hưởng lúc build |
| `NPM_CACHE` | Thư mục npm cache. Chỉ ảnh hưởng lúc build |

## Dùng

| Thao tác | Kết quả |
| --- | --- |
| Click tile trên rail / ⌘1 ⌘2 ⌘3 | Đổi kênh |
| `⌘⇧M` | Hiện/ẩn cửa sổ (global) |
| `⌘⇧H` | Về trang chính của kênh đang xem |
| `⌘[` | Quay lại |
| `⌘R` | Tải lại |
| `⌘W` / nút đóng | **Ẩn** cửa sổ, app vẫn chạy → lần sau mở tức thì |
| `⌘Q` | Thoát thật |
| Badge Dock + số cạnh icon menu bar | Tổng tin chưa đọc của cả ba kênh |

## Session tách riêng với bản Swift

Store ở `~/Library/Application Support/FBMessElectron/`, không phải `~/Library/WebKit/`.
Cookie KHÔNG chuyển sang được → phải login lại cả ba kênh. Mỗi lần login là một device
E2EE mới, nên hội thoại mã hoá đầu-cuối sẽ không có lịch sử cũ ở app này.

Đổi `productName` trong `electron/package.json` cũng đổi đường dẫn store → mất session.
Đừng đổi sau khi đã login.

## Khác biệt so với bản Swift

| Việc | Swift | Electron |
| --- | --- | --- |
| Web Notification | shim JS → `UNUserNotificationCenter` | Blink hiện native, chỉ cần cấp quyền |
| Chặn link | `navigationType == .linkActivated` | click capture trong preload |
| Hotkey | Carbon `RegisterEventHotKey` | `globalShortcut` |
| Thu gọn rail (⌘0) | có | chưa có |
| `FBMESS_TOPOLOGY` / `MODE` / `UA` / `WINDOW` | có (knob để đo) | không port — đều đã đo ra kết quả âm |

**Chặn link phải ở tầng CLICK, không phải navigation.** `will-navigate` không phân biệt được
click với redirect, mà luồng login của Meta đi qua `login.php` / `accounts/login` — internal
nhưng NGOÀI surface — nên chặn theo navigation là chặn luôn login. Bản Swift có
`navigationType == .linkActivated`; Electron không có field tương đương nên preload bắt click
ở capture phase.

## File

```
electron/
  main.js             process chính: window, rail, view mỗi kênh, tray, menu, link policy
  services.js         mirror của Sources/Messenger/Services.swift — url, surface, hideRules
  rail.html           rail: tile màu bệt + glyph SVG đơn sắc
  rail-preload.js     bridge click tile → main
  service-preload.js  bắt click link, quyết định giữ trong app hay mở browser
  selftest.js         cổng build — logic surface/unread, không cần GUI/mạng
  preview-rail.js     render rail.html ra PNG (light + dark)
  build-info.json     sinh lúc build, không commit
```

`services.js` giữ giống `Services.swift` để hai bản so sánh được và để **bốn bẫy selector**
không phải học lại — đọc comment đầu file trước khi sửa selector.
