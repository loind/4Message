# 4Message

Client chat cho macOS: **Messenger, Instagram DM, Threads, Zalo** trong một cửa sổ. Electron
(Blink), mỗi kênh một `WebContentsView`. Thay thế Franz: nhẹ hơn, mở lại tức thì, không
quảng cáo Pro.

Không reverse-engineer protocol của Meta — dùng đúng web app chính thức, nên không có rủi ro
khoá tài khoản. Đánh đổi: memory là của web app, không sửa được từ phía shell.

| Tài liệu | Nội dung |
| --- | --- |
| `electron/README.md` | **Hướng dẫn build đầy đủ** — yêu cầu, từng bước, cách verify |
| `docs/ui-discipline.md` | Kỷ luật soi DOM — bốn bẫy selector đã mắc, vẫn còn hiệu lực |
| `docs/perf-process.md` | Quy trình đo hiệu năng + các hướng tối ưu đã thử và thất bại |
| `docs/decisions/` | Quyết định kiến trúc kèm số liệu |
| `plans/` | Brainstorm và kế hoạch từng tính năng, kèm số đo tại thời điểm quyết |
| `plans/2026-08-24-copy-image/design.md` | Thiết kế menu chuột phải trên ảnh, kèm số đo |

## Build

```bash
./build-electron.sh          # → 4Message.app
./build-dmg.sh               # → 4Message-arm64.dmg (bản để phát hành)
./build-electron.sh --run
```

Chi tiết từng bước và lý do thứ tự: `electron/README.md`.

## Phát hành và cài

```bash
./release-electron.sh        # máy build: tạo GitHub Release electron-b<số build>
./install-electron.sh        # máy dùng: tải release mới nhất, cài, mở lại
```

`release-electron.sh` build cả app và DMG rồi đẩy **DMG** lên Release — đó là asset duy
nhất. `install-electron.sh` tải DMG về, mount, copy app sang `/Applications`, unmount.

Máy dùng chỉ cần `gh` đã login — không cần `node`. Nếu có `node` thì
`git pull && ./build-electron.sh` nhanh hơn và không phải tải 112 MB.

## DMG

```bash
./build-dmg.sh               # → 4Message-arm64.dmg
./build-dmg.sh --keep        # dùng .app đang có, không build lại
```

Mở DMG ra thấy app cạnh shortcut `Applications`, kéo sang là cài — cách cài quen thuộc trên
macOS. Đây là **asset duy nhất** của mỗi Release.

Đánh đổi đã chấp nhận: DMG 112 MB so với `.tar.xz` 80 MB trước đây, vì `hdiutil` nén zlib
chứ không phải lzma. Mỗi lần cài tải thêm ~32 MB, đổi lại chỉ còn một artifact và cài đúng
kiểu macOS.

Bước sắp xếp vị trí icon và ảnh nền trong DMG cần **GUI session thật** (Finder automation).
Máy build headless sẽ bỏ qua bước đó và vẫn ra DMG dùng được, chỉ thiếu phần trang trí.
Đặt `build-icon/dmg-bg.png` nếu muốn có ảnh nền.

## Vì sao vẫn bị hỏi "Open Anyway", và cần gì để hết

Gatekeeper chỉ chặn file có cờ `com.apple.quarantine` — cờ đó do **browser** gắn khi tải.

- `install-electron.sh` tải bằng `gh` → **không** có quarantine → app mở thẳng, không bị hỏi.
- Tải bằng browser (kể cả DMG) → có quarantine → bị hỏi một lần.

Dialog trên macOS mới **không** có nút "Open Anyway" — nó chỉ cho *Move to Trash* hoặc
*Done*, nên phải vào System Settings → Privacy & Security, hoặc bỏ cờ bằng lệnh.

Bỏ cờ ở **DMG** là đủ — đã kiểm: app kéo ra khỏi DMG sau đó cũng không có cờ:

```bash
xattr -dr com.apple.quarantine ~/Downloads/4Message-arm64.dmg
```

Nếu đã copy app ra rồi mới nhớ, thì bỏ trên app:

```bash
xattr -dr com.apple.quarantine /Applications/4Message.app
```

Lưu ý khi tự kiểm: `spctl -a` trả `rejected` **kể cả sau khi đã bỏ cờ quarantine** — nó đánh
giá signature/notarization, không đánh giá "có mở được không". Gatekeeper chỉ cưỡng chế trên
file **có** cờ quarantine. Đừng dùng `spctl` để kết luận app mở được hay không.

Muốn **không bao giờ** bị hỏi thì phải ký bằng Developer ID rồi notarize, và điều đó bắt
buộc có Apple Developer Program **$99/năm**:

1. Certificate *Developer ID Application* (hiện repo này ký ad-hoc, `spctl` trả `rejected`)
2. Ký với hardened runtime + secure timestamp
3. `notarytool submit` rồi `stapler staple`

