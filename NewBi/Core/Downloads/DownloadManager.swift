import ActivityKit
import CoreGraphics
import Foundation
import os

/// 离线缓存调度：
/// - 用后台 URLSession 下载，App 退到后台、被系统挂起甚至被杀掉后，系统会继续下载完
/// - 同时最多 2 个视频在下（每个视频视频 / 音频两路）；暂停保存续传数据，继续时断点续传
/// - 每一路只认当前这次尝试（taskIdentifier）：暂停后马上继续时，旧任务迟到的回调不会清掉新任务、覆盖续传数据
/// - 文件先装到同目录的暂存文件、校验大小再替换正式文件；装不上就是失败，不会出现在「已缓存」里
/// - 地址过期（403/404/410）时按同画质同编码重新取流，每一路最多换 3 次、逐次退避
/// - 一路失败时另一路一并停下（保留续传数据），整条记录标为失败，让出名额给排队的
/// - 封面、弹幕跟着媒体任务走：遵守「仅 Wi-Fi」，暂停 / 删除 / 失败时取消
/// - 下载中显示实况活动：灵动岛与锁屏上的总进度；结束时区分完成、暂停、失败、取消
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    private(set) var records: [DownloadRecord] = []

    /// 系统在后台下载完成后唤醒 App 时给的回调，处理完事件后调用
    @ObservationIgnored var backgroundCompletion: (() -> Void)?

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let delegate = DownloadSessionDelegate()
    /// 每一路当前这次尝试的任务。暂停 / 失败时不立即移除：等这个任务自己的完成回调到了才清，
    /// 期间同一路不会再开新任务（避免新旧两个任务同时写同一个文件）
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    /// 每一路换过几次地址（成功下完或用户手动继续时清零）
    @ObservationIgnored private var refreshes: [String: Int] = [:]
    /// 每条记录的封面 / 弹幕任务；token 防止旧任务结束时清掉新任务的登记
    @ObservationIgnored private var extras: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var activity: Activity<DownloadActivityAttributes>?
    /// 这次实况活动期间出现过的记录：结束时据此判断是全部完成、暂停、失败还是取消
    @ObservationIgnored private var activityMembers: Set<String> = []
    @ObservationIgnored private var lastActivityUpdate = Date.distantPast
    private let maxConcurrent = 2
    private static let maxRefreshes = 3

    var cached: [DownloadRecord] { records.filter { $0.state == .completed } }
    var inProgress: [DownloadRecord] { records.filter { $0.state != .completed } }

    private static var wifiOnly: Bool { UserDefaults.standard.object(forKey: "downloadWifiOnly") as? Bool ?? true }

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
        // 取流期间同一个已经加进来了（连点两次）
        guard !records.contains(where: { $0.id == id }) else { return }
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
        // 封面、弹幕在这一条真正开始下载时取（遵守仅 Wi-Fi，暂停 / 删除时一起取消）
        schedule()
    }

    // MARK: 控制

    func pause(_ id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state != .completed else { return }
        records[index].state = .paused
        cancelTasks(id)
        cancelExtras(id)
        save()
        schedule()
    }

    func resume(_ id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state != .completed else { return }
        records[index].state = .waiting
        records[index].error = nil
        // 用户手动重试：换地址的次数重新算
        for part in DownloadRecord.Part.allCases { refreshes[DownloadPaths.taskKey(id, part)] = nil }
        save()
        schedule()
    }

    /// 先把所有在下 / 排队的都标成暂停再调度：逐个暂停会让排在后面的先被拉起来、马上又被停掉
    func pauseAll() {
        for index in records.indices where records[index].state == .downloading || records[index].state == .waiting {
            records[index].state = .paused
            cancelTasks(records[index].id)
            cancelExtras(records[index].id)
        }
        save()
        schedule()
    }
    func resumeAll() { inProgress.filter { $0.state == .paused || $0.state == .failed }.map(\.id).forEach(resume) }

    func delete(_ id: String) {
        for part in DownloadRecord.Part.allCases {
            let key = DownloadPaths.taskKey(id, part)
            tasks[key]?.cancel()
            tasks[key] = nil
            refreshes[key] = nil
        }
        cancelExtras(id)
        try? FileManager.default.removeItem(at: DownloadPaths.folder(id))
        records.removeAll { $0.id == id }
        save()
        schedule()
    }

    /// 停下这条记录还在跑的任务并保留续传数据。任务登记留到它自己的完成回调到了再清
    private func cancelTasks(_ id: String) {
        for part in DownloadRecord.Part.allCases {
            let key = DownloadPaths.taskKey(id, part)
            guard let task = tasks[key] else { continue }
            let taskID = task.taskIdentifier
            task.cancel(byProducingResumeData: { data in
                guard let data else { return }
                Task { @MainActor in DownloadManager.shared.storeResumeData(data, key: key, taskID: taskID) }
            })
        }
    }

    /// 续传数据只在这一路没有更新的尝试在跑时写入（迟到的旧数据不能覆盖新一轮的）
    private func storeResumeData(_ data: Data, key: String, taskID: Int) {
        guard let (id, part) = DownloadPaths.parse(taskKey: key),
              records.contains(where: { $0.id == id && $0.state != .completed }) else { return }
        if let current = tasks[key], current.taskIdentifier != taskID { return }
        try? data.write(to: DownloadPaths.resumeData(id, part), options: .atomic)
    }

    // MARK: 调度

    /// 每次都现数正在下的个数：start 里可能失败并递归调度，事先算好的名额会过期
    private func schedule() {
        for index in records.indices where records[index].state == .waiting {
            guard records.count(where: { $0.state == .downloading }) < maxConcurrent else { break }
            start(at: index)
        }
        updateActivity(force: true)
    }

    /// 开始（或接着）下载一条记录里还没完成、也没有任务在跑的那几路
    private func start(at index: Int) {
        records[index].state = .downloading
        let record = records[index]
        var alive = false
        for part in DownloadRecord.Part.allCases {
            guard let stream = record.stream(part), !(part == .video ? record.videoDone : record.audioDone) else { continue }
            let key = DownloadPaths.taskKey(record.id, part)
            // 上一次尝试还没收尾（刚暂停又继续）：等它的完成回调到了再开
            if tasks[key] != nil {
                alive = true
                continue
            }
            let task: URLSessionDownloadTask
            if let data = try? Data(contentsOf: DownloadPaths.resumeData(record.id, part)) {
                task = session.downloadTask(withResumeData: data)
                try? FileManager.default.removeItem(at: DownloadPaths.resumeData(record.id, part))
            } else if let url = stream.urls.first {
                var request = URLRequest(url: url)
                request.allowsCellularAccess = !Self.wifiOnly
                task = session.downloadTask(with: request)
            } else {
                continue
            }
            task.taskDescription = key
            tasks[key] = task
            task.resume()
            alive = true
        }
        if !alive {
            // 两路其实都已经装好（上次只差最后一步）：直接收尾
            if record.isFinished {
                complete(index)
                save()
            } else {
                fail(index, "没有可用的下载地址，请重试")
            }
            return
        }
        fetchExtras(record)
        save()
    }

    /// 一路失败：另一路一并停下（保留续传数据），封面 / 弹幕取消，让出名额
    private func fail(_ index: Int, _ message: String) {
        let id = records[index].id
        records[index].state = .failed
        records[index].error = message
        cancelTasks(id)
        cancelExtras(id)
        save()
        schedule()
    }

    private func reattach(_ running: [URLSessionTask]) {
        for task in running {
            guard let key = task.taskDescription, let download = task as? URLSessionDownloadTask,
                  task.state == .running || task.state == .suspended else { continue }
            guard let (id, _) = DownloadPaths.parse(taskKey: key), records.contains(where: { $0.id == id }) else {
                // 记录已删除：系统那边残留的任务不再要
                task.cancel()
                continue
            }
            if let current = tasks[key], current.taskIdentifier != task.taskIdentifier {
                // 启动后这一路已经开了新任务：留新的，免得两个任务写同一个文件
                task.cancel()
                continue
            }
            tasks[key] = download
        }
        // 已暂停 / 失败的记录还有残留任务：停下并留续传数据
        for record in records where record.state != .downloading && record.state != .completed {
            cancelTasks(record.id)
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

    fileprivate func progress(key: String, taskID: Int, written: Int64, expected: Int64) {
        // 旧尝试（已暂停 / 已换地址）迟到的进度不算
        if let current = tasks[key], current.taskIdentifier != taskID { return }
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

    fileprivate func finished(_ event: TaskCompletion) {
        let key = event.key
        guard let (id, part) = DownloadPaths.parse(taskKey: key) else { return }
        // 只认当前这次尝试：同一路已经开了新任务时，旧任务的回调直接丢弃
        // （没有登记的任务也接受：App 重启后系统可能先送完成回调、再交还任务列表）
        if let current = tasks[key] {
            guard current.taskIdentifier == event.taskID else { return }
            tasks[key] = nil
        }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }

        if event.cancelled {
            // 暂停 / 失败时停下的那一路：留下续传数据；期间用户已经点了继续，就接着下
            if let data = event.resumeData { storeResumeData(data, key: key, taskID: event.taskID) }
            if records[index].state == .downloading { start(at: index) }
            return
        }

        let status = event.status ?? 200
        if [403, 404, 410].contains(status) {
            Task { await refreshAndRestart(id: id, part: part) }
            return
        }
        if let error = event.error {
            if let data = event.resumeData { storeResumeData(data, key: key, taskID: event.taskID) }
            guard records[index].state == .downloading else { return }
            fail(index, error)
            return
        }
        guard (200..<300).contains(status) else {
            guard records[index].state == .downloading else { return }
            fail(index, "下载失败（HTTP \(status)）")
            return
        }
        // 传完了但文件没装上（目录被删、空间不足、大小不对）：不算完成
        if let installError = event.installError {
            switch part {
            case .video: records[index].videoDone = false
            case .audio: records[index].audioDone = false
            }
            fail(index, installError)
            return
        }

        refreshes[key] = nil
        switch part {
        case .video: records[index].videoDone = true
        case .audio: records[index].audioDone = true
        }
        if records[index].isFinished {
            complete(index)
        }
        save()
        schedule()
    }

    /// 两路都装好：再确认一次文件都在，才标为已缓存
    private func complete(_ index: Int) {
        let record = records[index]
        let missing = DownloadRecord.Part.allCases.filter { part in
            record.stream(part) != nil && !FileManager.default.fileExists(atPath: DownloadPaths.file(record.id, part).path)
        }
        guard missing.isEmpty else {
            for part in missing {
                switch part {
                case .video: records[index].videoDone = false
                case .audio: records[index].audioDone = false
                }
            }
            fail(index, "缓存文件缺失，请重试")
            return
        }
        records[index].state = .completed
        records[index].error = nil
        // 开始时没取成的封面 / 弹幕（比如当时在蜂窝网络）现在补上
        fetchExtras(records[index])
    }

    /// 地址过期：退避后重新取流，找同画质同编码的那一路换上新地址，从头下载这一路。
    /// 每一路最多换 3 次，之后算失败（CDN 一直拒绝时不会无限换址、耗流量）
    private func refreshAndRestart(id: String, part: DownloadRecord.Part) async {
        let key = DownloadPaths.taskKey(id, part)
        let attempt = (refreshes[key] ?? 0) + 1
        guard attempt <= Self.maxRefreshes else {
            if let index = records.firstIndex(where: { $0.id == id }), records[index].state == .downloading {
                fail(index, "下载地址多次被拒绝，请稍后重试")
            }
            return
        }
        refreshes[key] = attempt
        try? await Task.sleep(for: .seconds(attempt * attempt))
        guard let record = records.first(where: { $0.id == id }) else { return }
        do {
            let info = try await BiliClient.shared.get(.playURL(bvid: record.bvid, cid: record.cid, qn: record.quality, dash: true), as: PlayURLInfo.self)
            guard let dash = info.dash else { throw DashError.noStream }
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            switch part {
            case .video:
                guard let fresh = dash.video.first(where: { $0.id == record.video.id && $0.codec == record.video.codec }) else { throw DashError.noStream }
                records[index].video = fresh
            case .audio:
                guard let fresh = dash.audio?.first(where: { $0.id == record.audio?.id }) else { throw DashError.noStream }
                records[index].audio = fresh
            }
            // 续传数据里带着旧地址，作废
            try? FileManager.default.removeItem(at: DownloadPaths.resumeData(id, part))
            save()
            // 等待期间用户暂停 / 删除 / 已经失败：只换上新地址，不重新开始
            if records[index].state == .downloading { start(at: index) }
        } catch {
            guard let index = records.firstIndex(where: { $0.id == id }), records[index].state == .downloading else { return }
            fail(index, "地址已失效，请重试")
        }
    }

    fileprivate func backgroundEventsFinished() {
        backgroundCompletion?()
        backgroundCompletion = nil
    }

    // MARK: 封面与弹幕

    /// 封面、弹幕都很小，跟着这一条的媒体任务取：仅 Wi-Fi 时只在 Wi-Fi 下取（请求本身也禁用蜂窝），
    /// 暂停 / 删除 / 失败时取消；已经存下的不再重复取
    private func fetchExtras(_ record: DownloadRecord) {
        let id = record.id
        guard extras[id] == nil else { return }
        let wifiOnly = Self.wifiOnly
        // 现在只有蜂窝：先不取，等媒体在 Wi-Fi 下载完时再补
        if wifiOnly, NetworkStatus.shared.isCellular || !NetworkStatus.shared.isOnline { return }
        let cover = record.coverSaved == true ? nil : record.cover
        let cid = record.cid
        let duration = record.duration
        let token = UUID()
        let task = Task { [weak self] in
            let saved = await Self.downloadExtras(id: id, cover: cover, cid: cid, duration: duration, allowsCellular: !wifiOnly)
            guard let self, extras[id]?.token == token else { return }
            extras[id] = nil
            if saved, let index = records.firstIndex(where: { $0.id == id }) {
                records[index].coverSaved = true
                save()
            }
        }
        extras[id] = (token, task)
    }

    private func cancelExtras(_ id: String) {
        extras.removeValue(forKey: id)?.task.cancel()
    }

    /// - Returns: 这次是否存下了封面
    private nonisolated static func downloadExtras(id: String, cover: String?, cid: Int, duration: Int, allowsCellular: Bool) async -> Bool {
        var coverSaved = false
        if let cover, let url = cover.biliResized(CGSize(width: 640, height: 360)) {
            var request = URLRequest(url: url)
            request.allowsCellularAccess = allowsCellular
            if let (data, response) = try? await MediaFetch.session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty, !Task.isCancelled,
               (try? data.write(to: DownloadPaths.cover(id), options: .atomic)) != nil {
                coverSaved = true
            }
        }
        let segments = max(1, Int(ceil(Double(duration) / 360)))
        for index in 1...segments {
            guard !Task.isCancelled else { break }
            let file = DownloadPaths.danmaku(id, segment: index)
            if FileManager.default.fileExists(atPath: file.path) { continue }
            if let data = try? await BiliClient.shared.data(.danmakuSegment(cid: cid, index: index), allowsCellular: allowsCellular),
               !Task.isCancelled {
                try? data.write(to: file, options: .atomic)
            }
        }
        return coverSaved
    }

    // MARK: 实况活动（灵动岛）

    private func updateActivity(force: Bool) {
        let active = records.filter { $0.state == .downloading || $0.state == .waiting }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if active.isEmpty {
            let state = finalState()
            activityMembers = []
            guard let activity else { return }
            self.activity = nil
            Self.endActivity(id: activity.id, state: state)
            return
        }
        activityMembers.formUnion(active.map(\.id))
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

    /// 没有在下的了：只有这次活动里的记录全部缓存好才显示「完成」；有失败的报失败，有暂停的报暂停，都删掉了算取消
    private func finalState() -> DownloadActivityAttributes.ContentState {
        let members = records.filter { activityMembers.contains($0.id) }
        let failed = members.filter { $0.state == .failed }
        let paused = members.filter { $0.state == .paused }
        let total = members.reduce(Int64(0)) { $0 + $1.totalBytes }
        let received = members.reduce(Int64(0)) { $0 + ($1.state == .completed ? $1.totalBytes : $1.receivedBytes) }
        let progress = total > 0 ? min(Double(received) / Double(total), 1) : 0
        if let first = failed.first {
            return .init(title: first.title, progress: progress, remaining: failed.count, finished: false, outcome: .failed)
        }
        if let first = paused.first {
            return .init(title: first.title, progress: progress, remaining: paused.count, finished: false, outcome: .paused)
        }
        if !members.isEmpty, members.allSatisfy({ $0.state == .completed }) {
            return .init(title: "缓存完成", progress: 1, remaining: 0, finished: true, outcome: .completed)
        }
        return .init(title: "缓存已取消", progress: progress, remaining: 0, finished: false, outcome: .cancelled)
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

    /// 启动时读索引，顺带校验：标为已缓存但文件不在了的改成失败（可重试），封面是否存下只在这里查一次文件
    private static func loadIndex() -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: DownloadPaths.index),
              var records = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return [] }
        let fm = FileManager.default
        for index in records.indices {
            let id = records[index].id
            if records[index].coverSaved == nil {
                records[index].coverSaved = fm.fileExists(atPath: DownloadPaths.cover(id).path)
            }
            guard records[index].state == .completed else { continue }
            if !fm.fileExists(atPath: DownloadPaths.file(id, .video).path) {
                records[index].videoDone = false
            }
            if records[index].audio != nil, !fm.fileExists(atPath: DownloadPaths.file(id, .audio).path) {
                records[index].audioDone = false
            }
            if !records[index].isFinished {
                records[index].state = .failed
                records[index].error = "缓存文件缺失，请重试"
            }
        }
        return records
    }
}

