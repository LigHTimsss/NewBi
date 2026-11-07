import SwiftUI

/// 关注状态：空间页、视频详情页共用
@MainActor
@Observable
final class RelationModel {
    let mid: Int
    private(set) var isFollowing = false
    /// 本地关注/取关带来的粉丝数变化，用于即时更新粉丝数
    private(set) var followerDelta = 0
    /// 只有用户成功执行关注才触发反馈，资料同步不增加计数。
    private(set) var followFeedback = 0

    init(mid: Int) {
        self.mid = mid
    }

    /// 名片接口已经带了关注状态时直接用
    func seed(_ following: Bool) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isFollowing = following
            followerDelta = 0
        }
    }

    func refresh() async {
        guard BiliClient.csrfToken != nil,
              let info = try? await BiliClient.shared.get(.relation(fid: mid), as: RelationInfo.self) else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isFollowing = info.attribute == 2 || info.attribute == 6
        }
    }

    /// 先改界面再请求，失败回滚
    func toggle() async throws {
        guard let csrf = BiliClient.csrfToken else { throw BiliError.api(code: -101, message: "登录后才能关注") }
        let target = !isFollowing
        isFollowing = target
        followerDelta += target ? 1 : -1
        do {
            try await BiliClient.shared.post(.relationModify, form: [
                "fid": "\(mid)", "act": target ? "1" : "2", "re_src": "11", "csrf": csrf,
            ])
            if target { followFeedback += 1 }
        } catch {
            isFollowing = !target
            followerDelta += target ? -1 : 1
            throw error
        }
    }
}

/// 关注按钮：未关注为强调色实心，已关注为浅灰；取关前二次确认
struct FollowButton: View {
    let relation: RelationModel
    /// true：按内容宽度（详情页）；false：撑满（空间页）
    var compact = false
    var onError: (String) -> Void
    @State private var confirmUnfollow = false
    @Environment(\.accent) private var accent

    var body: some View {
        let following = relation.isFollowing
        Button {
            if following { confirmUnfollow = true } else { toggle() }
        } label: {
            Label(following ? "已关注" : "关注", systemImage: following ? "checkmark" : "plus")
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(following ? Theme.secondaryText : .white)
                .padding(.horizontal, 14)
                .frame(maxWidth: compact ? nil : .infinity)
                .frame(height: 32)
                .background(following ? Theme.selection : accent.accentFill, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressableStyle())
        .animation(Motion.component, value: following)
        .sensoryFeedback(.success, trigger: relation.followFeedback)
        .confirmationDialog("确定不再关注？", isPresented: $confirmUnfollow, titleVisibility: .visible) {
            Button("不再关注", role: .destructive) { toggle() }
        }
    }

    private func toggle() {
        Task {
            do { try await relation.toggle() } catch { onError(error.localizedDescription) }
        }
    }
}
