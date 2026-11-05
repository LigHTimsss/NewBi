import SwiftUI
import UIKit

/// 要分享的东西：标题 + 链接
struct SharePayload: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: URL

    /// 发到微信 / QQ 时粘贴的文字：【标题】链接
    var message: String {
        title.isEmpty ? url.absoluteString : "【\(title)】 \(url.absoluteString)"
    }
}

/// 全局分享入口：任何地方调用 share，分享框画在整个 App 最上层（视频页之上）
@MainActor
@Observable
final class ShareCenter {
    static let shared = ShareCenter()

    fileprivate(set) var payload: SharePayload?

    func share(title: String, url: URL) {
        withAnimation(Motion.component) { payload = SharePayload(title: title, url: url) }
    }

    func video(bvid: String, title: String) {
        guard !bvid.isEmpty, let url = URL(string: "https://www.bilibili.com/video/\(bvid)") else { return }
        share(title: title, url: url)
    }

    /// 收起分享框；动画结束后再做下一步（比如弹系统分享，免得两层同时出现）
    fileprivate func dismiss(then next: (@MainActor () -> Void)? = nil) {
        withAnimation(Motion.component, completionCriteria: .logicallyComplete) {
            payload = nil
        } completion: {
            next?()
        }
    }
}

/// 放在 RootView 最上层：遮罩 + 底部分享框
struct SharePanelLayer: View {
    private var center: ShareCenter { .shared }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let payload = center.payload {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { center.dismiss() }
                    .accessibilityLabel("关闭分享")
                    .transition(.opacity)
                SharePanel(payload: payload)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(center.payload != nil)
    }
}

/// 自绘的分享框：微信、QQ、复制链接、系统分享
private struct SharePanel: View {
    let payload: SharePayload

    private static let weChatGreen = Color(red: 0x07 / 255, green: 0xC1 / 255, blue: 0x60 / 255)
    private static let qqBlue = Color(red: 0x12 / 255, green: 0xB7 / 255, blue: 0xF5 / 255)

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 5) {
                Text("分享到").font(.serif(17)).tracking(1.4)
                Text(payload.title.isEmpty ? payload.url.absoluteString : payload.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
            }
            HStack(spacing: 0) {
                target("微信", icon: "message.fill", fill: Self.weChatGreen) { openApp("微信", scheme: "weixin://") }
                target("QQ", icon: "bubble.left.fill", fill: Self.qqBlue) { openApp("QQ", scheme: "mqq://") }
                target("复制链接", icon: "link", fill: nil, action: copyLink)
                target("系统分享", icon: "square.and.arrow.up", fill: nil, action: systemShare)
            }
            Button { ShareCenter.shared.dismiss() } label: {
                Text("取消")
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Theme.selection, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(PressableStyle())
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(maxWidth: 520)
        .glassEffect(.regular, in: .rect(cornerRadius: 34, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .accessibilityAddTraits(.isModal)
    }

    private func target(_ title: String, icon: String, fill: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(fill == nil ? Color.primary : Color.white)
                    .frame(width: 56, height: 56)
                    .background(fill ?? Theme.selection, in: .circle)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
    }

    /// 没有接入微信 / QQ 的官方 SDK（需要在开放平台注册应用）：先把「标题 + 链接」放进剪贴板，再打开对应 App 粘贴发送
    private func openApp(_ name: String, scheme: String) {
        let message = payload.message
        ShareCenter.shared.dismiss {
            UIPasteboard.general.string = message
            guard let url = URL(string: scheme) else { return }
            Task {
                if await UIApplication.shared.open(url) {
                    ToastCenter.shared.show("链接已复制，到\(name)里粘贴发送")
                } else {
                    ToastCenter.shared.show("没有安装\(name)，链接已复制")
                }
            }
        }
    }

    private func copyLink() {
        let link = payload.url.absoluteString
        ShareCenter.shared.dismiss {
            UIPasteboard.general.string = link
            ToastCenter.shared.show("链接已复制")
        }
    }

    private func systemShare() {
        let payload = payload
        ShareCenter.shared.dismiss {
            SystemShare.present(title: payload.title, url: payload.url)
        }
    }
}

/// 系统分享面板：从最上层的控制器弹出（视频页、全屏时也能弹）
@MainActor
enum SystemShare {
    static func present(title: String, url: URL) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let items: [Any] = title.isEmpty ? [url] : [title, url]
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = top.view
        top.present(controller, animated: true)
    }
}
