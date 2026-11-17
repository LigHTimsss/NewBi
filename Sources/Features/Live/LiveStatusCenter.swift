import SwiftUI

/// 谁在直播：头像出现在屏幕上时登记 uid，攒 0.15 秒合成一次批量查询（一次最多 50 个），
/// 结果缓存 90 秒。只有状态真的变了才写回，滚动列表时不会让所有头像跟着重绘
@MainActor
@Observable
final class LiveStatusCenter {
    static let shared = LiveStatusCenter()

    /// 正在直播的人：uid → 直播间
    private(set) var live: [Int: LiveStatus] = [:]

    @ObservationIgnored private var checkedAt: [Int: Date] = [:]
    @ObservationIgnored private var pending: Set<Int> = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    private static let freshness: TimeInterval = 90
    private static let batchSize = 50

    func room(for mid: Int) -> LiveStatus? { live[mid] }

    /// 头像出现时调用；缓存还新鲜就什么都不做
    func watch(_ mid: Int) {
        guard mid > 0 else { return }
        if let checked = checkedAt[mid], Date.now.timeIntervalSince(checked) < Self.freshness { return }
        pending.insert(mid)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await self?.flush()
        }
    }

    /// 进直播间、下拉刷新时强制重查某个人
    func refresh(_ mid: Int) {
        checkedAt[mid] = nil
        watch(mid)
    }

    private func flush() async {
        let mids = Array(pending)
        pending.removeAll()
        flushTask = nil
        let now = Date.now
        for mid in mids { checkedAt[mid] = now }

        for start in stride(from: 0, to: mids.count, by: Self.batchSize) {
            let chunk = Array(mids[start..<min(start + Self.batchSize, mids.count)])
            guard let rooms = try? await LiveAPI.status(uids: chunk) else {
                // 查询失败：下次头像出现时再试
                for mid in chunk { checkedAt[mid] = nil }
                continue
            }
            for mid in chunk {
                let room = rooms[mid].flatMap { $0.isLive ? $0 : nil }
                if live[mid] != room { live[mid] = room }
            }
        }
    }
}

/// B 站直播的粉色
extension Color {
    static let live = Color(red: 1, green: 0.4, blue: 0.6)
}

extension EnvironmentValues {
    /// 从任何地方推入一个页面（导航栈里的页面和视频舞台上都能用）；由 RootView 注入
    @Entry var pushRoute: (@MainActor (Route) -> Void)? = nil
}

/// 圆形头像；这个人正在直播时套一圈粉色描边、底部挂「直播中」，点头像进直播间。
/// 不在直播时点按交给外层（通常是进 UP 主空间的链接）
struct LiveAvatar: View {
    let mid: Int
    let url: String?
    let size: CGFloat

    @Environment(\.pushRoute) private var pushRoute

    private var room: LiveStatus? { LiveStatusCenter.shared.room(for: mid) }

    var body: some View {
        let room = room
        RemoteImage(url: url, size: CGSize(width: size, height: size))
            .frame(width: size, height: size)
            .clipShape(.circle)
            .overlay {
                if room != nil {
                    Circle()
                        .strokeBorder(Color.live, lineWidth: max(1.5, size / 24))
                        .padding(-max(2.5, size / 16))
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                // 太小的头像（比如全屏左上角）只留描边，字放不下
                if room != nil, size >= 36 {
                    LiveTag(height: max(14, size * 0.3))
                        .alignmentGuide(.bottom) { $0[.bottom] - $0.height * 0.55 }
                        .transition(.opacity)
                }
            }
            .animation(Motion.micro, value: room?.roomID)
            .contentShape(.circle)
            // 直播中：点头像进直播间；不在直播时这个手势不生效，点按落到外层
            .gesture(TapGesture().onEnded { open() }, including: room == nil ? .subviews : .all)
            .accessibilityValue(room == nil ? "" : "直播中")
            .accessibilityHint(room == nil ? "" : "进入直播间")
            .accessibilityAddTraits(room == nil ? [] : .isButton)
            .task(id: mid) { LiveStatusCenter.shared.watch(mid) }
    }

    private func open() {
        guard let room else { return }
        pushRoute?(.live(roomID: room.roomID))
    }
}

/// 「直播中」小标签：粉底白字，外面一圈背景色把它和头像分开
struct LiveTag: View {
    var height: CGFloat = 16

    var body: some View {
        Text("直播中")
            .font(.system(size: height * 0.6, weight: .semibold))
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, height * 0.38)
            .frame(height: height)
            .background(Color.live, in: .capsule)
            .padding(1.5)
            .background(Theme.background, in: .capsule)
    }
}
