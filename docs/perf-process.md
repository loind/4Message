# Quy trình phân tích hiệu năng

Quy trình 5 bước, lặp lại được, dùng cho mọi thay đổi liên quan hiệu năng của FB Mess.
Nguyên tắc: **chẩn đoán trước, không tối ưu mù**; mọi phương án phải đo được và so sánh
ở cùng điều kiện.

## Bước 1 — Chẩn đoán: memory nằm ở đâu

Không dùng `ps` RSS để kết luận. RSS gộp cả vùng shared (`__TEXT` của framework) nên
phóng đại nhiều lần. Số đúng là `phys_footprint` — cũng chính là số Activity Monitor hiện.

```bash
vmmap --summary <pid> | grep 'Physical footprint'
vmmap --summary <pid> | sed -n '/REGION TYPE/,/^TOTAL/p'   # phân rã theo region
```

Đọc cột **DIRTY**, không phải RESIDENT. Resident gồm cả code framework dùng chung với
Safari nên không phản ánh chi phí thật của app.

Ví dụ số đo được lần đầu (sau khi login, dùng một lúc):

| Vùng | Dirty | Ý nghĩa |
| --- | --- | --- |
| `WebKit Malloc` | ~468 MB | DOM, render tree, ảnh đã decode, layer backing store |
| vùng graphics | ~106 MB | `VM_ALLOCATE (graphics)` + `owned unmapped (graphics)` |
| `JS JIT generated code` | 48 MB | Code JIT của JavaScriptCore |
| `JS VM Gigacage` | 11 MB | **JS heap — rất nhỏ** |

Kết luận rút ra: vấn đề **không** ở JavaScript heap. Nó ở DOM + render tree + ảnh decode
+ layer backing. Mọi phương án phải nhắm vào đó, không nhắm vào JS.

## Bước 2 — Sinh phương án từ chẩn đoán

Chỉ chọn phương án tác động đúng vùng đã chẩn đoán. Ưu tiên API công khai của platform
trước khi tự viết cơ chế.

API tìm được trong SDK (`WKPreferences.h`) quyết định thiết kế:

```objc
typedef NS_ENUM(NSInteger, WKInactiveSchedulingPolicy) {
    WKInactiveSchedulingPolicySuspend,   // dừng hẳn JS + layout
    WKInactiveSchedulingPolicyThrottle,  // throttle CPU, JS vẫn chạy
    WKInactiveSchedulingPolicyNone
};
```

Điều kiện then chốt trong header: policy chỉ áp dụng khi web view **"idle and detached
from all windows"**, và *"web views are not considered idle when playing media or loading
web pages"*. Nghĩa là chỉ set policy là vô nghĩa — phải tháo webView khỏi view hierarchy
khi ẩn cửa sổ.

Bốn phương án:

| Mode | inactiveSchedulingPolicy | Detach khi ẩn | Giữ assertion chặn App Nap | Chặn telemetry/media | Giả thuyết |
| --- | --- | --- | --- | --- | --- |
| `baseline` | `.none` | Không | Có | Không | Hành vi ban đầu — assertion nghi chặn WebKit prune |
| `throttle` | `.throttle` | Có | Không | Không | CPU giảm, memory prune, notification vẫn đến |
| `suspend` | `.suspend` | Có | Không | Không | CPU ≈ 0, memory giảm nhiều nhất, **notification có thể tắt** |
| `block` | `.throttle` | Có | Không | Có | Như throttle + giảm ảnh/media decode |

Chọn bằng env var, **một lần build cho cả 4 mode** — tránh 4 binary lệch nhau:

```bash
FBMESS_MODE=throttle "FB Mess.app/Contents/MacOS/Messenger"
```

## Bước 3 — Đo: giao thức cố định

`./bench.sh [mode...]`

