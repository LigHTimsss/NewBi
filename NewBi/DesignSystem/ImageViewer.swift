import Photos
import SwiftUI
import UIKit

struct ImageViewerRequest: Identifiable {
    let urls: [String]
    let index: Int
    var id: String { "\(index)-\(urls.first ?? "")" }
    /// 从哪张缩略图展开（缩略图用 imageZoomSource 标记了同一个地址）
    var sourceID: String { urls.indices.contains(index) ? urls[index] : "" }
}

extension EnvironmentValues {
    /// 大图展开 / 收回的 zoom 转场命名空间，由 imageViewer 提供给里面的缩略图
    @Entry var imageZoomNamespace: Namespace.ID? = nil
}

extension View {
    /// 全屏大图：从缩略图直接放大展开（关闭时缩回去），左右翻页、双指 / 双击缩放、下滑或返回退出；
    /// 右上角「…」可以保存到相册或分享
    func imageViewer(_ request: Binding<ImageViewerRequest?>) -> some View {
        modifier(ImageViewerHost(request: request))
    }

    /// 标记缩略图：大图从这里放大展开、关闭时缩回这里
    func imageZoomSource(_ url: String) -> some View {
        modifier(ImageZoomSource(url: url))
    }
}

private struct ImageViewerHost: ViewModifier {
    @Binding var request: ImageViewerRequest?
    @Namespace private var zoom

    func body(content: Content) -> some View {
        content
            .environment(\.imageZoomNamespace, zoom)
            .fullScreenCover(item: $request) { request in
                ImageViewer(urls: request.urls, index: request.index)
                    .navigationTransition(.zoom(sourceID: request.sourceID, in: zoom))
            }
    }
}

private struct ImageZoomSource: ViewModifier {
    let url: String
    @Environment(\.imageZoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: url, in: namespace)
        } else {
            content
        }
    }
}

struct ImageViewer: View {
    let urls: [String]
    @State private var index: Int
    @State private var dragOffset: CGFloat = 0
    @State private var showActions = false
    @State private var toast: String?
    @Environment(\.dismiss) private var dismiss

    init(urls: [String], index: Int) {
        self.urls = urls
        _index = State(initialValue: index)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - Double(min(abs(dragOffset) / CGFloat(400), CGFloat(0.6))))
                .ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(urls.indices, id: \.self) { i in
                    ZoomableImage(url: urls[i])
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dragOffset)
            .simultaneousGesture(
                // 下滑关闭
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        dragOffset = max(value.translation.height, 0)
                    }
                    .onEnded { value in
                        if value.translation.height > 140 { dismiss() } else {
                            withAnimation(Motion.component) { dragOffset = 0 }
                        }
                    }
            )
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) { topBar }
        // 分享框画在大图上面（大图是全屏覆盖，App 根部的分享框会被挡住）
        .overlay { SharePanelLayer() }
        .confirmationDialog("图片", isPresented: $showActions, titleVisibility: .hidden) {
            Button("保存到手机") { save() }
            Button("分享") { share() }
            Button("取消", role: .cancel) {}
        }
        .toast($toast, bottomPadding: 60)
        // 分享框给出的提示（「图片已复制」等）平时显示在 App 根部，会被大图挡住，这里也接一份
        .toast(Binding(get: { ToastCenter.shared.message }, set: { ToastCenter.shared.message = $0 }), bottomPadding: 60)
        .animation(Motion.micro, value: index)
        .statusBarHidden()
    }

    private var topBar: some View {
        HStack {
            GlassCircleButton(systemImage: "chevron.left", label: "返回", glass: .clear) { dismiss() }
            Spacer()
            if urls.count > 1 {
                Text("\(index + 1) / \(urls.count)")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .glassEffect(.clear, in: .capsule)
            }
            Spacer()
            GlassCircleButton(systemImage: "ellipsis", label: "更多", glass: .clear) { showActions = true }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .opacity(dragOffset > 0 ? 0 : 1)
    }

    // MARK: 保存 / 分享

    private var currentURL: URL? {
        guard urls.indices.contains(index) else { return nil }
        var raw = urls[index]
        if raw.hasPrefix("//") { raw = "https:" + raw }
        return URL(string: raw.replacingOccurrences(of: "http://", with: "https://"))
    }

    /// 原图（不走列表的缩放地址，保存的是完整清晰度、原格式）
    private func originalData() async -> Data? {
        guard let url = currentURL else { return nil }
        var request = URLRequest(url: url)
        request.setValue(BiliClient.referer, forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    /// 只申请「添加照片」权限，存进系统相册
    private func save() {
        Task {
            toast = "正在保存…"
            guard let data = await originalData() else {
                toast = "图片下载失败，请稍后重试"
                return
            }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                toast = "没有相册权限，可在「设置 → NewBi → 照片」里允许添加"
                return
            }
            toast = await Self.addToLibrary(data) ? "已保存到相册" : "保存失败，请稍后重试"
        }
    }

    /// 先按原格式写入（GIF 保持动图）；相册不认的格式退回转成图片再存
    private nonisolated static func addToLibrary(_ data: Data) async -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return true
        } catch {
            guard let image = UIImage(data: data) else { return false }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                return true
            } catch {
                return false
            }
        }
    }

    private func share() {
        Task {
            guard let data = await originalData(), let image = UIImage(data: data) else {
                toast = "图片下载失败，请稍后重试"
                return
            }
            ShareCenter.shared.shareImage(image)
        }
    }
}

private struct ZoomableImage: View {
    let url: String
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        RemoteImage(url: url, size: CGSize(width: 430, height: 932), fill: false, background: .clear)
            .scaleEffect(scale * pinch)
            .gesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in
                        withAnimation(Motion.component) { scale = min(max(scale * value.magnification, 1), 4) }
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(Motion.component) { scale = scale > 1 ? 1 : 2.5 }
            }
            .accessibilityAddTraits(.isImage)
    }
}