Ký ad-hoc không bao giờ qua được Gatekeeper — đây là điều kiện của Apple, không phải thiếu
sót cấu hình. `notarytool` và `stapler` đã có sẵn trên máy (Command Line Tools), nên khi có
cert thì chỉ cần thêm bước vào `release-electron.sh`.

## Dùng

| Thao tác | Kết quả |
| --- | --- |
| Click tile trên rail / `⌘1`–`⌘4` | Đổi kênh |
| Menu **Kênh** (thanh menu + tray) | Bật/tắt từng kênh |
| `⌘0` | Ẩn/hiện cột kênh. Nhớ qua lần chạy sau |
| `⌘⇧M` | Hiện/ẩn cửa sổ (global, chạy được khi app đang ẩn) |
| `⌘⇧H` | Về trang chính của kênh đang xem |
| `⌘[` | Quay lại |
| `⌘R` | Tải lại |
| `⌘W` / nút đóng | **Ẩn** cửa sổ, app vẫn chạy → lần sau mở tức thì |
| `⌘Q` | Thoát thật |
| Chuột phải vào ảnh | Menu **Copy ảnh** / **Lưu ảnh…**. Lưu thì hiện hộp thoại chọn nơi lưu, mặc định `~/Downloads` |
| Badge Dock + số cạnh icon menu bar | Tổng tin chưa đọc của các kênh đang bật |

Đăng nhập một lần, session lưu ở `~/Library/Application Support/4Message/`.

## Copy / lưu ảnh

Electron **không** tự dựng context menu như Chrome — nó chỉ phát event rồi để app quyết. App
dựng menu 2 mục khi có ảnh dưới con trỏ; chỗ không phải ảnh thì không hiện gì, trang tự xử.

Ảnh trong Messenger/Instagram/Threads thường bị element khác **phủ lên**, làm Chromium trả
`hasImageContents = false` và không nhận ra đó là ảnh. App xử lý ca đó bằng cách dò
`elementsFromPoint` tìm `<img>`, rồi lúc copy thì tạm tắt `pointer-events` của lớp phủ để
hit-test của `copyImageAt` chạm được tới ảnh.

Vì sao không tự tải bytes ảnh về rồi ghi clipboard — hai đường đó đều đã đo và đều chết:

| Đường | Vì sao chết |
| --- | --- |
| `net.fetch` + `nativeImage.createFromBuffer` | `nativeImage` **không decode webp/gif**, mà Meta serve webp là chính |
| Vẽ `<img>` ra canvas rồi `toDataURL` | Canvas bị taint vì ảnh CDN không có CORS header → `SecurityError` |

Toàn bộ số đo: `plans/2026-08-24-copy-image/design.md`.

## Bật/tắt kênh

Tắt một kênh là `webContents.close()` — process renderer chết, RAM trả về OS. Đã chứng minh
bằng `process.kill(pid, 0)` chứ không bằng đo footprint: bmalloc trả page cho OS rất chậm nên
footprint từng làm số liệu vô nghĩa.

**Đánh đổi: kênh tắt không báo tin nữa**, và bật lại phải load lại. Vì vậy `⌘0` tách rời —
nó chỉ ẩn cột, cả bốn kênh vẫn sống và vẫn báo tin.

Không cho tắt kênh cuối cùng: cửa sổ rỗng không có đường thoát bằng chuột. Menu item bị
disable chứ không im lặng bỏ qua.

Trạng thái ở `prefs.json` trong thư mục session. File hỏng hoặc thiếu → về mặc định (bật
tất cả), không crash.

## Env

| Biến | Tác dụng |
| --- | --- |
| `FBMESS_SERVICES` | Chọn và sắp thứ tự kênh, ví dụ `messenger,instagram`. Id lạ bị bỏ |
| `FBMESS_KEEP_FB_CHROME` | `1` = không inject CSS ẩn chrome. Dùng để A/B khi nghi rule phá layout |
| `FBMESS_ARCH` | `arm64` (mặc định) hoặc `universal`. Chỉ ảnh hưởng lúc build |
| `NPM_CACHE` | Thư mục npm cache. Chỉ ảnh hưởng lúc build |

## Ẩn chrome không liên quan tới chat

Rule nằm ở `Service.hideRules` trong `electron/services.js`, riêng từng kênh vì DOM các site
khác nhau hoàn toàn. **Đọc comment đầu file trước khi sửa selector** — nó ghi bốn bẫy đã mắc,
và cả bốn vẫn còn hiệu lực:

1. `[role="navigation"]` trên facebook.com có 3 vùng, một trong đó là **thread list**.
2. `[role="navigation"]` trên instagram.com **chính là** panel danh sách hội thoại.
3. `input[role="combobox"]` khớp cả ô `Search Messenger` của chính Messenger.
4. `[aria-label*="Facebook" i]` khớp cả **một tin nhắn** — nội dung tin cũng vào aria-label.

