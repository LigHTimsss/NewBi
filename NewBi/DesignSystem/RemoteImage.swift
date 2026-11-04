import SwiftUI
import ImageIO

/// 轻量图片管线：URLCache 磁盘缓存 + NSCache 内存缓存 + ImageIO 下采样。
/// 不用 AsyncImage（无缓存、按原图解码），也不引第三方库。
actor ImagePipeline {
    static let shared = ImagePipeline()

    private let session: URLSession
    private let memory = NSCache<NSURL, UIImage>()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 150 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpAdditionalHeaders = ["Referer": "https://www.bilibili.com/"]
        session = URLSession(configuration: config)
        memory.totalCostLimit = 60 * 1024 * 1024
    }

    func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }
        if let task = inflight[url] { return await task.value }

        let session = session
        // 解码放到后台，不占用 actor 串行队列
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image, let cg = image.cgImage {
            memory.setObject(image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
        }
        return image
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
struct RemoteImage: View {
    let url: String?
    let size: CGSize
    /// true 裁切铺满（列表封面）；false 完整显示（大图查看）
    var fill = true
    var background: Color = Theme.card
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        background
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: fill ? .fill : .fit)
                        .transition(.opacity.animation(Motion.micro))
                }
            }
            .clipped()
        .task(id: url) {
            let px = CGSize(width: size.width * scale, height: size.height * scale)
            // 完整显示时只限宽，不让服务端裁切
            guard let url = fill ? url?.biliResized(px) : url?.biliResized(width: px.width) else { return }
            image = await ImagePipeline.shared.image(for: url, maxPixel: max(px.width, px.height))
        }
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
