import SwiftUI
import ImageIO

/// 解码好的图片的内存缓存，主线程可同步读：滚回来的卡片、舞台上的封面在第一帧就有图，不闪、不再淡入一次。
/// NSCache 本身线程安全，管线（后台）写、视图（主线程）读。
final class ImageMemory: @unchecked Sendable {
    static let shared = ImageMemory()

    private let exact = NSCache<NSURL, UIImage>()
    /// 同一张图（去掉尺寸后缀）最近解码过的任意尺寸：要的尺寸还在路上时先拿它顶上
    /// （比如视频页的大封面先用卡片上那张小图，展开时画面不留白）
    private let anySize = NSCache<NSString, UIImage>()

    init() {
        exact.totalCostLimit = 80 * 1024 * 1024
        anySize.totalCostLimit = 30 * 1024 * 1024
    }

    func image(for url: URL) -> UIImage? {
        exact.object(forKey: url as NSURL)
    }

    /// 清理存储空间时一并清掉内存里的图
    func removeAll() {
        exact.removeAllObjects()
        anySize.removeAllObjects()
    }

    func anySize(for url: URL) -> UIImage? {
        anySize.object(forKey: Self.base(url))
    }

    func store(_ image: UIImage, for url: URL) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        exact.setObject(image, forKey: url as NSURL, cost: cost)
        anySize.setObject(image, forKey: Self.base(url), cost: cost)
    }

    /// 同一张图的「任意尺寸」键：B 站图去掉 `@…` 尺寸后缀；本地文件去掉 `#宽x高` 尺寸标记
    private static func base(_ url: URL) -> NSString {
        if url.isFileURL { return url.path as NSString }
        let string = url.absoluteString
        guard let at = string.firstIndex(of: "@") else { return string as NSString }
        return String(string[..<at]) as NSString
    }
}

/// 轻量图片管线：URLCache 磁盘缓存 + 内存缓存（ImageMemory）+ ImageIO 下采样。
/// 不用 AsyncImage（无缓存、按原图解码），也不引第三方库。
/// - 同一地址同时只下载一次；显示中的请求离屏（.task 取消）且没有别人在等时取消下载
/// - 预取排队、限并发，把连接留给正在显示的图；排队太长时丢掉最早的（用户已经滑过去了）
actor ImagePipeline {
    static let shared = ImagePipeline()

    private struct Entry {
        let task: Task<UIImage?, Never>
        /// 正在等它的显示请求数
        var consumers: Int
        /// 预取发起的：显示请求都离开了也继续下完（滑回来时内存里就有）
        var prefetched = false
    }

    private static let maxPrefetching = 3
    private static let prefetchBacklog = 30

    private let session: URLSession
    /// 图片的磁盘缓存（200 MB），「设置 → 清理存储空间」里显示和清理
    private let diskCache = URLCache(memoryCapacity: 0, diskCapacity: 200 * 1024 * 1024)
    private var inflight: [URL: Entry] = [:]
    private var prefetchQueue: [(url: URL, maxPixel: CGFloat)] = []
    private var prefetching = 0

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = diskCache
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpAdditionalHeaders = ["Referer": "https://www.bilibili.com/"]
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
    }

    /// 图片磁盘缓存占用（字节）
    func diskUsage() -> Int { diskCache.currentDiskUsage }

    /// 清掉磁盘和内存里的图片缓存（之后用到再重新下载）
    func clearCache() {
        diskCache.removeAllCachedResponses()
        ImageMemory.shared.removeAll()
    }

    func image(for url: URL, maxPixel: CGFloat, priority: TaskPriority = .userInitiated) async -> UIImage? {
        if let cached = ImageMemory.shared.image(for: url) { return cached }
        let task: Task<UIImage?, Never>
        if var entry = inflight[url] {
            // 加入已在进行的下载（可能是预取发起的：等待会把它的优先级抬上来）
            entry.consumers += 1
            inflight[url] = entry
            task = entry.task
        } else {
            task = load(url, maxPixel: maxPixel, priority: priority)
            inflight[url] = Entry(task: task, consumers: 1)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.leave(url, task) }
        }
    }

    /// 预取：列表新一页到了就把封面下载、解码好，滑到时直接从内存出图
    func prefetch(_ urls: [URL], maxPixel: CGFloat) {
        for url in urls where ImageMemory.shared.image(for: url) == nil && inflight[url] == nil
            && !prefetchQueue.contains(where: { $0.url == url }) {
            prefetchQueue.append((url, maxPixel))
        }
        if prefetchQueue.count > Self.prefetchBacklog {
            prefetchQueue.removeFirst(prefetchQueue.count - Self.prefetchBacklog)
        }
        pumpPrefetch()
    }

    private func pumpPrefetch() {
        while prefetching < Self.maxPrefetching, !prefetchQueue.isEmpty {
            let (url, maxPixel) = prefetchQueue.removeFirst()
            guard ImageMemory.shared.image(for: url) == nil, inflight[url] == nil else { continue }
            let task = load(url, maxPixel: maxPixel, priority: .utility)
            inflight[url] = Entry(task: task, consumers: 0, prefetched: true)
            prefetching += 1
            Task {
                _ = await task.value
                self.prefetchFinished()
            }
        }
    }

    private func prefetchFinished() {
        prefetching -= 1
        pumpPrefetch()
    }

    /// 下载、解码都放到后台，不占用 actor 串行队列，也不占主线程；结束时自己从 inflight 里摘掉
    private func load(_ url: URL, maxPixel: CGFloat, priority: TaskPriority) -> Task<UIImage?, Never> {
        let session = session
        let task = Task.detached(priority: priority) { () -> UIImage? in
            let image: UIImage?
            if url.isFileURL {
                // 离线缓存的封面：直接从文件下采样（地址里的 #宽x高 只是缓存键）
                image = Self.downsample(file: URL(filePath: url.path), maxPixel: maxPixel)
            } else {
                guard let (data, _) = try? await session.data(from: url), !Task.isCancelled else { return nil }
                image = Self.downsample(data, maxPixel: maxPixel)
            }
            if let image { ImageMemory.shared.store(image, for: url) }
            return image
        }
        Task { [weak self] in
            _ = await task.value
            await self?.finished(url, task)
        }
        return task
    }

    private func finished(_ url: URL, _ task: Task<UIImage?, Never>) {
        if inflight[url]?.task == task { inflight[url] = nil }
    }

    /// 显示请求离屏：没人再等这张图（也不是预取）就取消下载
    private func leave(_ url: URL, _ task: Task<UIImage?, Never>) {
        guard var entry = inflight[url], entry.task == task else { return }
        entry.consumers -= 1
        if entry.consumers <= 0, !entry.prefetched {
            task.cancel()
            inflight[url] = nil
        } else {
            inflight[url] = entry
        }
    }

    private static func downsample(file url: URL, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return thumbnail(source, maxPixel: maxPixel)
    }

    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return thumbnail(source, maxPixel: maxPixel)
    }

    private static func thumbnail(_ source: CGImageSource, maxPixel: CGFloat) -> UIImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// 远程图片，填满调用方给的 frame。`size` 是预估显示尺寸（pt），