/// 一个下载任务的完成回调，从系统线程带回主线程的全部信息
fileprivate struct TaskCompletion: Sendable {
    let key: String
    let taskID: Int
    let status: Int?
    let error: String?
    let cancelled: Bool
    let resumeData: Data?
    /// 传输成功时文件没能装到位的原因
    let installError: String?
}

/// 后台会话的代理：在系统线程上回调，文件必须在回调里同步移走，其余转回主线程处理
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var manager: DownloadManager?
    /// 进度回调节流：每个任务最多 0.3 秒一次
    private let lastProgress = OSAllocatedUnfairLock(initialState: [Int: Date]())
    /// didFinishDownloadingTo 里装文件的结果（nil 为成功），同一任务随后的 didCompleteWithError 取走
    private let installs = OSAllocatedUnfairLock(initialState: [Int: String?]())

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        let taskID = downloadTask.taskIdentifier
        let now = Date.now
        let shouldSend = lastProgress.withLock { last -> Bool in
            if let previous = last[taskID], now.timeIntervalSince(previous) < 0.3 { return false }
            last[taskID] = now
            return true
        }
        guard shouldSend else { return }
        let manager = manager
        Task { @MainActor in
            manager?.progress(key: key, taskID: taskID, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription, let (id, part) = DownloadPaths.parse(taskKey: key) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { return } // 失败在 didCompleteWithError 里处理
        let taskID = downloadTask.taskIdentifier
        let result = Self.install(location, id: id, part: part, response: downloadTask.response)
        installs.withLock { $0[taskID] = .some(result) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        let taskID = task.taskIdentifier
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let nsError = error as NSError?
        let resumeData = nsError?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let cancelled = nsError?.code == NSURLErrorCancelled
        lastProgress.withLock { $0[taskID] = nil }
        let install = installs.withLock { $0.removeValue(forKey: taskID) }
        // 传输成功（无错误、2xx）却没有装文件的记录：当作没装上
        let succeeded = error == nil && (200..<300).contains(status ?? 200)
        let installError: String?
        if !succeeded {
            installError = nil
        } else if let install {
            installError = install // 装文件时的结果：nil 为成功
        } else {
            installError = "文件没有保存下来"
        }
        let completion = TaskCompletion(
            key: key, taskID: taskID, status: status, error: error?.localizedDescription,
            cancelled: cancelled, resumeData: resumeData, installError: installError
        )
        let manager = manager
        Task { @MainActor in manager?.finished(completion) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let manager = manager
        Task { @MainActor in manager?.backgroundEventsFinished() }
    }

    /// 系统给的临时文件在回调返回后就会被删：先移到同目录的暂存文件、校验大小，再替换正式文件
    /// （替换失败时旧文件还在）。返回失败原因，成功为 nil
    private static func install(_ location: URL, id: String, part: DownloadRecord.Part, response: URLResponse?) -> String? {
        let fm = FileManager.default
        let destination = DownloadPaths.file(id, part)
        let staging = destination.appendingPathExtension("staging")
        // 目录不在了（记录已删除）：不重建，免得留下孤儿文件
        guard fm.fileExists(atPath: DownloadPaths.folder(id).path) else { return "缓存目录已被删除" }
        do {
            try? fm.removeItem(at: staging)
            try fm.moveItem(at: location, to: staging)
            let size = (try fm.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value ?? 0
            let expected = expectedSize(response)
            guard size > 0, expected == nil || size == expected else {
                try? fm.removeItem(at: staging)
                return "文件不完整，请重试"
            }
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
            return nil
        } catch {
            try? fm.removeItem(at: staging)
            return "保存文件失败：\(error.localizedDescription)"
        }
    }

    /// 完整文件应有的大小：206（续传）取 Content-Range 里的总长，200 取 Content-Length；有压缩编码或未知时不校验
    private static func expectedSize(_ response: URLResponse?) -> Int64? {
        guard let http = response as? HTTPURLResponse else { return nil }
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" { return nil }
        if http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
            return total
        }
        if http.statusCode == 200, http.expectedContentLength > 0 { return http.expectedContentLength }
        return nil
    }
}