```
t=0             launch, cửa sổ hiện, trang load
t=LOAD-15       đo T1: footprint + CPU (cửa sổ còn hiện)
t=LOAD          app tự ẩn cửa sổ (FBMESS_BENCH_HIDE_AFTER)
t=LOAD+SOAK/2   đo delta network → kết nối realtime còn sống không
t=LOAD+SOAK     đo T2: footprint + CPU (đã ẩn)
```

Ba điểm khiến số đo tin được:

1. **Attribution chính xác, không heuristic.** Chụp danh sách WebKit XPC process trước
   khi launch; process mới xuất hiện sau đó là của app. WebKit XPC service có `ppid=1`
   nên không thể gom bằng quan hệ cha–con, và `launchctl procinfo` cần root.
2. **CPU là trung bình trên cửa sổ thời gian**, lấy mẫu thứ 2 của `top -l 2 -s N`.
   `ps -o pcpu` là trung bình từ lúc process sinh ra — vô dụng ở đây.
3. **Delta network làm proxy cho "notification còn hoạt động"**. `> 0 KB` khi đang ẩn
   nghĩa là WebSocket còn sống. `lsof` không thấy socket của WebKit process nên phải
   dùng `nettop` (API khác).

## Bước 4 — Control run, và cái bẫy đã gặp

Lần smoke test đầu tiên cho footprint khi ẩn (812 MB) **cao hơn** khi hiện (736 MB).
Không phải vì ẩn làm tốn thêm memory — mà vì hai mốc đo cách nhau ~73 s và memory vẫn
đang tăng theo thời gian. So T1 với T2 trong cùng một mode là **confound**.

Vì vậy:

- Luôn chạy thêm **control**: `NOHIDE=1 ./bench.sh baseline` — không ẩn cửa sổ, nên T2
  của nó là mức tăng theo thời gian thuần.
- Kết luận chỉ được rút từ **so sánh giữa các mode tại cùng mốc T**, không phải từ
  T1→T2 trong một mode.

## Bước 5 — Chọn phương án

Thứ tự ưu tiên khi cân nhắc:

1. **Notification phải còn hoạt động.** Đây là lý do tồn tại của app. Mode nào làm
   `Net T2 = 0` thì loại, dù memory đẹp đến đâu.
2. Footprint T2 khi ẩn — trạng thái app ở phần lớn thời gian.
3. CPU T2 — ảnh hưởng pin và quạt.
4. Footprint T1 — trạng thái đang dùng.

Kết quả ghi vào `bench-results.md` (append, không ghi đè), log stderr từng mode ở
`bench-<mode>.log`.

## Bước 6 — Trước khi kết luận "leak", thử memory pressure

Sai lầm đã mắc trong dự án này: thấy process `WebContent` tăng lên ~900 MB và không giảm
sau 60 giây ẩn cửa sổ → kết luận "ratchet một chiều, không trả lại". **Kết luận đó sai vì
cửa sổ quan sát quá ngắn.**

`WebKit Malloc` là bmalloc — allocator có cache riêng, trả page về OS theo scavenger chạy
định kỳ, và purge mạnh chỉ khi nhận notification memory pressure. Máy còn RAM thì nó
không có lý do co lại. Nên **thiếu pressure thì không phân biệt được cache với leak.**

`sudo ./pressure-test.sh` — simulate pressure qua `memory_pressure -S`, đo footprint ở
4 mốc. Kết quả thực tế: 891 → 692 → 653 → **516 MB** (giảm 42%), và SharedWorker bị kill
rồi respawn từ 161 MB xuống 10 MB.

An toàn: `-S` chỉ **simulate**, không cấp phát RAM thật. Bỏ `-S` thì `memory_pressure`
sẽ ăn nhiều GB RAM thật cho đến khi hệ thống báo thiếu — **đừng dùng**. Sysctl
`kern.memorypressure_manual_trigger` là trigger write-only nên máy không thể kẹt ở trạng
thái pressure; script vẫn có trap fire `NORMAL` lúc thoát.

