import SwiftUI

/// 投币面板：选 1 / 2 枚（一个视频最多 2 枚），可同时点赞。选中的硬币翻转一圈，确认后落下
struct CoinSheet: View {
    let model: VideoDetailModel
    var onDone: (String) -> Void
    @State private var count: Int
    @State private var alsoLike = true
    @State private var isSending = false
    @State private var dropped = false
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    init(model: VideoDetailModel, onDone: @escaping (String) -> Void) {
        self.model = model
        self.onDone = onDone
        // 已投 1 枚时只能再投 1 枚
        _count = State(initialValue: model.maxCoins - model.coins >= 2 ? 2 : 1)
    }

    private var remaining: Int { model.maxCoins - model.coins }

    var body: some View {
        VStack(spacing: 18) {
            Text(model.coins > 0 ? "已投 \(model.coins) 枚，还能再投 \(remaining) 枚" : "给 UP 主投币")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 22)

            HStack(spacing: 18) {
                choice(1)
                choice(2).disabled(remaining < 2)
            }

            if !model.isLiked {
                Toggle("同时点赞", isOn: $alsoLike)
                    .font(.system(size: 15))
                    .padding(.horizontal, 28)
            }

            Button(action: send) {
                Text(isSending ? "投币中…" : "投 \(count) 枚")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.glassProminent)
            .tint(accent)
            .disabled(isSending)
            .padding(.horizontal, 24)

            if let money = session.user?.money {
                Text("硬币余额 \(money.formatted(.number.precision(.fractionLength(0...1))))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.bottom, 12)
        .presentationDetents([.height(model.isLiked ? 330 : 380)])
        .presentationBackground(.regularMaterial)
        .sensoryFeedback(.selection, trigger: count)
        .sensoryFeedback(.success, trigger: dropped)
    }

    private func choice(_ n: Int) -> some View {
        let on = n == count
        return Button {
            withAnimation(Motion.component) { count = n }
        } label: {
            VStack(spacing: 10) {
                HStack(spacing: -10) {
                    ForEach(0..<n, id: \.self) { index in
                        Image(systemName: "b.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(on ? accent.accentText(scheme) : Theme.secondaryText)
                            // 选中时翻转一圈；确认后往下落
                            .rotation3DEffect(.degrees(on ? 360 : 0), axis: (0, 1, 0))
                            .animation(Motion.component.delay(Double(index) * 0.06), value: on)
                            .offset(y: dropped && on ? 60 : 0)
                            .opacity(dropped && on ? 0 : 1)
                            .animation(.easeIn(duration: 0.35).delay(Double(index) * 0.08), value: dropped)
                    }
                }
                .frame(height: 50)
                Text("\(n) 枚").font(.system(size: 14, weight: on ? .semibold : .regular))
            }
            .frame(width: 128, height: 118)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .glassEffect(on ? .regular.tint(accent.opacity(0.18)).interactive() : .regular.interactive(), in: .rect(cornerRadius: 22))
        .accessibilityLabel("投 \(n) 枚硬币")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func send() {
        isSending = true
        let like = alsoLike && !model.isLiked
        Task {
            do {
                try await model.addCoins(count, alsoLike: like)
                dropped = true
                await session.refresh() // 刷新硬币余额
                try? await Task.sleep(for: .milliseconds(450))
                onDone(like ? "投币成功，已同时点赞" : "投币成功")
                dismiss()
            } catch {
                isSending = false
                onDone(error.localizedDescription)
            }
        }
    }
}
