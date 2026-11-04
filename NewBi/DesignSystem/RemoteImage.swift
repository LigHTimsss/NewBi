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

    func anySize(for url: URL) -> UIImage? {
        anySize.object(forKey: Self.base(url))
    }

    func store(_ image: UIImage, for url: URL) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        exact.setObject(image, forKey: url as NSURL, cost: cost)
        anySize.setObject(image, forKey: Self.base(url), cost: cost)
    }

    private static func base(_ url: URL) -> NSString {
        let string = url.absoluteString
        guard let at = string.firstIndex(of: "@") else { return string as NSString }
        return String(string[..<at]) as NSString
    }
}

/// 轻量图片管线：URLCache 磁盘缓存 + 内存缓存（ImageMemory）+ ImageIO 下采样。
/// 不用 AsyncImage（无缓存、按原图解码），也不引第三方库。
actor ImagePipeline {
    static let shared = ImagePipeline()

    private let session: URLSession
    private var inflight: [URL: Task<UIImage?, Never>] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 200 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpAdditionalHeaders = ["Referer": "https://www.bilibili.com/"]
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
    }

    func image(for url: URL, maxPixel: CGFloat, priority: TaskPriority = .userInitiated) async -> UIImage? {
        if let cached = ImageMemory.shared.image(for: url) { return cached }
        if let task = inflight[url] { return await task.value }

        let session = session
        // 下载、解码都放到后台，不占用 actor 串行队列，也不占主线程
        let task = Task.detached(priority: priority) { () -> UIImage? in
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            guard let image = Self.downsample(data, maxPixel: maxPixel) else { return nil }
            ImageMemory.shared.store(image, for: url)
            return image
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        return image
    }

    /// 预取：列表新一页到了就把封面下载、解码好，滑到时直接从内存出图
    func prefetch(_ urls: [URL], maxPixel: CGFloat) {
        for url in urls where ImageMemory.shared.image(for: url) == nil && inflight[url] == nil {
            Task { _ = await image(for: url, maxPixel: maxPixel, priority: .utility) }
        }
    }

    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
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
        let shown: UIImage? = if let loaded, loaded.url == request {
            loaded.image
        } else if let request {
            memory.image(for: request) ?? memory.anySize(for: request)
        } else {
            nil
        }
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
                if let image = await ImagePipeline.shared.image(for: request, maxPixel: max(pixel.width, pixel.height)) {
                    loaded = Loaded(url: request, image: image)
                }
            }
    }

    /// 实际请求的地址（服务端按像素裁好）：显示和预取用同一套规则，才能命中同一份缓存
    static func request(_ url: String?, size: CGSize, scale: CGFloat, fill: Bool = true) -> URL? {
        let pixel = CGSize(width: size.width * scale, height: size.height * scale)
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
