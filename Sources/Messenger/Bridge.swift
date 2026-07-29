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

/// Sinh JS ẩn chrome cho một service. Rule nằm ở `Service.hideRules` — DOM của Facebook
/// và Instagram khác nhau hoàn toàn nên không dùng chung selector được.
///
/// Rule truyền qua JSON để không phải escape thủ công selector chứa dấu ngoặc kép.
func makeHideChromeJS(serviceId: String, rules: [HideRule]) -> String {
    let payload = rules.map { ["name": $0.name, "sel": $0.selector] }
    let json = (try? JSONSerialization.data(withJSONObject: payload))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

    return """
    (() => {
      const SERVICE = \(jsString(serviceId));
      const RULES = \(json);
      if (!RULES.length) return;

      const style = document.createElement('style');
      style.textContent = RULES.map(r => r.sel).join(',') + '{display:none!important}';
      (document.head || document.documentElement).appendChild(style);

      // Self-check từng rule: khớp 0 element nghĩa là site đã đổi cấu trúc/label.
      // Báo về native để biết, thay vì hỏng âm thầm.
      //
      // Chạy 2 mốc và chỉ báo mốc SAU: nav của Threads trên /messages/ render trễ, mốc
      // 8s báo thiếu 3 rule dù chúng đúng. Cảnh báo sai thường xuyên thì người dùng
      // quen bỏ qua cảnh báo thật.
      const report = (phase) => {
        try {
          window.webkit.messageHandlers.mbr.postMessage({
            kind: 'chrome',
            service: SERVICE,
            phase: phase,
            hits: RULES.map(r => r.name + '=' + document.querySelectorAll(r.sel).length).join(' '),
            misses: RULES.filter(r => !document.querySelector(r.sel)).map(r => r.name).join(',')
          });
        } catch (e) {}
      };
      setTimeout(() => report('early'), 8000);
      setTimeout(() => report('late'), 25000);
    })();
    """
}

/// JSON-encode một string để nhúng an toàn vào `evaluateJavaScript`.
func jsString(_ value: String) -> String {
    guard let data = try? JSONEncoder().encode(value),
          let encoded = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    return encoded
}