Vì vậy ưu tiên nhận theo `href` (độc lập ngôn ngữ và tài khoản); không có href thì dùng
aria-label **khớp chính xác** — khớp chính xác fail-safe, site đổi label thì không ẩn được
(vô hại) chứ không ẩn nhầm thứ đang cần.

**Ẩn CSS không giảm memory** — DOM node vẫn tồn tại, React vẫn render và diff. Lợi ích thật
là chặn lỡ tay click vào Reels/Explore/Marketplace, những surface load rất nặng.

Self-check 2 mốc (8s và 25s) đếm element khớp từng rule và chỉ cảnh báo ở mốc sau: nav của
Threads render trễ nên mốc sớm luôn báo thiếu, mà cảnh báo luôn sai thì người ta quen bỏ qua
cảnh báo thật.

## Verify không cần nhìn màn hình

```bash
node electron/selftest.js                                # logic thuần, là cổng build
./4Message.app/Contents/MacOS/4Message --version
./4Message.app/Contents/MacOS/4Message --probe           # rail, link policy, tray icon
./4Message.app/Contents/MacOS/4Message --probe-toggle    # bật/tắt kênh, process chết thật
./4Message.app/Contents/MacOS/4Message --probe-prefs     # trạng thái đọc lại được
./4Message.app/Contents/MacOS/4Message --probe-image     # menu chuột phải trên ảnh
```

**Thứ tự bắt buộc** là `--probe` → `--probe-toggle` → `--probe-prefs`, liên tiếp. Chèn
`--probe` vào giữa hai lệnh cuối sẽ reset `prefs.json` và làm `--probe-prefs` fail oan, đọc
y hệt một lỗi persistence thật.

`--probe-image` **nằm ngoài ràng buộc thứ tự đó** — nó không đọc cũng không ghi `prefs.json`
nên chạy lúc nào cũng được. Ba lưu ý khi chạy nó:

- Chạy trên `userData` **thật**, không phải thư mục tạm như ba mode kia. Cố ý: nửa giá trị
  nhất của nó là đo ảnh chat thật, mà ảnh chat chỉ có khi đã đăng nhập. Nó chỉ đọc, không ghi
  `prefs.json`. **Thoát app đang chạy trước** để tránh hai instance khoá cùng một profile.
- Cướp focus (`app.focus({steal: true})`) vì `sendInputEvent` chỉ tới nơi khi cửa sổ đang
  focused. Đừng gõ phím trong lúc nó chạy.
- **Ghi đè clipboard**: một assert kiểm copy ra tận bitmap trong clipboard.

Nó in hai phần tách bạch: **assert** (cơ chế Chromium → Electron, không cần login, exit code
phụ thuộc phần này) và **báo cáo** (chuột phải vào ảnh thật của từng kênh — chỉ có nghĩa khi
đã đăng nhập, không assert). Xem `plans/2026-08-24-copy-image/design.md` để biết vì sao tách.

Exit code là cổng, không phải dòng log. Mọi probe đi qua `runProbe` nên throw cũng thành
`FAIL probe throw` + exit 1 chứ không treo.

## Script

| Script | Việc |
| --- | --- |
| `./build-electron.sh` | Build + selftest + cắt locale + ad-hoc sign |
| `./release-electron.sh` | Build rồi đẩy lên GitHub Release, tag `electron-b<số build>` |
| `./install-electron.sh` | Cài bản Release mới nhất lên máy dùng. Không cần node |
| `./build-dmg.sh` | Đóng `.app` thành DMG có shortcut Applications để kéo vào cài |
| `./measure.sh` | Đo memory/CPU gồm cả helper process, có `--watch` |
| `./make-icon.sh` | Sinh `Resources/AppIcon.icns` từ `tools/make-icon.swift` |
| `./docs-check.sh` | Kiểm docs không lệch code: env var và script đều phải được nhắc |
| `tools/pii-guard.sh` | Chặn PII/secret. `--staged` (hook), `--tree` (gate publish), `--history` (audit) |

## Chặn PII

Repo này từng public kèm tên thật của ba người, username Instagram và thread ID E2EE — nằm
trong file `.log` commit rồi xoá. Dọn tốn force-push, xoá tag, rồi xoá và tạo lại repo.

Bật hook chặn tại chỗ (mỗi clone phải chạy một lần):

```bash
git config core.hooksPath .githooks
```

Gate thật nằm ở `release-electron.sh` — nó chạy `pii-guard.sh --tree` trước khi publish,
**không phụ thuộc** hook có được cấu hình hay không. Đó là chỗ nội dung thật sự thành công
khai.

