import SwiftUI

/// 视频卡片 ⇄ 视频页 ⇄ 迷你播放胶囊 的连贯缩放转场。
///
/// - 列表里的视频卡片用 `.zoomSource(card)` 标成转场源：点进去时卡片展开铺满屏幕，返回时收回卡片。
/// - 每个页面底部、迷你播放条的位置放一个透明的 `MiniSlot`（同一个转场源 id `ZoomID.mini`）：
///   返回时若视频还在播放，视频页收缩进这个胶囊位，随后真正的迷你条在原地出现；
///   点迷你条回到视频页时，也是从这个胶囊位展开。
/// - 视频页用 `.zoomDestination(id:)`，id 随播放状态切换（播放中 → 胶囊，其它 → 卡片）。
enum ZoomID {
    static let mini = "newbi.mini"
    static func card(_ card: VideoCard) -> String { "video.\(card.bvid)" }
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

    /// 视频页：从 id 对应的源展开，返回时收回到（届时的）id 对应的源
    func zoomDestination(id: String) -> some View {
        modifier(ZoomDestination(id: id))
    }

    /// 在页面底部迷你播放条的位置放一个透明胶囊位
    func miniSlot(bottom: CGFloat) -> some View {
        overlay(alignment: .bottom) { MiniSlot().padding(.bottom, bottom) }
    }
}

private struct ZoomSource: ViewModifier {
    let id: String
    let cornerRadius: CGFloat
    @Environment(\.zoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace) { source in
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
    @Environment(\.zoomNamespace) private var namespace

    var body: some View {
        if let namespace {
            Capsule()
                .fill(Color.white.opacity(0.001))
                .frame(height: 56)
                .matchedTransitionSource(id: ZoomID.mini, in: namespace) { source in
                    // 只支持 RoundedRectangle：半径取高度一半即胶囊
                    source.clipShape(.rect(cornerRadius: 28))
                }
                .padding(.horizontal, 18)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
