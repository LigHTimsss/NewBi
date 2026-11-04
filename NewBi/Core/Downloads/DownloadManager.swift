import ActivityKit
import CoreGraphics
import Foundation
import os

/// 离线缓存调度：
/// - 用后台 URLSession 下载，App 退到后台、被系统挂起甚至被杀掉后，系统会继续下载完
/// - 同时最多 2 个视频在下（每个视频视频 / 音频两路）；暂停保存续传数据，继续时断点续传
/// - 地址过期（403/404/410）时按同画质同编码重新取流，从头下载这一路
/// - 下载中显示实况活动：灵动岛与锁屏上的总进度
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    private(set) var records: [DownloadRecord] = []

    /// 系统在后台下载完成后唤醒 App 时给的回调，处理完事件后调用
    @ObservationIgnored var backgroundCompletion: (() -> Void)?

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let delegate = DownloadSessionDelegate()
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var activity: Activity<DownloadActivityAttributes>?
    @ObservationIgnored private var lastActivityUpdate = Date.distantPast
    private let maxConcurrent = 2

    var cached: [DownloadRecord] { records.filter { $0.state == .completed } }
    var inProgress: [DownloadRecord] { records.filter { $0.state != .completed } }

    private init() {
        let config = URLSessionConfiguration.background(withIdentifier: "com.example.newbi.downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpAdditionalHeaders = BiliClient.mediaHeaders
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        records = Self.loadIndex()
        delegate.manager = self
        // 重新接上 App 重启前还在跑的后台任务
        session.getAllTasks { tasks in
            Task { @MainActor in DownloadManager.shared.reattach(tasks) }
        }
    }

    func record(bvid: String, cid: Int? = nil) -> DownloadRecord? {
        records.first { $0.bvid == bvid && (cid == nil || $0.cid == cid) }
    }

    func completed(bvid: String, cid: Int) -> DownloadRecord? {
        records.first { $0.bvid == bvid && $0.cid == cid && $0.state == .completed }
    }

    // MARK: 添加

    /// - Parameter part: 多 P 视频时缓存的那一 P（nil 为第一 P）
    func enqueue(detail: VideoDetail, part: VideoPage? = nil, quality qn: Int) async throws {
        let cid = part?.cid ?? detail.cid
        let multiPart = (detail.pages?.count ?? 0) > 1
        let title = multiPart ? "\(detail.title) · P\(part?.page ?? 1) \(part?.part ?? "")" : detail.title
        let duration = part?.duration ?? detail.duration
        let id = DownloadRecord.id(bvid: detail.bvid, cid: cid)
        guard !records.contains(where: { $0.id == id }) else { return }
        let info = try await BiliClient.shared.get(.playURL(bvid: detail.bvid, cid: cid, qn: qn, dash: true), as: PlayURLInfo.self)
        let preference = UserDefaults.standard.string(forKey: "codecPreference") ?? "auto"
        guard let dash = info.dash,
              let selection = DashSelector.select(dash, quality: qn, codecOrder: DashSelector.codecOrder(preference: preference)) else {
            throw DashError.noStream
        }
        let name = zip(info.acceptQuality, info.acceptDescription).first { $0.0 == selection.quality }?.1 ?? "\(selection.quality)"
        let record = DownloadRecord(
            id: id, aid: detail.aid, bvid: detail.bvid, cid: cid, title: title, cover: detail.pic,
            ownerName: detail.owner.name, ownerMid: detail.owner.mid, duration: duration,
            quality: selection.quality, qualityName: name, video: selection.video, audio: selection.audio,
            state: .waiting, createdAt: .now
        )
        try? FileManager.default.createDirectory(at: DownloadPaths.folder(id), withIntermediateDirectories: true)
        records.insert(record, at: 0)
        save()
        schedule()
        // 封面、弹幕都很小，前台顺手下完，断网时也能显示
        Task.detached(priority: .utility) {
            await Self.downloadExtras(id: id, cover: detail.pic, cid: cid, duration: duration)
        }
    }

    private nonisolated static func downloadExtras(id: String, cover: String, cid: Int, duration: Int) async {
        if let url = cover.biliResized(CGSize(width: 640, height: 360)),
           let (data, _) = try? await MediaFetch.session.data(from: url) {
            try? data.write(to: DownloadPaths.cover(id))
        }
        let segments = max(1, Int(ceil(Double(duration) / 360)))
        for index in 1...segments {
            if let data = try? await BiliClient.shared.data(.danmakuSegment(cid: cid, index: index)) {
                try? data.write(to: DownloadPaths.danmaku(id, segment: index))
            }
        }
    }

    // MARK: 控制

    func pause(_ id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state != .completed else { return }
        records[index].state = .paused
        for part in DownloadRecord.Part.allCases {
            let key = DownloadPaths.taskKey(id, part)
            tasks[key]?.cancel(byProducingResumeData: { data in
                if let data { try? data.write(to: DownloadPaths.resumeData(id, part)) }
            })
            tasks[key] = nil
        }
        save()
        schedule()
    }

    func resume(_ id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state != .completed else { return }
        records[index].state = .waiting
        records[index].error = nil
        save()
        schedule()
    }

    func pauseAll() { inProgress.map(\.id).forEach(pause) }
    func resumeAll() { inProgress.filter { $0.state == .paused || $0.state == .failed }.map(\.id).forEach(resume) }

    func delete(_ id: String) {
        for part in DownloadRecord.Part.allCases {
            tasks[DownloadPaths.taskKey(id, part)]?.cancel()
            tasks[DownloadPaths.taskKey(id, part)] = nil
        }
        try? FileManager.default.removeItem(at: DownloadPaths.folder(id))
        records.removeAll { $0.id == id }
        save()
        schedule()
    }

    // MARK: 调度

    private func schedule() {
        var slots = maxConcurrent - records.filter { $0.state == .downloading }.count
        for index in records.indices where slots > 0 && records[index].state == .waiting {
            start(at: index)
            slots -= 1
        }
        updateActivity(force: true)
    }

    private func start(at index: Int) {
        records[index].state = .downloading
        let record = records[index]
        for part in DownloadRecord.Part.allCases {
            guard let stream = record.stream(part), !(part == .video ? record.videoDone : record.audioDone) else { continue }
            let key = DownloadPaths.taskKey(record.id, part)
            guard tasks[key] == nil else { continue }
            let task: URLSessionDownloadTask
            if let data = try? Data(contentsOf: DownloadPaths.resumeData(record.id, part)) {
                task = session.downloadTask(withResumeData: data)
                try? FileManager.default.removeItem(at: DownloadPaths.resumeData(record.id, part))
            } else if let url = stream.urls.first {
                var request = URLRequest(url: url)
                request.allowsCellularAccess = !(UserDefaults.standard.object(forKey: "downloadWifiOnly") as? Bool ?? true)
                task = session.downloadTask(with: request)
            } else {
                continue
            }
            task.taskDescription = key
            tasks[key] = task
            task.resume()
        }
        save()
    }

    private func reattach(_ running: [URLSessionTask]) {
        for task in running {
            guard let key = task.taskDescription, let download = task as? URLSessionDownloadTask else { continue }
            tasks[key] = download
        }
        // 记录是「下载中」但任务已经不在了（比如 App 被杀时还没开始）：重新排队
        for index in records.indices where records[index].state == .downloading {
            let id = records[index].id
            let alive = DownloadRecord.Part.allCases.contains { tasks[DownloadPaths.taskKey(id, $0)] != nil }
            if !alive, !records[index].isFinished { records[index].state = .waiting }
        }
        schedule()
    }

    // MARK: 来自后台会话的回调

    fileprivate func progress(key: String, written: Int64, expected: Int64) {
        guard let (id, part) = DownloadPaths.parse(taskKey: key), let index = records.firstIndex(where: { $0.id == id }) else { return }
        switch part {
        case .video:
            records[index].videoBytes = written
            if expected > 0 { records[index].videoTotal = expected }
        case .audio:
            records[index].audioBytes = written
            if expected > 0 { records[index].audioTotal = expected }
        }
        updateActivity(force: false)
    }

    fileprivate func finished(key: String, status: Int?, error: String?, cancelled: Bool, resumeData: Data?) {
        guard let (id, part) = DownloadPaths.parse(taskKey: key) else { return }
        tasks[key] = nil
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if let resumeData { try? resumeData.write(to: DownloadPaths.resumeData(id, part)) }
        if cancelled { return } // 暂停 / 删除

        let expired = status.map { [403, 404, 410].contains($0) } ?? false
        if expired {
            Task { await refreshAndRestart(id: id, part: part) }
            return
        }
        if error != nil || (status ?? 200) >= 400 {
            records[index].state = .failed
            records[index].error = error ?? "下载失败（HTTP \(status ?? 0)）"
            save()
            schedule()
            return
        }
        switch part {
        case .video: records[index].videoDone = true
        case .audio: records[index].audioDone = true
        }
        if records[index].isFinished {
            records[index].state = .completed
            records[index].error = nil
        }
        save()
        schedule()
    }

    /// 地址过期：重新取流，找同画质同编码的那一路换上新地址，从头下载这一路
    private func refreshAndRestart(id: String, part: DownloadRecord.Part) async {
        guard let record = records.first(where: { $0.id == id }) else { return }
        do {
            let info = try await BiliClient.shared.get(.playURL(bvid: record.bvid, cid: record.cid, qn: record.quality, dash: true), as: PlayURLInfo.self)
            guard let dash = info.dash, let index = records.firstIndex(where: { $0.id == id }) else { throw DashError.noStream }
            switch part {
            case .video:
                guard let fresh = dash.video.first(where: { $0.id == record.video.id && $0.codec == record.video.codec }) else { throw DashError.noStream }
                records[index].video = fresh
            case .audio:
                guard let fresh = dash.audio?.first(where: { $0.id == record.audio?.id }) else { throw DashError.noStream }
                records[index].audio = fresh
            }
            try? FileManager.default.removeItem(at: DownloadPaths.resumeData(id, part))
            records[index].state = .waiting
            save()
            schedule()
        } catch {
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            records[index].state = .failed
            records[index].error = "地址已失效，请重试"
            save()
        }
    }

    fileprivate func backgroundEventsFinished() {
        backgroundCompletion?()
        backgroundCompletion = nil
    }

    // MARK: 实况活动（灵动岛）

    private func updateActivity(force: Bool) {
        let active = records.filter { $0.state == .downloading || $0.state == .waiting }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if active.isEmpty {
            guard let activity else { return }
            self.activity = nil
            let state = DownloadActivityAttributes.ContentState(title: "缓存完成", progress: 1, remaining: 0, finished: true)
            Self.endActivity(id: activity.id, state: state)
            return
        }
        // 进度最多每秒刷新一次，省电
        guard force || Date.now.timeIntervalSince(lastActivityUpdate) > 1 else { return }
        lastActivityUpdate = .now
        let total = active.reduce(Int64(0)) { $0 + $1.totalBytes }
        let received = active.reduce(Int64(0)) { $0 + $1.receivedBytes }
        let state = DownloadActivityAttributes.ContentState(
            title: active.first(where: { $0.state == .downloading })?.title ?? active[0].title,
            progress: total > 0 ? min(Double(received) / Double(total), 1) : 0,
            remaining: active.count,
            finished: false
        )
        if let activity {
            Self.updateActivity(id: activity.id, state: state)
        } else {
            activity = try? Activity.request(attributes: DownloadActivityAttributes(), content: ActivityContent(state: state, staleDate: nil))
        }
    }

    // Activity 不是 Sendable：只把 id 和状态交给后台任务，在那边按 id 找回实例再更新 / 结束
    private nonisolated static func updateActivity(id: String, state: DownloadActivityAttributes.ContentState) {
        Task.detached {
            for activity in Activity<DownloadActivityAttributes>.activities where activity.id == id {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        }
    }

    private nonisolated static func endActivity(id: String, state: DownloadActivityAttributes.ContentState) {
        Task.detached {
            for activity in Activity<DownloadActivityAttributes>.activities where activity.id == id {
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(4)))
            }
        }
    }

    // MARK: 持久化

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: DownloadPaths.index, options: .atomic)
    }

    private static func loadIndex() -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: DownloadPaths.index) else { return [] }
        return (try? JSONDecoder().decode([DownloadRecord].self, from: data)) ?? []
    }
}

/// 后台会话的代理：在系统线程上回调，文件必须在回调里同步移走，其余转回主线程处理
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var manager: DownloadManager?
    /// 进度回调节流：每个任务最多 0.3 秒一次
    private let lastProgress = OSAllocatedUnfairLock(initialState: [String: Date]())

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        let now = Date.now
        let shouldSend = lastProgress.withLock { last -> Bool in
            if let previous = last[key], now.timeIntervalSince(previous) < 0.3 { return false }
            last[key] = now
            return true
        }
        guard shouldSend else { return }
        let manager = manager
        Task { @MainActor in manager?.progress(key: key, written: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription, let (id, part) = DownloadPaths.parse(taskKey: key) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard status < 400 else { return } // 失败在 didCompleteWithError 里处理
        let destination = DownloadPaths.file(id, part)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: location, to: destination)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let nsError = error as NSError?
        let resumeData = nsError?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let cancelled = nsError?.code == NSURLErrorCancelled
        let message = error?.localizedDescription
        let manager = manager
        Task { @MainActor in
            manager?.finished(key: key, status: status, error: message, cancelled: cancelled, resumeData: resumeData)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let manager = manager
        Task { @MainActor in manager?.backgroundEventsFinished() }
    }
}
