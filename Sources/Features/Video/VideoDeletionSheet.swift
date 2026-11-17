import SwiftUI
import WebKit

/// 稿件删除由官方页面完成短信 / 人机验证；只有目标稿件的成功响应才更新本地。
struct VideoDeletionSheet: View {
    let card: VideoCard
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    @State private var reloadID = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text("请在下方官方稿件管理中找到此视频，点击删除并完成验证。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(card.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    .textSelection(.enabled)
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(.red)
                    Button("重新加载") { self.failure = nil; reloadID += 1 }
                }
                if let mid = card.owner?.mid, OwnedContentDeletion.owns(mid, session: session) {
                    CreatorDeletionWebView(card: card, mid: mid, onDeleted: {
                        guard session.mid == mid else { return }
                        // 先请求关闭管理页，再收起正在播放的同一稿件。
                        dismiss()
                        OwnedContentDeletion.shared.confirmedVideo(card)
                        ToastCenter.shared.show("视频稿件已删除")
                    }, onFailure: { failure = $0 })
                    .id(reloadID)
                } else {
                    ContentUnavailableView("登录账号已变化", systemImage: "person.crop.circle.badge.exclamationmark")
                }
            }
            .padding(.top, 8)
            .navigationTitle("删除自己的视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("复制 BV 号") { UIPasteboard.general.string = card.bvid }
                        .disabled(card.bvid.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
        }
        .onChange(of: session.mid) { _, _ in dismiss() }
    }
}

private struct CreatorDeletionWebView: UIViewRepresentable {
    let card: VideoCard
    let mid: Int
    var onDeleted: () -> Void
    var onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(aid: card.id, mid: mid, onDeleted: onDeleted, onFailure: onFailure)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.userContentController.add(context.coordinator, name: "archiveDeleted")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.observer, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.customUserAgent = BiliClient.userAgent
        let coordinator = context.coordinator
        coordinator.startTask = Task { @MainActor [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            let url = URL(string: "https://member.bilibili.com/platform/upload-manager/article")!
            let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
            guard cookies.first(where: { $0.name == "DedeUserID" })?.value == String(mid),
                  cookies.contains(where: { $0.name == "SESSDATA" && !$0.value.isEmpty }) else {
                coordinator.onFailure("登录已失效，请重新登录后再试")
                return
            }
            for cookie in cookies { await view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
            guard !Task.isCancelled else { return }
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onDeleted = onDeleted
        context.coordinator.onFailure = onFailure
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.startTask?.cancel()
        coordinator.verificationTask?.cancel()
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "archiveDeleted")
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency WKScriptMessageHandler, @preconcurrency WKNavigationDelegate {
        let aid: Int
        let mid: Int
        var onDeleted: () -> Void
        var onFailure: (String) -> Void
        var startTask: Task<Void, Never>?
        var verificationTask: Task<Void, Never>?
        private var finished = false

        init(aid: Int, mid: Int, onDeleted: @escaping () -> Void, onFailure: @escaping (String) -> Void) {
            self.aid = aid; self.mid = mid; self.onDeleted = onDeleted; self.onFailure = onFailure
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !finished, verificationTask == nil, message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol == "https",
                  message.frameInfo.securityOrigin.host == "member.bilibili.com",
                  let raw = message.body as? String, Int(raw) == aid, let view = message.webView else { return }
            verificationTask = Task { @MainActor [weak self, weak view] in
                guard let self, let view else { return }
                defer { verificationTask = nil }
                let cookies = await view.configuration.websiteDataStore.httpCookieStore.allCookies()
                guard !Task.isCancelled,
                      cookies.contains(where: { $0.name == "DedeUserID" && $0.value == String(mid) }) else { return }
                finished = true
                onDeleted()
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { onFailure("页面加载失败：\(error.localizedDescription)") }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { onFailure("页面加载失败：\(error.localizedDescription)") }
        }
    }

    // 仅观察官方删除请求，不触发删除、不读取或传出 Cookie、不修改原响应。
    private static let observer = #"""
    (() => {
      function matches(value) {
        try { const u = new URL(value, location.href);
          return u.origin === 'https://member.bilibili.com' && u.pathname === '/x/web/archive/delete';
        } catch (_) { return false; }
      }
      function aid(body) {
        if (body instanceof FormData || body instanceof URLSearchParams) return body.get('aid');
        if (typeof body === 'string') return new URLSearchParams(body).get('aid');
        return null;
      }
      function report(id, result) {
        if (id && /^\d+$/.test(String(id)) && result && result.code === 0)
          window.webkit.messageHandlers.archiveDeleted.postMessage(String(id));
      }
      const fetchOriginal = window.fetch;
      window.fetch = function(input, init) {
        const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
        const relevant = matches(url) && String(init?.method || input?.method || 'GET').toUpperCase() === 'POST';
        const body = relevant ? (init?.body !== undefined ? Promise.resolve(init.body) :
          input instanceof Request ? input.clone().text() : Promise.resolve(null)) : null;
        const result = fetchOriginal.apply(this, arguments);
        if (relevant) result.then(async response => {
          if (response.ok) {
            const snapshot = response.clone();
            report(aid(await body), await snapshot.json());
          }
        }).catch(() => {});
        return result;
      };
      const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
      const targets = new WeakMap();
      XMLHttpRequest.prototype.open = function(method, url) {
        const previous = targets.get(this);
        if (previous?.listener) this.removeEventListener('load', previous.listener);
        targets.set(this, { relevant: String(method).toUpperCase() === 'POST' && matches(url) });
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function(body) {
        const target = targets.get(this);
        if (target?.relevant) {
          const id = aid(body);
          target.listener = () => {
            if (targets.get(this) !== target) return;
            try { if (this.status >= 200 && this.status < 300)
              report(id, this.responseType === 'json' ? this.response : JSON.parse(this.responseText));
            } catch (_) {}
          };
          this.addEventListener('load', target.listener, {once:true});
        }
        return send.apply(this, arguments);
      };
    })();
    """#
}
