import SwiftUI

/// 离线缓存：「已缓存 / 缓存中」两个分组，底部显示占用空间
struct DownloadsView: View {
    private enum Tab: String, CaseIterable {
        case cached = "已缓存", downloading = "缓存中"
    }

    @State private var tab: Tab = .cached
    @State private var usage: (used: Int64, free: Int64) = (0, 0)
    @State private var confirmDelete: DownloadRecord?
    private var manager: DownloadManager { DownloadManager.shared }

    var body: some View {
        let items = tab == .cached ? manager.cached : manager.inProgress
        List {
            GlassSegmented(options: Tab.allCases, selection: $tab) { item in
                let count = item == .cached ? manager.cached.count : manager.inProgress.count
                return count > 0 ? "\(item.rawValue) \(count)" : item.rawValue
            }
            .frame(maxWidth: 260)
            .frame(maxWidth: .infinity)
            .listRowBackground(Theme.background)
            .listRowSeparator(.hidden)

            ForEach(items) { record in
                Group {
                    if record.state == .completed {
                        CachedRow(record: record)
                    } else {
                        DownloadingRow(record: record)
                    }
                }
                .listRowBackground(Theme.background)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { confirmDelete = record } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }

            if items.isEmpty {
                ContentUnavailableView(
                    tab == .cached ? "还没有缓存" : "没有正在缓存的视频",
                    systemImage: "arrow.down.circle",
                    description: Text("在视频页点「缓存」，没网的时候也能看")
                )
                .listRowBackground(Theme.background)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .animation(Motion.component, value: items.map(\.id))
        .safeAreaInset(edge: .bottom) { storageBar }
        .navigationTitle("离线缓存")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if tab == .downloading, !manager.inProgress.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    let anyRunning = manager.inProgress.contains { $0.state == .downloading || $0.state == .waiting }
                    Button(anyRunning ? "全部暂停" : "全部开始") {
                        anyRunning ? manager.pauseAll() : manager.resumeAll()
                    }
                }
            }
        }
        .confirmationDialog("删除这个缓存？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible, presenting: confirmDelete) { record in
            Button("删除", role: .destructive) {
                withAnimation(Motion.component) { manager.delete(record.id) }
                refreshUsage()
            }
        } message: { record in
            Text(record.title)
        }
        .task { refreshUsage() }
        .onChange(of: manager.cached.count) { refreshUsage() }
    }

    /// 已缓存占用 / 手机剩余
    private var storageBar: some View {
        let total = max(usage.used + usage.free, 1)
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                Capsule().fill(Theme.selection)
                    .overlay(alignment: .leading) {
                        Capsule().fill(.tint).frame(width: max(geo.size.width * CGFloat(usage.used) / CGFloat(total), 4))
                    }
            }
            .frame(height: 4)
            Text("已缓存 \(Self.size(usage.used)) · 手机剩余 \(Self.size(usage.free))")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.background)
    }

    /// 遍历文件统计大小放到后台
    private func refreshUsage() {
        Task {
            usage = await Task.detached(priority: .utility) { DownloadPaths.usage() }.value
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct CachedRow: View {
    let record: DownloadRecord

    var body: some View {
        VideoLink(card: record.card) {
            HStack(spacing: 14) {
                RemoteImage(url: record.coverURL, size: CGSize(width: 128, height: 72))
                    .frame(width: 128, height: 72)
                    .overlay(alignment: .bottomTrailing) {
                        Text(record.duration.durationText)
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(5)
                    }
                    .clipShape(.rect(cornerRadius: 12))
                    .videoCover(cornerRadius: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    Text("\(record.qualityName) · \(DownloadsView.size(record.totalBytes))")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityLabel("已下载")
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
    }
}

private struct DownloadingRow: View {
    let record: DownloadRecord
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 14) {
            RemoteImage(url: record.coverURL, size: CGSize(width: 128, height: 72))
                .frame(width: 128, height: 72)
                .clipShape(.rect(cornerRadius: 12))
                .opacity(record.state == .downloading ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 6) {
                Text(record.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                ProgressView(value: record.progress)
                    .tint(record.state == .failed ? .red : accent)
                    .animation(Motion.micro, value: record.progress)
                Text(statusText)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(record.state == .failed ? .red : Theme.secondaryText)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: toggle) {
                Image(systemName: actionIcon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(accent)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(actionLabel)
        }
    }

    private var statusText: String {
        let progress = "\(DownloadsView.size(record.receivedBytes)) / \(DownloadsView.size(record.totalBytes))"
        switch record.state {
        case .downloading: return "\(Int(record.progress * 100))% · \(progress)"
        case .waiting: return "等待中 · \(record.qualityName)"
        case .paused: return "已暂停 · \(progress)"
        case .failed: return record.error ?? "下载失败，点右侧重试"
        case .completed: return record.qualityName
        }
    }

    private var actionIcon: String {
        switch record.state {
        case .downloading, .waiting: "pause.circle"
        case .paused: "play.circle"
        case .failed: "arrow.clockwise.circle"
        case .completed: "checkmark.circle"
        }
    }

    private var actionLabel: String {
        switch record.state {
        case .downloading, .waiting: "暂停"
        case .paused: "继续"
        case .failed: "重试"
        case .completed: "已完成"
        }
    }

    private func toggle() {
        switch record.state {
        case .downloading, .waiting: DownloadManager.shared.pause(record.id)
        case .paused, .failed: DownloadManager.shared.resume(record.id)
        case .completed: break
        }
    }
}

/// 视频页「缓存」：选画质后加入离线缓存
struct CacheSheet: View {
    let detail: VideoDetail
    /// 多 P 时缓存当前这一 P
    let part: VideoPage?
    let qualities: [QualityOption]
    @State private var selected: Int
    @State private var isAdding = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    init(detail: VideoDetail, part: VideoPage? = nil, qualities: [QualityOption], current: Int) {
        self.detail = detail
        self.part = part
        self.qualities = qualities.filter(\.available)
        _selected = State(initialValue: current)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(qualities) { option in
                        let on = option.id == selected
                        Button {
                            withAnimation(Motion.micro) { selected = option.id }
                        } label: {
                            HStack {
                                Text(option.name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(on ? accent.accentText(scheme) : Theme.secondaryText)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .frame(minHeight: 40)
                            .contentShape(.rect)
                        }
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                } header: {
                    if let part, (detail.pages?.count ?? 0) > 1 {
                        Text("缓存 P\(part.page) \(part.part) · 画质")
                    } else {
                        Text("缓存画质")
                    }
                } footer: {
                    Text("缓存会在后台继续，可在「我的 → 离线缓存」查看进度。弹幕一并缓存，断网也能看。")
                }
            }
            .navigationTitle("缓存视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("缓存") { add() }.disabled(isAdding)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func add() {
        isAdding = true
        Task {
            do {
                try await DownloadManager.shared.enqueue(detail: detail, part: part, quality: selected)
                ToastCenter.shared.show("已加入离线缓存")
                dismiss()
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
                isAdding = false
            }
        }
    }
}
