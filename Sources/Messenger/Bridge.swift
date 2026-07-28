import Foundation

/// Inject tại `.atDocumentStart` — phải có mặt trước khi JS của Messenger chạy.
///
/// WKWebView trên macOS không implement Web Notifications API, nên `window.Notification`
/// được shim lại: mỗi lần Messenger tạo notification, ta forward sang native
/// `UNUserNotificationCenter`. Registry `reg` giữ instance để khi user click
/// notification native, ta gọi lại đúng `onclick` của web → nhảy vào đúng hội thoại.
let bridgeJS = #"""
(() => {
  if (window.__mbr) return;
  window.__mbr = true;

  const post = (msg) => {
    try { window.webkit.messageHandlers.mbr.postMessage(msg); } catch (e) {}
  };

  const reg = new Map();
  let seq = 0;

  class MbrNotification {
    static get permission() { return 'granted'; }
    static requestPermission(cb) {
      if (typeof cb === 'function') cb('granted');
      return Promise.resolve('granted');
    }

    constructor(title, options) {
      const o = options || {};
      this.title = title;
      this.body = o.body || '';
      this.tag = o.tag || '';
      this.data = o.data;
      this.onclick = null;
      this.onclose = null;
      this.onerror = null;
      this.onshow = null;
      this._id = 'n' + (++seq);

      reg.set(this._id, this);
      // Giữ registry nhỏ — chỉ cần instance gần đây để route click.
      while (reg.size > 50) reg.delete(reg.keys().next().value);

      post({
        kind: 'notify',
        id: this._id,
        title: String(title == null ? '' : title),
        body: String(this.body),
      });
    }

    close() { reg.delete(this._id); }
    addEventListener(type, fn) { if (type === 'click') this.onclick = fn; }
    removeEventListener(type) { if (type === 'click') this.onclick = null; }
    dispatchEvent() { return true; }
  }

  Object.defineProperty(window, 'Notification', {
    value: MbrNotification,
    writable: true,
    configurable: true,
  });

  // Gọi từ native khi user click notification.
  window.__mbrClick = (id) => {
    const n = reg.get(id);
    if (n && typeof n.onclick === 'function') {
      try { n.onclick.call(n, new Event('click')); } catch (e) {}
    }
  };
})();
"""#

/// Ẩn thanh tab của Facebook (Home / Reels / Marketplace / Groups / Gaming) trên
/// surface `facebook.com/messages`.
///
/// KHÔNG dùng `[role="navigation"]` trần: trang này có 3 vùng navigation — thanh tab,
/// account controls, và THREAD LIST. Ẩn hết là mất danh sách hội thoại.
///
/// Nhận diện bằng `:has()` theo `href` chứ không theo `aria-label`, vì label đổi theo
/// ngôn ngữ UI. `:has()` có từ Safari 15.4, máy đích chạy Safari 26.
///
/// Lưu ý: ẩn CSS KHÔNG giảm memory — DOM node vẫn tồn tại, React vẫn render và diff.
/// Lợi ích thật là chặn lỡ tay click vào Reels/Marketplace, vốn load surface rất nặng
/// vào cùng WebContent process.
/// Vì sao dùng aria-label KHỚP CHÍNH XÁC chứ không phải `*=`:
///   - `input[role="combobox"]` khớp cả ô "Search Messenger" của chính Messenger.
///   - `[role="button"][aria-label*="Facebook" i]` khớp cả một tin nhắn, vì nội dung
///     tin nhắn cũng được đưa vào `aria-label`.
/// Khớp chính xác thì fail-safe: Facebook đổi label → không ẩn được (vô hại), chứ không
/// ẩn nhầm thứ đang cần. Đánh đổi: phụ thuộc ngôn ngữ UI của Facebook.
let hideChromeJS = #"""
(() => {
  const RULES = [
    // Thanh tab: nhận theo href nên độc lập ngôn ngữ.
    { name: 'tab bar',       sel: '[role="navigation"]:has(a[href^="/marketplace/"])' },
    // Hai cái dưới chỉ phân biệt được qua label → khớp chính xác.
    { name: 'search input',  sel: 'input[aria-label="Search Facebook"]' },
    // Ẩn mỗi <input> là chưa đủ: cái nút tròn nhìn thấy được là <label> bọc ngoài
    // (40x40, border-radius 50px) chứa icon kính lúp.
    // BẮT BUỘC dùng `> input`: `:has(input…)` không có `>` sẽ khớp MỌI ancestor
    // tới tận <body> → ẩn sạch trang.
    { name: 'search button', sel: '*:has(> input[aria-label="Search Facebook"])' },
    // Mảnh còn lại của widget search: không còn cách mở typeahead nên đây là UI chết.
    { name: 'typeahead x',   sel: '[role="button"][aria-label="Exit typeahead"]' },
    { name: 'facebook menu', sel: '[role="button"][aria-label="Facebook menu"]' },
  ];

  const style = document.createElement('style');
  style.textContent = RULES.map(r => r.sel).join(',') + '{display:none!important}';
  (document.head || document.documentElement).appendChild(style);

  // Self-check từng rule: khớp 0 element nghĩa là Facebook đã đổi cấu trúc/label.
  // Báo về native để biết, thay vì hỏng âm thầm.
  setTimeout(() => {
    try {
      window.webkit.messageHandlers.mbr.postMessage({
        kind: 'chrome',
        hits: RULES.map(r => r.name + '=' + document.querySelectorAll(r.sel).length).join(' '),
        misses: RULES.filter(r => !document.querySelector(r.sel)).map(r => r.name).join(',')
      });
    } catch (e) {}
  }, 8000);
})();
"""#

/// JSON-encode một string để nhúng an toàn vào `evaluateJavaScript`.
func jsString(_ value: String) -> String {
    guard let data = try? JSONEncoder().encode(value),
          let encoded = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    return encoded
}
