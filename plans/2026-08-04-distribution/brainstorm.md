# Phân phối bản Electron sang máy dùng

Chốt engine = A (`plans/2026-08-04-engine-decision/brainstorm.md`), nên chỉ còn một artifact
phải phân phối: `FBMessElectron.app`.

## Vấn đề

Hiện tại mỗi lần sửa code là chuỗi này, làm tay:

1. Build trên Mac mini → `FBMessElectron-arm64.zip` (129 MB)
2. Copy 129 MB sang MacBook
3. `unzip`
4. `mv /Applications/`
5. `xattr -dr com.apple.quarantine` — vì bundle chỉ ad-hoc sign

Bước 5 là hệ quả của việc không có Developer ID. Bước 2 là 129 MB mỗi lần sửa một dòng CSS.

## Số liệu vừa đo (Mac mini M4)

| | Giá trị |
| --- | --- |
| Build lần 2 (cache đã ấm) | **13.4 giây** |
| Cache Electron binary | 352 MB, một lần, ở `~/Library/Caches/electron` |
| npm cache | 41 MB |
| Quarantine trên app build tại máy | **không có** — chỉ `com.apple.provenance`, không phải cờ Gatekeeper |

Điểm thứ tư quan trọng: `com.apple.quarantine` do **tải về** mà có, không do thiếu signature.
App build tại máy không bị gắn cờ đó, nên bước 5 tự biến mất.

## Phương án

| | A. Build tại máy dùng | B. Tải zip tay (hiện tại) | C. Homebrew private tap | D. Developer ID + electron-updater |
| --- | --- | --- | --- | --- |
| Byte phải chuyển mỗi lần | **~0** (chỉ git diff) | 129 MB | 129 MB | 129 MB (nền) |
| Bước thủ công | 1 lệnh | 4 bước | 1 lệnh (`brew upgrade`) | **0** |
| Quarantine | không có | phải `xattr` | cask có `--no-quarantine` | không (đã notarize) |
| Tiền | 0 | 0 | 0 | **$99/năm** |
| Công phải viết | ~15 dòng `update.sh` | 0 | cask file + tap repo + upload release mỗi lần | chuyển sang electron-builder + CI + notarize |
| Máy đích cần | `node` + repo | không cần gì | homebrew | không cần gì |
| Hỏng thì sao | build fail → chưa cài bản mới, app cũ còn nguyên | — | — | update fail im lặng là lỗi kinh điển của Squirrel |

**D không khả thi ở trạng thái hiện tại**, không chỉ vì tiền: `autoUpdater` trên macOS là
Squirrel.Mac, đòi app được sign bằng Developer ID và bản update sign cùng identity đó.
Ad-hoc sign thì autoUpdate không chạy. Nên D là "mua Developer ID + chuyển build sang
electron-builder + notarize", không phải "bật một cờ".

## Đề xuất: A

**Build trên chính MacBook.** Repo đã có sẵn ở đó (bạn vẫn `git pull` và chạy `measure.sh`
trên máy đó), nên vấn đề phân phối biến mất thay vì được giải.

Gói lại thành `update.sh`:

```bash
git pull --ff-only
./build-electron.sh
# quit TRƯỚC khi ghi đè: copy lên một .app đang chạy làm hỏng instance đang chạy
osascript -e 'quit app "FBMessElectron"'
rm -rf /Applications/FBMessElectron.app
cp -R FBMessElectron.app /Applications/
open /Applications/FBMessElectron.app
```

Quit không mất gì — session nằm ở `~/Library/Application Support/FBMessElectron/`, không
nằm trong bundle.

Ba điều A đổi được so với hiện tại:

| | Trước | Sau |
| --- | --- | --- |
| Chuyển file | 129 MB mỗi lần sửa | 0 |
| Bước tay | 5 | 1 |
| `xattr -dr com.apple.quarantine` | bắt buộc | không cần |

### Điều kiện tiên quyết duy nhất

`node` trên MacBook. Lần build đầu tải 352 MB Electron binary vào cache, từ lần hai là 13s
(trên M4 — M1 chắc ~20–25s).

Nếu MacBook chưa có node thì đây là điểm cần xác nhận trước khi chốt A, vì nó là toàn bộ
điều kiện để A hoạt động.

### Kèm theo: zip nên thành opt-in

Nếu không còn chuyển file thì `ditto` 129 MB mỗi build là công vô ích. Đổi
`build-electron.sh` sang chỉ tạo zip khi có `--zip`. Giữ cờ đó lại vì vẫn cần khi đưa app
cho máy chưa có node.

## Khi nào đổi sang C hoặc D

| Điều kiện | Chuyển sang |
| --- | --- |
| Cài lên ≥3 máy, hoặc máy không có node | C — tap riêng, `brew upgrade`, vẫn 0đ |
| Đưa app cho người khác dùng | D — người ta sẽ không chấp nhận `xattr` và không tự build |

Không cần chuẩn bị trước cho hai trường hợp đó. `build-electron.sh` đã tách rời khỏi cách
phân phối, thêm C hay D sau đều không phải sửa app.

## Self-review

| Mục | Kết quả |
| --- | --- |
| Over-engineering | A là **bỏ** bước, không thêm hạ tầng. Đúng hướng |
| Đơn giản hơn được không | Không — 1 lệnh là mức thấp nhất mà vẫn có kiểm soát |
| Rủi ro phá hoại | `rm -rf /Applications/FBMessElectron.app` — phải hardcode đúng path, không nhận tham số, và `set -euo pipefail` để không chạy tiếp khi build fail |
| Rollback | `git checkout <commit cũ> && ./build-electron.sh`. Không cần cơ chế riêng |
| Điểm vỡ mới | Máy dùng giờ cần toolchain. Đánh đổi có ý thức: đổi 129 MB/lần lấy một lần cài node |

## Tiêu chú thành công

Trên MacBook: `./update.sh` từ lúc gõ đến lúc app mới mở lại < 1 phút, và `--version` in
đúng commit vừa pull.
