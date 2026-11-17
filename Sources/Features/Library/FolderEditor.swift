import SwiftUI

/// 收藏夹增删改（需登录）
enum FavFolders {
    struct Created: Decodable, Sendable {
        let id: Int
    }

    /// 返回新收藏夹的 media_id
    static func create(title: String, intro: String, isPrivate: Bool) async throws -> Int {
        let csrf = try token()
        let result = try await BiliClient.shared.post(.favFolderAdd, form: [
            "title": title, "intro": intro, "privacy": isPrivate ? "1" : "0", "cover": "", "csrf": csrf,
        ], as: Created.self)
        return result.id
    }

    static func edit(id: Int, title: String, intro: String, isPrivate: Bool) async throws {
        let csrf = try token()
        try await BiliClient.shared.post(.favFolderEdit, form: [
            "media_id": "\(id)", "title": title, "intro": intro, "privacy": isPrivate ? "1" : "0", "cover": "", "csrf": csrf,
        ])
    }

    static func delete(id: Int) async throws {
        let csrf = try token()
        try await BiliClient.shared.post(.favFolderDelete, form: ["media_ids": "\(id)", "csrf": csrf])
    }

    private static func token() throws -> String {
        guard let csrf = BiliClient.csrfToken else { throw BiliError.api(code: -101, message: "请先登录") }
        return csrf
    }
}

/// 新建 / 编辑收藏夹：名称（≤20 字）、简介（≤200 字）、私密开关
struct FolderEditor: View {
    /// nil 为新建
    let folder: FavFolder?
    /// 保存成功：新建时带回新 id
    var onSaved: (Int) -> Void
    @State private var title: String
    @State private var intro: String
    @State private var isPrivate: Bool
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(folder: FavFolder? = nil, onSaved: @escaping (Int) -> Void) {
        self.folder = folder
        self.onSaved = onSaved
        _title = State(initialValue: folder?.title ?? "")
        _intro = State(initialValue: folder?.intro ?? "")
        _isPrivate = State(initialValue: folder?.isPrivate ?? false)
    }

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("收藏夹名称", text: $title)
                        .focused($titleFocused)
                        .onChange(of: title) { _, value in if value.count > 20 { title = String(value.prefix(20)) } }
                } header: {
                    Text("名称")
                } footer: {
                    Text("\(title.count) / 20").monospacedDigit()
                }
                Section("简介") {
                    TextField("可以不填", text: $intro, axis: .vertical)
                        .lineLimit(3...6)
                        .onChange(of: intro) { _, value in if value.count > 200 { intro = String(value.prefix(200)) } }
                }
                Section {
                    Toggle("设为私密", isOn: $isPrivate)
                } footer: {
                    Text("私密收藏夹只有自己能看到")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.system(size: 13)) }
                }
            }
            .navigationTitle(folder == nil ? "新建收藏夹" : "编辑收藏夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(folder == nil ? "创建" : "保存") { save() }
                        .disabled(trimmed.isEmpty || isSaving)
                }
            }
            .onAppear { if folder == nil { titleFocused = true } }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        isSaving = true
        Task {
            do {
                if let folder {
                    try await FavFolders.edit(id: folder.id, title: trimmed, intro: intro, isPrivate: isPrivate)
                    onSaved(folder.id)
                } else {
                    onSaved(try await FavFolders.create(title: trimmed, intro: intro, isPrivate: isPrivate))
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isSaving = false
            }
        }
    }
}