/// 用于向 B 站请求服务端裁剪图并按像素下采样。
/// 内存里已经有这张图（同尺寸，或者先拿别的尺寸顶上）时第一帧就画出来，不走异步、不淡入
struct RemoteImage: View {
    let url: String?
    let size: CGSize
    /// true 裁切铺满（列表封面）；false 完整显示（大图查看）
    var fill = true
    var background: Color = Theme.card
    @State private var loaded: Loaded?
    @Environment(\.displayScale) private var scale

    private struct Loaded {
        let url: URL
        let image: UIImage
    }

    var body: some View {
        let request = Self.request(url, size: size, scale: scale, fill: fill)
        let memory = ImageMemory.shared
        let shown = image(for: request)
        background
            .overlay {
                if let shown {
                    Image(uiImage: shown)
                        .resizable()
                        .aspectRatio(contentMode: fill ? .fill : .fit)
                        .transition(.opacity.animation(Motion.micro))
                }
            }
            .clipped()
            .task(id: request) {
                guard let request, memory.image(for: request) == nil else { return }
                let pixel = CGSize(width: size.width * scale, height: size.height * scale)
                if let image = await ImagePipeline.shared.image(for: request, maxPixel: max(pixel.width, pixel.height)),
                   !Task.isCancelled {
                    loaded = Loaded(url: request, image: image)
                }
            }
    }

    /// 刚加载好的 → 内存里同尺寸的 → 内存里别的尺寸（先顶上）
    private func image(for request: URL?) -> UIImage? {
        if let loaded, loaded.url == request { return loaded.image }
        guard let request else { return nil }
        return ImageMemory.shared.image(for: request) ?? ImageMemory.shared.anySize(for: request)
    }

    /// 实际请求的地址（服务端按像素裁好）：显示和预取用同一套规则，才能命中同一份缓存
    static func request(_ url: String?, size: CGSize, scale: CGFloat, fill: Bool = true) -> URL? {
        let pixel = CGSize(width: size.width * scale, height: size.height * scale)
        // 本地文件（离线缓存的封面）：保留原路径，不拼图床的尺寸后缀；尺寸放进片段里，让不同尺寸各有缓存键
        if let url, url.hasPrefix("file:"), var components = URLComponents(string: url) {
            components.fragment = "\(Int(pixel.width))x\(Int(pixel.height))"
            return components.url
        }
        // 完整显示时只限宽，不让服务端裁切
        return fill ? url?.biliResized(pixel) : url?.biliResized(width: pixel.width)
    }

    /// 预取一批封面（和显示时同样的尺寸）
    static func prefetch(_ urls: [String], size: CGSize, scale: CGFloat) {
        let requests = urls.compactMap { request($0, size: size, scale: scale) }
        guard !requests.isEmpty else { return }
        let maxPixel = max(size.width, size.height) * scale
        Task { await ImagePipeline.shared.prefetch(requests, maxPixel: maxPixel) }
    }
}

extension String {
    /// B 站图床支持 `@{w}w_{h}h_1c.webp` 服务端裁剪：省流量、省解码
    func biliResized(_ pixel: CGSize) -> URL? {
        guard let base = biliBase else { return nil }
        return URL(string: base + "@\(Int(pixel.width))w_\(Int(pixel.height))h_1c.webp")
    }

    /// 只限宽、保持原比例（大图查看）
    func biliResized(width: CGFloat) -> URL? {
        guard let base = biliBase else { return nil }
        return URL(string: base + "@\(Int(width))w.webp")
    }

    private var biliBase: String? {
        guard !isEmpty else { return nil }
        var base = hasPrefix("//") ? "https:" + self : self
        base = base.replacingOccurrences(of: "http://", with: "https://")
        if let at = base.firstIndex(of: "@") { base = String(base[..<at]) }
        return base
    }
}
