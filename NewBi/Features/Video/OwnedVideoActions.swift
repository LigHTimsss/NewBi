import SwiftUI

/// 保留原有长按菜单，在本人视频上追加删除入口。
struct OwnedVideoActions<MenuItems: View>: ViewModifier {
    let card: VideoCard
    @ViewBuilder var menuItems: MenuItems
    @Environment(SessionStore.self) private var session
    @State private var confirm = false

    func body(content: Content) -> some View {
        Group {
            if !OwnedContentDeletion.shared.videos.contains(card.id) {
                content.contextMenu {
                    menuItems
                    if card.id > 0, OwnedContentDeletion.owns(card.owner?.mid, session: session) {
                        Button("删除视频稿件", systemImage: "trash", role: .destructive) { confirm = true }
                    }
                }
            }
        }
        .modifier(VideoDeletionPresentation(card: card, confirmation: $confirm))
    }
}

/// 普通播放器和全屏播放器共用的更多面板入口。
struct DeleteVideoControl: View {
    let card: VideoCard
    @Environment(SessionStore.self) private var session
    @State private var confirm = false

    var body: some View {
        if card.id > 0, OwnedContentDeletion.owns(card.owner?.mid, session: session) {
            Button(role: .destructive) { confirm = true } label: {
                VStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                        .frame(width: 48, height: 48)
                        .background(.white.opacity(0.08), in: .rect(cornerRadius: 16))
                    Text("删除稿件").font(.system(size: 11))
                }
            }
            .buttonStyle(PressableStyle())
            .modifier(VideoDeletionPresentation(card: card, confirmation: $confirm))
        }
    }
}

struct VideoDeletionPresentation: ViewModifier {
    let card: VideoCard
    @Binding var confirmation: Bool
    @State private var showManager = false
    @Environment(SessionStore.self) private var session

    func body(content: Content) -> some View {
        content
            .alert("删除自己的视频稿件？", isPresented: $confirmation) {
                Button("前往验证并删除", role: .destructive) {
                    guard OwnedContentDeletion.owns(card.owner?.mid, session: session) else {
                        ToastCenter.shared.show("登录账号已变化，请重新操作")
                        return
                    }
                    showManager = true
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("《\(card.title)》\n删除的是已发布稿件，不是本地缓存。删除后无法恢复。接下来在官方稿件管理页完成删除和身份验证。")
            }
            .sheet(isPresented: $showManager) { VideoDeletionSheet(card: card) }
            .onChange(of: session.mid) { _, _ in confirmation = false; showManager = false }
    }
}
