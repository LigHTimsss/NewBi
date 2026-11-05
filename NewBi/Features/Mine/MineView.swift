import SwiftUI

/// 「我的」画板：头像 + 等级/会员、三项数据、常用入口卡片、设置
struct MineView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearance") private var appearance = 0
    @State private var showLogin = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                if session.isLoggedIn { stats }
                shortcuts
                moreRows
            }
            .padding(.horizontal, 16)
        }
        .contentMargins(.top, 56, for: .scrollContent)
        .contentMargins(.bottom, 96, for: .scrollContent)
        .overlay(alignment: .topTrailing) { toolGroup.padding(.trailing, 16) }
        .sheet(isPresented: $showLogin) { LoginView() }
    }

    private var toolGroup: some View {
        HStack(spacing: 0) {
            toolButton("viewfinder", "扫一扫") {}
            toolButton(scheme == .dark ? "moon.fill" : "moon", "深色模式") {
                withAnimation(Motion.component) { appearance = scheme == .dark ? 1 : 2 }
            }
            NavigationLink(value: Route.settings) {
                Image(systemName: "gearshape").frame(width: 42, height: 40)
            }
            .accessibilityLabel("设置")
        }
        .font(.system(size: 18))
        .foregroundStyle(.primary)
        .padding(.horizontal, 2)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func toolButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 42, height: 40)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var header: some View {
        if let user = session.user, user.isLogin {
            HStack(spacing: 14) {
                RemoteImage(url: user.face, size: CGSize(width: 58, height: 58))
                    .frame(width: 58, height: 58)
                    .clipShape(.circle)
                    .padding(4)
                    .overlay { Circle().stroke(accent, lineWidth: 2) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(user.uname ?? "").font(.system(size: 20, weight: .bold))
                        if let level = user.levelInfo?.currentLevel {
                            Text("LV\(level)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(accent.accentText(scheme))
                                .padding(.horizontal, 5)
                                .frame(height: 16)
                                .overlay { RoundedRectangle(cornerRadius: 4).stroke(accent.accentText(scheme)) }
                        }
                    }
                    HStack(spacing: 6) {
                        if user.vipStatus == 1 {
                            Text("大会员")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .frame(height: 18)
                                .background(accent.accentFill, in: .capsule)
                        }
                        Text("硬币 \(Int(user.money ?? 0))")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer()
            }
            .padding(.top, 8)
        } else {
            Button { showLogin = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 62))
                        .foregroundStyle(Theme.secondaryText)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("点击登录").font(.system(size: 20, weight: .bold))
                        Text("扫码登录，同步关注与历史").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.secondaryText)
                }
                .contentShape(.rect)
            }
            .buttonStyle(PressableStyle())
            .foregroundStyle(.primary)
            .padding(.top, 8)
        }
    }

    private var stats: some View {
        HStack {
            stat(session.stat?.dynamicCount, "动态")
            stat(session.stat?.following, "关注")
            stat(session.stat?.follower, "粉丝")
        }
    }

    private func stat(_ value: Int?, _ title: String) -> some View {
        VStack(spacing: 2) {
            // 不挂数字滚动效果：数据刷新本来就不带动画，这个效果从没显示过；
            // 挂着时低电量模式下切到「我的」整页平移会明显掉帧（真机逐项排查确认）
            Text(value?.biliCount ?? "-")
                .font(.system(size: 19, weight: .bold))
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private var shortcuts: some View {
        HStack {
            shortcut("arrow.down.to.line", "离线缓存", route: .downloads)
            shortcut("clock", "历史记录", route: .history)
            shortcut("star", "我的收藏", route: .favorites)
            shortcut("play.rectangle.on.rectangle", "稍后再看", route: .watchLater)
        }
        .padding(.vertical, 14)
        .background(Theme.card, in: .rect(cornerRadius: 22))
    }

    @ViewBuilder
    private func shortcut(_ icon: String, _ title: String, route: Route? = nil) -> some View {
        let label = VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(accent.accentText(scheme))
                .frame(height: 26)
            Text(title).font(.system(size: 12)).foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)

        if let route {
            NavigationLink(value: route) { label }.buttonStyle(PressableStyle())
        } else {
            // 离线缓存、稍后再看：后续版本
            Button {} label: { label }.buttonStyle(PressableStyle())
        }
    }

    private var moreRows: some View {
        VStack(spacing: 0) {
            NavigationLink(value: Route.settings) {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18))
                        .foregroundStyle(accent.accentText(scheme))
                    Text("设置").font(.system(size: 15))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal, 14)
                .frame(height: 50)
                .contentShape(.rect)
            }
            .foregroundStyle(.primary)
        }
        .background(Theme.card, in: .rect(cornerRadius: 22))
    }
}

struct LoginView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var model = QRLoginModel()

    var body: some View {
        VStack(spacing: 20) {
            Text("扫码登录").font(.serif(24)).tracking(2).padding(.top, 32)

            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(.white)
                if let image = model.qrImage {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                        .blur(radius: model.phase == .expired ? 6 : 0)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 220, height: 220)
            .animation(Motion.component, value: model.phase)

            Text(statusText)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .contentTransition(.opacity)

            HStack(spacing: 12) {
                if model.phase == .expired {
                    Button("刷新二维码") { model.start() }
                }
                // 同一台 iPhone：保存二维码后在官方 App「扫一扫 → 相册」识别
                if let image = model.qrImage {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("登录二维码", image: Image(uiImage: image))) {
                        Label("保存二维码", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .buttonStyle(.glass)

            Text("仅使用官方扫码登录，不会接触你的账号密码")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .presentationDetents([.medium, .large])
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.phase) { _, phase in
            guard phase == .success else { return }
            Task {
                await session.didLogin()
                dismiss()
            }
        }
    }

    private var statusText: String {
        switch model.phase {
        case .loading: "正在生成二维码…"
        case .waiting: "请使用哔哩哔哩 App 扫码"
        case .scanned: "已扫码，请在手机上确认"
        case .expired: "二维码已过期"
        case .success: "登录成功"
        case .failed(let message): message
        }
    }
}
