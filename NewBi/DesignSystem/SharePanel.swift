import SwiftUI
import UIKit

/// 要分享的东西：标题 + 链接，或一张图片
struct SharePayload: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: URL?
    let image: UIImage?

    /// 发到微信 / QQ 时粘贴的文字：【标题】链接
    var message: String {
        guard let url else { return title }
        return title.isEmpty ? url.absoluteString : "【\(title)】 \(url.absoluteString)"
    }

    static func == (lhs: SharePayload, rhs: SharePayload) -> Bool { lhs.id == rhs.id }
}

/// 全局分享入口：任何地方调用 share，分享框画在整个 App 最上层（视频页之上）
@MainActor
@Observable
final class ShareCenter {
    static let shared = ShareCenter()

    fileprivate(set) var payload: SharePayload?

    func share(title: String, url: URL) {
        withAnimation(Motion.component) { payload = SharePayload(title: title, url: url, image: nil) }
    }

    /// 分享图片（大图查看里的「分享」）
    func shareImage(_ image: UIImage) {
        withAnimation(Motion.component) { payload = SharePayload(title: "图片", url: nil, image: image) }
    }

    func video(bvid: String, title: String) {
        guard !bvid.isEmpty, let url = URL(string: "https://www.bilibili.com/video/\(bvid)") else { return }
        share(title: title, url: url)
    }

    /// 收起分享框；动画结束后再做下一步（比如弹系统分享，免得两层同时出现）
    /// 收起用「越来越快」的曲线：弹簧收尾很长，最后一小段像是卡了一下才收回去
    private static let out = Animation.timingCurve(0.4, 0, 0.9, 0.6, duration: 0.28)

    fileprivate func dismiss(then next: (@MainActor () -> Void)? = nil) {
        // 完全移除后再做下一步（弹系统分享、打开微信），不在收起的最后一段抢主线程
        withAnimation(Self.out, completionCriteria: .removed) {
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

/// 自绘的分享框：微信、QQ、复制链接、更多（系统分享）
private struct SharePanel: View {
    let payload: SharePayload

    private static let weChatGreen = Color(red: 0x07 / 255, green: 0xC1 / 255, blue: 0x60 / 255)
    private static let qqBlue = Color(red: 0x12 / 255, green: 0xB7 / 255, blue: 0xF5 / 255)

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 5) {
                Text("分享到").font(.serif(17)).tracking(1.4)
                Text(payload.title.isEmpty ? (payload.url?.absoluteString ?? "") : payload.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
            }
            HStack(spacing: 0) {
                target("微信", icon: "message.fill", fill: Self.weChatGreen) { openApp("微信", scheme: "weixin://") }
                target("QQ", icon: "bubble.left.fill", fill: Self.qqBlue) { openApp("QQ", scheme: "mqq://") }
                target(payload.image == nil ? "复制链接" : "复制图片", icon: payload.image == nil ? "link" : "doc.on.doc", fill: nil, action: copyLink)
                target("更多", icon: "square.and.arrow.up", fill: nil, action: systemShare)
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

    /// 没有接入微信 / QQ 的官方 SDK（需要在开放平台注册应用）：先把「标题 + 链接」或图片放进剪贴板，
    /// 再打开对应 App，在里面选好聊天对象后粘贴发送
    private func openApp(_ name: String, scheme: String) {
        let payload = payload
        ShareCenter.shared.dismiss {
            Self.copy(payload)
            let what = payload.image == nil ? "链接" : "图片"
            guard let url = URL(string: scheme) else { return }
            Task {
                if await UIApplication.shared.open(url) {
                    ToastCenter.shared.show("\(what)已复制，在\(name)里选好聊天后粘贴发送")
                } else {
                    ToastCenter.shared.show("没有安装\(name)，\(what)已复制")
                }
            }
        }
    }

    private func copyLink() {
        let payload = payload
        ShareCenter.shared.dismiss {
            Self.copy(payload)
            ToastCenter.shared.show(payload.image == nil ? "链接已复制" : "图片已复制")
        }
    }

    private static func copy(_ payload: SharePayload) {
        if let image = payload.image {
            UIPasteboard.general.image = image
        } else if payload.url != nil {
            UIPasteboard.general.string = payload.message
        }
    }

    private func systemShare() {
        let payload = payload
        ShareCenter.shared.dismiss {
            SystemShare.present(payload)
        }
    }
}

/// 系统分享面板：从最上层的控制器弹出（视频页、全屏时也能弹）
@MainActor
enum SystemShare {
    /// 图片直接交给系统分享：微信、QQ 的分享扩展里可以直接选好友
    static func present(_ payload: SharePayload) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let items: [Any]
        if let image = payload.image {
            items = [image]
        } else if let url = payload.url {
            items = payload.title.isEmpty ? [url] : [payload.title, url]
        } else {
            return
        }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = top.view
        top.present(controller, animated: true)
    }
}