Audit toàn bộ history: `tools/pii-guard.sh --history`.

Mỗi mẫu phải **khớp fixture của chính nó** trước khi quét; không khớp thì guard dừng với
exit 2 thay vì âm thầm quét rỗng. Đây là phần quan trọng nhất của script: harness kiểm trong
repo này đã hỏng 6 lần và lần nào cũng báo "sạch".

False positive thì thêm regex vào `tools/pii-allow.txt` — mỗi dòng ở đó là một lỗ thủng.

## Icon

Bong bóng chat + **4 chấm 2×2** = 4 kênh. Thiết kế gốc — không dùng logo Messenger của Meta
(trademark), không dùng SF Symbols (license cấm dùng làm app icon).

- `tools/make-icon.swift` → `Resources/AppIcon.icns` (app icon, full màu)
- `electron/make-tray-icon.js` → `electron/tray.png` (menu bar, template đơn sắc)

Hai file phải giữ cùng tỉ lệ; các phân số hình học ghi trong `make-tray-icon.js`.
`tools/icon-balance.swift` đo centroid/bbox và vẽ đường gióng để kiểm cân bằng.

Chi tiết quyết định: `plans/2026-08-06-icon-4-dots/design.md`.

## Hạn chế đã biết

1. **E2EE: app là một thiết bị Messenger riêng.** Hội thoại mã hoá đầu-cuối chỉ giải mã được
   từ store cục bộ của từng thiết bị; server không giữ bản rõ. Nên app chỉ có lịch sử từ lúc
   bạn đăng nhập vào nó. Thread cũ không có tin mới sẽ hiện preview trống hoặc cũ, dù tên và
   avatar vẫn đúng. Đây là bản chất E2EE, không phải bug.
2. **Kênh tắt không báo tin.** Hệ quả trực tiếp của việc hủy view để trả RAM.
3. **Badge Instagram/Threads/Zalo đọc `document.title`** — có thể không phản ánh đúng số DM.
   Zalo đặc biệt chưa kiểm chứng được title có mang số hay không.
4. **`--probe-toggle` FAIL 1 assert**: `process kênh đã tắt còn sống: ["zalo"]`. Process
   renderer của Zalo không chết sau `webContents.close()`. Lỗi có sẵn, đã kiểm chứng độc lập
   với tính năng ảnh (bỏ `zalo` khỏi `FBMESS_SERVICES` thì PASS). Chưa sửa.
5. **Notification khi app ẩn lâu chưa xác minh trên máy dùng thật.** Quyền đã gate theo
   origin; nếu vỡ thì log `quyền BỊ TỪ CHỐI:` sẽ chỉ ra lý do.
6. `⌘⇧M` có thể trùng hotkey app khác.
7. Voice/video call chưa kiểm tra thực tế.

## Vì sao Electron chứ không phải WKWebView

Bản đầu viết bằng Swift + `WKWebView`. Nó bùng 60–100% CPU theo đợt làm nội dung đóng băng.
`sample` trên một WebContent đang 100.7% CPU cho thấy thời gian nằm **toàn bộ ở layout của
WebCore** (`computeVisibleRectsInContainer` 400 mẫu, `performFlexLayout` 229) — không một
frame style-recalc nào, và spike vẫn xảy ra khi tắt hết CSS của app. Tức layout thrash nằm
trong WebCore, không sửa được từ phía shell.

Blink đo trên cùng trang: 0.91% trung bình qua 25.78 giờ.

Bản Swift đã xoá. Source còn trong git history ở tag `swift-final`:

```bash
git checkout swift-final -- Package.swift Sources/ Resources/Info.plist build.sh
```

Store WebKit của nó (`~/Library/WebKit/io.mobio.loind.fbmess`, 375 MB, chứa lịch sử E2EE) đã
bị xoá ngày 2026-08-06 — không có snapshot hay Time Machine nên không phục hồi được. Nên tag
`swift-final` giờ chỉ còn giá trị tham khảo code, không còn là đường đọc lại lịch sử cũ.

Bài học đáng ghi cho lần sau: dữ liệu E2EE là **per-device**. Thiết bị nào mất store là mất
bản sao của thiết bị đó, và không có bản trên server để tải lại. Muốn lịch sử theo được sang
máy mới thì phải bật **secure storage (PIN)** trong Messenger *trước*, không phải sau.

Chi tiết quyết định và số liệu: `plans/2026-08-04-engine-decision/brainstorm.md`.

## Cấu trúc

```
electron/            app: main.js, services.js, image-menu.js, prefs.js, rail.html, preload, selftest
tools/               make-icon.swift, icon-balance.swift (+ script dựng phương án icon)
Resources/           AppIcon.icns
docs/                ui-discipline, perf-process, decisions/
plans/               brainstorm + plan từng tính năng
```