Cần TTY thật để `sudo` nhập mật khẩu — chạy trong Terminal.app, không chạy qua tool.

### Phân biệt leak với cache

| Dấu hiệu | Leak | Cache |
| --- | --- | --- |
| Số process | Tích lũy dần | Cố định |
| Đường tăng | Đều, liên tục | Nhảy bậc rồi plateau |
| Dưới memory pressure | Không giảm | Giảm rõ rệt |
| Sau nhiều phút idle | Không giảm | Giảm chậm theo scavenger |
| Vùng vmmap | Bất kỳ | `WebKit Malloc` + graphics, JS heap nhỏ |

## Phụ lục — flag tối ưu khi biên dịch Swift

Câu hỏi: có bật được tối ưu mạnh như build C không, để app final nhanh hơn?

Đã có sẵn ở `-c release`: SwiftPM tự bật **whole-module-optimization**. Không cần thêm gì.

`RELEASE_TUNE=fast ./build.sh` bật thêm:

```
-Xswiftc -Ounchecked                      # bỏ precondition + bounds/overflow check
-Xswiftc -enforce-exclusivity=unchecked   # bỏ exclusivity check runtime
-Xswiftc -lto=llvm-thin                   # link-time optimization
-Xlinker -dead_strip                      # bỏ code không dùng khi link
```

Đo được (`./startup.sh`, n=5, lấy **min** vì avg nhiễu bởi cold cache):

| tune | Binary | total min | main min |
| --- | --- | --- | --- |
| `default` | 195 KB | 140.1 ms | 130.4 ms |
| `fast` | 195 KB | 138.1 ms | 130.2 ms |

**Kết luận: không đáng.** Binary giống nhau đến từng KB, phần code app nhanh hơn 0.2 ms
trên 130 ms. Lý do: trong 130 ms đó gần như toàn bộ là khởi tạo AppKit + WebKit +
`WKWebView` — framework prebuilt của Apple, flag của mình không chạm tới. Logic Swift của
app chỉ chạy một lần lúc dựng window, không có vòng lặp nóng nào để tối ưu.

Giá phải trả thì thật: `-Ounchecked` bỏ luôn kiểm tra bounds và integer overflow.

**Bẫy đã gặp:** `-Ounchecked` xoá cả `precondition` và `assert`, nên `--selftest` sẽ luôn
báo OK dù logic sai. Kiểm chứng:

```
precondition(false)  -O           → abort
precondition(false)  -Ounchecked  → chạy tiếp, không abort
fatalError(...)      cả hai       → abort
```

Vì vậy `runSelftest()` dùng hàm `check()` bọc `fatalError`, không dùng `precondition`.

Các flag khác đã cân nhắc và loại:

| Flag | Lý do loại |
| --- | --- |
| `--static-swift-stdlib` | macOS đã có Swift runtime trong `/usr/lib/swift` từ 10.14.4. Link tĩnh làm binary to hơn và mất shared page — chậm hơn, không nhanh hơn |
| `-cross-module-optimization` | Chỉ có tác dụng khi nhiều module. Project này 1 module |
| `-whole-module-optimization` | Đã bật sẵn ở `-c release` |

Thứ thật sự làm app "cảm giác nhanh" thì đã có: app resident ở menu bar, `⌘W` ẩn chứ
không quit → lần mở sau không tốn 140 ms nào cả.

## Chạy lại

```bash
./build.sh
rm -f bench-results.md
NOHIDE=1 ./bench.sh baseline                      # control
./bench.sh baseline throttle suspend block        # 4 phương án
```

Rút ngắn khi chỉ cần kiểm tra harness: `LOAD=35 SOAK=40 CPU_WINDOW=5 ./bench.sh throttle`.

Lưu ý: bench kill và relaunch app nhiều lần, mỗi lần cửa sổ chiếm focus ~LOAD giây.
Không chạy khi đang cần dùng Messenger.
