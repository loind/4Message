# 4Message — hướng dẫn build

Messenger, Instagram DM, Threads và Zalo trong một cửa sổ,
rail chọn kênh, ẩn chrome không liên quan tới chat, link ngoài surface mở browser, tray
resident, ⌘⇧M bật/tắt cửa sổ, badge unread ở Dock + menu bar.

Lý do tồn tại: WKWebView bùng 60–100% CPU theo đợt làm nội dung đóng băng — `sample` cho
thấy thời gian nằm hết ở layout của WebCore, không phải CSS của app và không phải memory
pressure. Đo cùng trang Messenger, Blink trung bình 0.91% qua 25.78 giờ. Chi tiết:
`plans/2026-08-03-engine-swap/` và `plans/2026-08-04-engine-decision/`.

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

- `4Message.app` (230 MB) — chạy được ngay trên máy build

Đóng gói để phát hành: `./build-dmg.sh` → `4Message-arm64.dmg` (112 MB), có shortcut
`Applications` để kéo vào cài.

```bash
./build-electron.sh --run                    # build xong mở luôn
FBMESS_ARCH=universal ./build-electron.sh    # kèm slice x86, nếu cần chạy trên Intel
NPM_CACHE=/tmp/mycache ./build-electron.sh   # đổi npm cache
```

Mặc định `arm64` thôi. Universal gấp đôi dung lượng cho một slice x86 không ai chạy.

### Dung lượng nằm ở đâu

Code của app là **52 KB** (`app.asar`). Toàn bộ phần còn lại là runtime Electron:

| Thành phần | |
| --- | --- |
| Electron Framework (nhị phân Chromium) | 182.6 MB |
| `libvk_swiftshader` + `libGLESv2` + `libffmpeg` | 24.0 MB |
| Resources (locale pak) | 46.4 MB → **1.3 MB** sau khi cắt |
| Code của app (`app.asar`) | 0.05 MB |

Nên **dọn code app không giảm được dung lượng** — nó chiếm 0.02%. Hai chỗ cắt thật, đã làm:

| Việc | Artifact |
| --- | --- |
| Gốc (zip, đủ 220 locale) | 114.1 MB |
| Cắt 218 locale, vẫn zip | 102.3 MB |
| Cắt locale + tar.xz | 70.4 MB |
| **Hiện tại: DMG** (zlib, có shortcut Applications) | **112 MB** |

DMG to hơn tar.xz 42 MB vì `hdiutil` nén zlib chứ không lzma. Chấp nhận để chỉ còn một
artifact và cài đúng kiểu macOS — người dùng kéo app vào `Applications` thay vì giải nén.

`libvk_swiftshader` 15.8 MB là software renderer fallback của Vulkan — cắt được nhưng mất
đường lùi khi GPU driver lỗi. Không cắt.

### Script làm gì, theo thứ tự

| Bước | Việc | Vì sao đúng thứ tự này |
| --- | --- | --- |
| 1 | Sinh `electron/build-info.json` (commit + dirty + timestamp) | Phải TRƯỚC khi package, không thì bundle mang info của lần build cũ |
| 2 | `npm install --save-dev electron` nếu thiếu | `--save-dev`: là devDependency thì packager prune khỏi bundle; là dependency thì nó gói cả runtime 250 MB vào `.app` rồi app tự load Electron trong Electron |
| 3 | `node electron/selftest.js` | Cổng build. Fail là dừng, không package ra bundle sai |
| 4 | `@electron/packager` → `.app` | |
| 5 | Xoá 218 locale pak của Chromium | 45 MB cho thứ tiếng không dùng. PHẢI trước codesign — sửa bundle sau khi sign làm signature vỡ |
| 6 | `codesign --sign -` (ad-hoc) | Không sign thì Gatekeeper chặn và entitlement (notification) im lặng fail |
| 7 | In `--version` | Xác nhận bundle vừa ra đúng commit |

`dirty` tính bằng `git status --porcelain`, không phải `git diff --quiet HEAD` — cái sau bỏ
qua file untracked nên báo clean khi cây đang có file mới.

## Cài lên máy khác

Qua GitHub Release — máy đích không cần `node`, chỉ cần `gh`:

```bash
# máy build
./release-electron.sh        # build + tạo release tag electron-b<số build>

# máy dùng
./install-electron.sh        # tải release mới nhất, quit app cũ, cài, mở lại
```

Số build = `git rev-list --count HEAD`: đơn điệu tăng và tra được về đúng một commit. Một
commit = một release; release lại cùng commit bị chặn.

**Không commit DMG vào repo.** Nó 112 MB mà GitHub chặn cứng push file > 100 MB, và mỗi
bản build sẽ nằm vĩnh viễn trong git history. Release asset không vào history, giới hạn 2 GB.

Artifact là `.dmg`. `install-electron.sh` mount nó vào thư mục tạm (`-mountpoint` +
`-nobrowse` để không đụng `/Volumes` và không hiện lên Finder giữa lúc cài), verify
signature, copy app sang `/Applications`, rồi detach.

**Tải bằng `gh`, không bằng browser.** File browser tải bị gắn `com.apple.quarantine` nên
Gatekeeper chặn (bundle chỉ ad-hoc sign, không notarize) và phải
`xattr -dr com.apple.quarantine` mới mở được. `gh` chỉ gắn `com.apple.provenance` — không
phải cờ Gatekeeper. Đã kiểm chứng bằng một lần tải thật 1.02 MB.

### Cách khác: build ngay trên máy dùng

Nếu máy dùng có `node` thì khỏi cần tải 112 MB:

```bash
git pull --ff-only && ./build-electron.sh
```

