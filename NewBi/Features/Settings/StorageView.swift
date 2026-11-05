import SwiftUI

/// 设置 → 清理存储空间：各类缓存占多少、一键清理。离线缓存只给入口，不在这里一键删（那是用户主动下的视频）
struct StorageView: View {
    private struct Usage: Sendable {
        var images = 0
        var network = 0
        var temporary = 0
        var downloads: Int64 = 0
        var free: Int64 = 0
    }

    @State private var usage: Usage?
    @State private var clearing = false
    @State private var confirmAll = false
    @State private var toast: String?
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    private var cleanable: Int { (usage?.images ?? 0) + (usage?.network ?? 0) + (usage?.temporary ?? 0) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text(usage.map { Self.size(Int64(cleanable) + $0.downloads) } ?? "计算中…")
                        .font(.system(size: 34, weight: .bold))
                        .monospacedDigit()
                    Text(usage.map { "NewBi 占用 · 手机剩余 \(Self.size($0.free))" } ?? " ")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)

                group {
                    item("图片缓存", detail: "封面、头像、表情；清理后用到时重新下载", bytes: usage?.images) { await clearImages() }
                    divider
                    item("网络数据缓存", detail: "接口返回的数据", bytes: usage?.network) { await clearNetwork() }
                    divider
                    item("临时文件", detail: "播放、分享时留下的临时数据", bytes: usage?.temporary) { await clearTemporary() }
                }

                group {
                    NavigationLink(value: Route.downloads) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("离线缓存").font(.system(size: 16))
                                Text("下载的视频，请到离线缓存里删除").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            Text(usage.map { Self.size($0.downloads) } ?? "…")
                                .foregroundStyle(Theme.secondaryText)
                                .monospacedDigit()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .frame(minHeight: 56)
                        .contentShape(.rect)
                    }
                    .foregroundStyle(.primary)
                }

                Button {
                    confirmAll = true
                } label: {
                    Text(clearing ? "正在清理…" : "一键清理缓存")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(accent.accentFill.opacity(cleanable > 0 && !clearing ? 1 : 0.45), in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(PressableStyle())
                .disabled(cleanable == 0 || clearing)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("清理存储空间")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .background(Theme.background)
        .toast($toast)
        .task { await measure() }
        .confirmationDialog("清理图片、网络数据和临时文件？", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("清理 \(Self.size(Int64(cleanable)))", role: .destructive) {
                Task {
                    clearing = true
                    let freed = cleanable
                    await clearImages(refresh: false)
                    await clearNetwork(refresh: false)
                    await clearTemporary(refresh: false)
                    await measure()
                    clearing = false
                    toast = "已清理 \(Self.size(Int64(freed)))"
                }
            }
        } message: {
            Text("不会删除离线缓存的视频")
        }
    }

    // MARK: 行

    private func group(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Theme.card, in: .rect(cornerRadius: 22))
    }

    private var divider: some View {
        Theme.separator.frame(height: 1).padding(.trailing, -16)
    }

    private func item(_ title: String, detail: String, bytes: Int?, clear: @escaping () async -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Text(bytes.map { Self.size(Int64($0)) } ?? "…")
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
            Button("清理") {
                Task {
                    let freed = bytes ?? 0
                    await clear()
                    toast = "已清理 \(Self.size(Int64(freed)))"
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle((bytes ?? 0) > 0 ? accent.accentText(scheme) : Theme.secondaryText)
            .disabled((bytes ?? 0) == 0 || clearing)
        }
        .frame(minHeight: 56)
    }

    // MARK: 统计与清理

    private func measure() async {
        let images = await ImagePipeline.shared.diskUsage()
        let measured = await Task.detached(priority: .userInitiated) { () -> Usage in
            let disk = DownloadPaths.usage()
            return Usage(
                images: 0,
                network: URLCache.shared.currentDiskUsage,
                temporary: Int(Self.folderSize(FileManager.default.temporaryDirectory)),
                downloads: disk.used,
                free: disk.free
            )
        }.value
        var result = measured
        result.images = images
        withAnimation(Motion.micro) { usage = result }
    }

    private func clearImages(refresh: Bool = true) async {
        await ImagePipeline.shared.clearCache()
        if refresh { await measure() }
    }

    private func clearNetwork(refresh: Bool = true) async {
        URLCache.shared.removeAllCachedResponses()
        if refresh { await measure() }
    }

    /// 只清临时目录里的文件（系统随时也可能清掉它们），不碰离线缓存所在的 Application Support
    private func clearTemporary(refresh: Bool = true) async {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory
            for item in (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: item)
            }
        }.value
        if refresh { await measure() }
    }

    private nonisolated static func folderSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            for case let file as URL in enumerator {
                total += Int64((try? file.resourceValues(forKeys: keys).totalFileAllocatedSize) ?? 0)
            }
        }
        return total
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
