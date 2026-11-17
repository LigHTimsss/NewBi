import Foundation

/// 仅保存列表元数据，图片仍由 ImagePipeline 管理；磁盘读写不占主线程。
actor HomeFeedCache {
    static let shared = HomeFeedCache()
    struct Snapshot: Codable, Sendable {
        let items: [VideoCard]
        let nextPage: Int
        let reachedEnd: Bool
    }
    private var folder: URL {
        URL.applicationSupportDirectory.appending(path: "HomeFeed", directoryHint: .isDirectory)
    }
    func read(_ key: String) -> Snapshot? {
        guard let data = try? Data(contentsOf: folder.appending(path: key + ".json")),
              data.count <= 4 * 1024 * 1024,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.nextPage > 0, snapshot.items.count <= 500 else { return nil }
        return snapshot
    }
    func write(_ snapshot: Snapshot, key: String) {
        // 超长列表保留此前有效快照，不截断列表后错误地恢复分页游标。
        guard snapshot.items.count <= 500,
              let data = try? JSONEncoder().encode(snapshot), data.count <= 4 * 1024 * 1024 else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appending(path: key + ".json"), options: .atomic)
        } catch { /* 快照失败不影响在线浏览；下次按无缓存处理。 */ }
    }
}
