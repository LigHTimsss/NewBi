import SwiftUI

/// 「我的」画板：头像 + 等级/会员、三项数据、常用入口卡片、设置
struct MineView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearance") private var appearance = 0
    @Environment(\.openURL) private var openURL
    @State private var showLogin = false
    @State private var showScanner = false
    /// 扫码识别出的视频 / 空间 / 网页：扫码页关掉后再打开（否则会开在扫码页底下）
    @State private var scanned: URL?

    var body: some View {
        let content = VStack(spacing: 20) {
            header
            if session.isLoggedIn, let mid = session.mid { stats(mid: mid) }
            shortcuts
            moreRows
        }
        .padding(.horizontal, 16)

        // 内容放得下一屏时直接排在页面上，不放进滚动视图：真机逐项排查过，滚动视图里的内容
        // 跟着整页平移时，低电量模式下切到「我的」会掉帧；放不下（大字号）时才用滚动视图
        ViewThatFits(in: .vertical) {
            content
                .padding(.top, 56)
                .padding(.bottom, 96)
                .frame(maxHeight: .infinity, alignment: .top)
            ScrollView { content }
                .contentMargins(.top, 56, for: .scrollContent)
                .contentMargins(.bottom, 96, for: .scrollContent)
        }
        .overlay(alignment: .topTrailing) { toolGroup.padding(.trailing, 16) }
        .sheet(isPresented: $showLogin) { LoginView() }
        .fullScreenCover(isPresented: $showScanner, onDismiss: openScanned) {
            QRScannerView { scanned = $0 }
        }
    }

    private func openScanned() {
        guard let url = scanned else { return }
        scanned = nil
        openURL(url)
    }

    private var toolGroup: some View {
        HStack(spacing: 0) {
            toolButton("viewfinder", "扫一扫") { showScanner = true }
            // 深色时是月亮，浅色时是太阳：图标就是当前的外观
            toolButton(scheme == .dark ? "moon.fill" : "sun.max.fill", scheme == .dark ? "深色模式，点按切换为浅色" : "浅色模式，点按切换为深色") {
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
            // 点头像、名字这一整块进入自己的空间
            if let mid = user.mid {
                NavigationLink(value: Route.space(mid: mid)) { profile(user, linked: true) }
                    .buttonStyle(PressableStyle())
                    .foregroundStyle(.primary)
                    .padding(.top, 8)
                    .accessibilityHint("进入个人空间")
            } else {
                profile(user, linked: false).padding(.top, 8)
            }
        } else {
            Button { showLogin = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 62))
                        .foregroundStyle(Theme.secondaryText)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("点击登录").font(.system(size: 20, weight: .bold))
                        Text("扫码、密码或验证码登录，同步关注与历史").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
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

    private func profile(_ user: NavInfo, linked: Bool) -> some View {
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
            if linked {
                HStack(spacing: 2) {
                    Text("空间")
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            }
        }
        .contentShape(.rect)
    }

    /// 动态 → 自己空间的「动态」；关注 / 粉丝 → 列表
    private func stats(mid: Int) -> some View {
        HStack {
            stat(session.stat?.dynamicCount, "动态", route: .spaceDynamics(mid: mid))
            stat(session.stat?.following, "关注", route: .relations(mid: mid, kind: .followings))
            stat(session.stat?.follower, "粉丝", route: .relations(mid: mid, kind: .followers))
        }
    }

    private func stat(_ value: Int?, _ title: String, route: Route) -> some View {
        NavigationLink(value: route) {
            VStack(spacing: 2) {
                // 不挂数字滚动效果：数据刷新本来就不带动画，这个效果从没显示过；
                // 挂着时低电量模式下切到「我的」整页平移会明显掉帧（真机逐项排查确认）
                Text(value?.biliCount ?? "-")
                    .font(.system(size: 19, weight: .bold))
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.primary)
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