Build lần hai hết ~13s (M4), cache Electron 352 MB một lần. App build tại máy cũng không bị
quarantine. Đánh đổi: máy dùng phải có toolchain.

## Kiểm tra

Không cái nào cần nhìn màn hình:

```bash
node electron/selftest.js                                # logic thuần, là cổng build
./4Message.app/Contents/MacOS/4Message --version         # commit + electron + chromium
./4Message.app/Contents/MacOS/4Message --probe           # rail, link policy, tray icon
./4Message.app/Contents/MacOS/4Message --probe-toggle    # bật/tắt kênh, process chết thật
./4Message.app/Contents/MacOS/4Message --probe-prefs     # trạng thái đọc lại được
cd electron && ./node_modules/.bin/electron preview-rail.js /tmp/rail   # rail ra PNG
```

**Thứ tự bắt buộc** với ba probe mode: `--probe` → `--probe-toggle` → `--probe-prefs`, liên
tiếp. `--probe` và `--probe-toggle` đều reset `prefs.json`; chèn `--probe` vào giữa hai lệnh
cuối làm `--probe-prefs` fail oan, đọc y hệt một lỗi persistence thật.

Exit code là cổng, không phải dòng log. Mọi probe đi qua `runProbe` nên throw cũng thành
`FAIL probe throw` + exit 1 chứ không treo.

`--probe` in ra số tile của rail, URL + title + trạng thái login của từng kênh, và hai case
link policy (link ngoài phải ra browser, link surface phải giữ trong app). Tự thoát sau ~25s.

`preview-rail.js` sinh 6 file `/tmp/rail-{light,dark}-{1,2,4}.png` từ chính `rail.html` —
số kênh bật đổi được lúc chạy (menu Kênh) nên rail 1 và 2 tile là trạng thái thật, không chỉ
4. Soi **cả hai** theme: bug rail chỉ hiện ở một theme đã xảy ra rồi (`docs/ui-discipline.md`).

Icon menu bar sinh lại bằng `./node_modules/.bin/electron make-tray-icon.js`. Nó là
**template image** (đen + alpha) nên macOS tự đảo màu theo menu bar sáng/tối — đặt màu cứng
là sai ở một trong hai theme. `--probe` in cỡ icon và cờ template để xác nhận nó vào được
asar; thiếu file thì `createFromPath` trả ảnh rỗng và Tray im lặng hiện trống.

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
| Click tile trên rail / ⌘1–⌘4 | Đổi kênh |
| `⌘0` | Ẩn/hiện cột kênh. Nhớ qua lần chạy sau |
| Menu **Kênh** | Bật/tắt từng kênh. Tắt là hủy view — **kênh tắt không báo tin nữa** |
| `⌘⇧M` | Hiện/ẩn cửa sổ (global) |
| `⌘⇧H` | Về trang chính của kênh đang xem |
| `⌘[` | Quay lại |
| `⌘R` | Tải lại |
| `⌘W` / nút đóng | **Ẩn** cửa sổ, app vẫn chạy → lần sau mở tức thì |
| `⌘Q` | Thoát thật |
| Badge Dock + số cạnh icon menu bar | Tổng tin chưa đọc của các kênh đang bật |

## Session

Store ở `~/Library/Application Support/4Message/`. Mỗi kênh phải đăng nhập một lần. Mỗi lần login là một device
E2EE mới, nên hội thoại mã hoá đầu-cuối sẽ không có lịch sử cũ ở app này.

Đổi `productName` trong `electron/package.json` cũng đổi đường dẫn store → mất session.
Đừng đổi sau khi đã login.

## Bật/tắt kênh

Menu **Kênh** (thanh menu trên) và menu tray đều bật/tắt được từng kênh. Tắt một kênh là
`webContents.close()` — process renderer của nó chết, RAM trả về OS. Đánh đổi: **kênh tắt
không báo tin nữa** và bật lại phải load lại.

Vì vậy ⌘0 tách rời: nó chỉ ẩn cột, cả 4 kênh vẫn sống và vẫn báo tin.

Không cho tắt kênh cuối cùng — cửa sổ rỗng không có đường thoát bằng chuột. Menu item bị
disable, không im lặng bỏ qua.

Trạng thái ở `~/Library/Application Support/4Message/prefs.json`. File hỏng hoặc thiếu
→ về mặc định (bật tất cả), không crash. `FBMESS_SERVICES` vẫn là vũ trụ kênh khả dụng;
prefs chỉ bật/tắt trong đó.

Kiểm bằng `--probe-toggle` và `--probe-prefs` — xem mục **Kiểm tra** ở trên, kèm ràng buộc
thứ tự chạy.

## File

```
electron/
  main.js             process chính: window, rail, view mỗi kênh, tray, menu, link policy
  prefs.js            đọc/ghi prefs.json (kênh nào bật, rail có ẩn tay)
  services.js         nguồn duy nhất định nghĩa kênh — url, surface, hideRules
  rail.html           rail: tile màu bệt + glyph SVG đơn sắc
  rail-preload.js     bridge click tile → main
  service-preload.js  bắt click link, quyết định giữ trong app hay mở browser
  selftest.js         cổng build — logic surface/unread, không cần GUI/mạng
  preview-rail.js     render rail.html ra PNG, 1/2/4 tile × light/dark
  make-tray-icon.js   sinh tray.png + tray@2x.png (template image cho menu bar)
  tray.png            icon menu bar 20×20, đen + alpha. tray@2x.png cho Retina
  build-info.json     sinh lúc build, không commit
```

`services.js` giữ giống `Services.swift` để hai bản so sánh được và để **bốn bẫy selector**
không phải học lại — đọc comment đầu file trước khi sửa selector.
