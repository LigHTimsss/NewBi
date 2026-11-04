import SwiftUI

/// 视频卡片 ⇄ 视频页 ⇄ 迷你播放胶囊 的连贯缩放转场。
///
/// - 列表里的视频卡片用 `.zoomSource(card)` 标成转场源：点进去时卡片展开铺满屏幕，返回时收回卡片。
/// - 视频页用 `.zoomDestination(id:)`，id 固定为打开它的那张卡片。系统在推入时就记下这个 id，
///   之后再改不起作用，所以不能靠「换目标 id」收进胶囊。
/// - 反过来换「谁拿着这个 id」：每个非视频页面在迷你播放条的位置放一个透明的胶囊位（`miniSlot`）。
///   胶囊位必须在页面里：放在 NavigationStack 外层时系统找不到它，返回时只会淡出「直接消失」。
///   视频正在播放时（或迷你条显示中），返回后会露出的那一页的胶囊位代领这个视频的 id（`ZoomRouting.slotID`），
///   列表里那张卡片暂时换成别的 id，于是返回时系统按 id 找到的是胶囊位，视频页收缩进胶囊，
///   随后真正的迷你条在原地出现；点迷你条回到视频页时，也从胶囊位展开。
///   暂停 / 播完时胶囊位交还 id，返回时照常收回卡片。
/// - 同一时间只有一个胶囊位拿着视频的 id（`slotOwner`）：同 id 的转场源有多个时会配错。
enum ZoomID {
    static let mini = "newbi.mini"
    static func card(_ card: VideoCard) -> String { "video.\(card.bvid)" }
}

/// 胶囊位现在代领的转场 id
@MainActor
@Observable
final class ZoomRouting {
    static let shared = ZoomRouting()
    /// 由胶囊位代领的视频转场 id；nil 时胶囊位用自己的 id，不和任何卡片冲突
    var slotID: String?
    /// 哪个页面的胶囊位拿着 id：最近一次出现的那个（视频页没有胶囊位，所以推入视频页时
    /// 下面那一页仍是主人，返回时正好收进它的胶囊位）。其它页面的胶囊位用各自不会被找的 id
    var slotOwner: UUID?

    /// 某个视频不再需要胶囊位（暂停、关掉迷你条）时交还；只交还自己的，不清掉别的视频的
    func release(_ id: String) {
        if slotID == id { slotID = nil }
    }
}

extension EnvironmentValues {
    /// RootView 提供的全局转场命名空间（所有页面共用，才能跨页面配对）
    @Entry var zoomNamespace: Namespace.ID? = nil
}

extension View {
    /// 标成视频页的缩放转场源
    func zoomSource(_ card: VideoCard, cornerRadius: CGFloat = 14) -> some View {
        modifier(ZoomSource(id: ZoomID.card(card), cornerRadius: cornerRadius))
    }

    /// 视频页：从 id 对应的源展开，返回时收回到（届时拿着这个 id 的）源
    func zoomDestination(id: String) -> some View {
        modifier(ZoomDestination(id: id))
    }

    /// 在这一页底部迷你播放条的位置放一个透明胶囊位（视频页不要放）
    func miniSlot(bottom: CGFloat) -> some View {
        modifier(MiniSlotHost(bottom: bottom))
    }
}

private struct MiniSlotHost: ViewModifier {
    let bottom: CGFloat
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                MiniSlot(token: token).padding(.bottom, bottom)
            }
            .onAppear { ZoomRouting.shared.slotOwner = token }
    }
}

private struct ZoomSource: ViewModifier {
    let id: String
    let cornerRadius: CGFloat
    @Environment(\.zoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            // 被胶囊位代领时换成一个不会被找的 id（只换参数、不增删修饰符，卡片不重建、图片不重新淡入）
            let claimed = ZoomRouting.shared.slotID == id
            content.matchedTransitionSource(id: claimed ? id + "#mini" : id, in: namespace) { source in
                source.clipShape(.rect(cornerRadius: cornerRadius))
            }
        } else {
            content
        }
    }
}

private struct ZoomDestination: ViewModifier {
    let id: String
    @Environment(\.zoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

/// 迷你播放条的「影子」：和 MiniPlayerBar 同样大小、同样位置，不可见、不接触摸
private struct MiniSlot: View {
    let token: UUID
    @Environment(\.zoomNamespace) private var namespace

    private var id: String {
        let routing = ZoomRouting.shared
        if routing.slotOwner == token, let claimed = routing.slotID { return claimed }
        return ZoomID.mini + "." + token.uuidString
    }

    var body: some View {
        if let namespace {
            Capsule()
                .fill(Color.white.opacity(0.001))
                .frame(height: 56)
                .matchedTransitionSource(id: id, in: namespace) { source in
                    // 只支持 RoundedRectangle：半径取高度一半即胶囊
                    source.clipShape(.rect(cornerRadius: 28))
                }
                .padding(.horizontal, 18)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
