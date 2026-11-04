import SwiftUI

/// 视频详情「收藏」：选择要放进哪些收藏夹（可多选，B 站同款交互）
struct FavoriteSheet: View {
    let aid: Int
    let mid: Int
    /// 保存成功后回调：是否仍在任一收藏夹中
    var onSaved: (Bool) -> Void

    @State private var folders: [FavFolder] = []
    @State private var original: Set<Int> = []
    @State private var selected: Set<Int> = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            List {
                ForEach(folders) { folder in
                    let on = selected.contains(folder.id)
                    Button {
                        withAnimation(Motion.micro) {
                            if on { selected.remove(folder.id) } else { selected.insert(folder.id) }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.title).font(.system(size: 16)).foregroundStyle(.primary)
                                Text("\(folder.mediaCount) 个内容").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundStyle(on ? accent.accentText(scheme) : Theme.secondaryText)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                } else if let error {
                    ContentUnavailableView("加载失败", systemImage: "wifi.exclamationmark", description: Text(error))
                }
            }
            .navigationTitle("收藏到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { Task { await save() } }
                        .disabled(isLoading || isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sensoryFeedback(.selection, trigger: selected)
        .task { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            let result = try await BiliClient.shared.get(.favFoldersForVideo(mid: mid, aid: aid), as: FavFolderPage.self)
            folders = result.list ?? []
            original = Set(folders.filter { $0.favState == 1 }.map(\.id))
            // 还没收藏过时默认勾选第一个（默认收藏夹），与 B 站一致
            selected = original.isEmpty ? Set(folders.prefix(1).map(\.id)) : original
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        let add = selected.subtracting(original), remove = original.subtracting(selected)
        guard !add.isEmpty || !remove.isEmpty else {
            dismiss()
            return
        }
        guard let csrf = BiliClient.csrfToken else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await BiliClient.shared.post(.favDeal, form: [
                "rid": "\(aid)", "type": "2",
                "add_media_ids": add.map(String.init).joined(separator: ","),
                "del_media_ids": remove.map(String.init).joined(separator: ","),
                "csrf": csrf,
            ])
            onSaved(!selected.isEmpty)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
