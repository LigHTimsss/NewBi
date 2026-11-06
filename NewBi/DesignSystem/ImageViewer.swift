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
            .contextMenu {
                Button("保存到手机", systemImage: "square.and.arrow.down") { ViewerImageAction.save(ViewerImageAction.url(url)) }
                Button("分享", systemImage: "square.and.arrow.up") { ViewerImageAction.share(ViewerImageAction.url(url)) }
            }
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
                    ZoomableImage(url: urls[i], onMore: openActions)
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
        .overlay {
            ImageActionMenu(showActions: $showActions, url: currentURL, save: ViewerImageAction.save, share: ViewerImageAction.share)
        }
        // 分享框画在大图上面（大图是全屏覆盖，App 根部的分享框会被挡住）
        .overlay { SharePanelLayer() }
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
            GlassCircleButton(systemImage: "ellipsis", label: "更多", glass: .clear, action: openActions)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .opacity(dragOffset > 0 ? 0 : 1)
    }

    private func openActions() {
        withAnimation(Motion.component) { showActions = true }
    }

    // MARK: 保存 / 分享

    private var currentURL: URL? {
        guard urls.indices.contains(index) else { return nil }
        return ViewerImageAction.url(urls[index])
    }
}

@MainActor
private enum ViewerImageAction {
    static func url(_ source: String) -> URL? {
        var raw = source
        if raw.hasPrefix("//") { raw = "https:" + raw }
        return URL(string: raw.replacingOccurrences(of: "http://", with: "https://"))
    }

    /// 原图（不走列表的缩放地址，保存的是完整清晰度、原格式）
    private static func originalData(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(BiliClient.referer, forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    /// 只申请「添加照片」权限，存进系统相册
    static func save(_ url: URL?) {
        Task {
            ToastCenter.shared.show("正在保存…")
            guard let data = await originalData(url) else {
                ToastCenter.shared.show("图片下载失败，请稍后重试")
                return
            }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                ToastCenter.shared.show("没有相册权限，可在「设置 → NewBi → 照片」里允许添加")
                return
            }
            ToastCenter.shared.show(await addToLibrary(data) ? "已保存到相册" : "保存失败，请稍后重试")
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

    static func share(_ url: URL?) {
        Task {
            guard let data = await originalData(url), let image = UIImage(data: data) else {
                ToastCenter.shared.show("图片下载失败，请稍后重试")
                return
            }
            ShareCenter.shared.shareImage(image)
        }
    }
}

private struct ZoomableImage: View {
    let url: String
    let onMore: () -> Void
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
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5, maximumDistance: 10).onEnded { _ in onMore() })
            .accessibilityAction(named: "更多", onMore)
            .accessibilityAddTraits(.isImage)
    }
}


private struct ImageActionMenu: View {
    @Binding var showActions: Bool
    let url: URL?
    let save: (URL?) -> Void
    let share: (URL?) -> Void
    @State private var closingActions = false

    // MARK: 「…」面板：从底部滑出、停在底部

    var body: some View {
        ZStack(alignment: .bottom) {
            if showActions {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { dismissActions() }
                    .accessibilityLabel("关闭")
                    .transition(.opacity)
                VStack(spacing: 10) {
                    VStack(spacing: 0) {
                        actionRow("保存到手机", icon: "square.and.arrow.down") {
                            let selectedURL = url
                            dismissActions { save(selectedURL) }
                        }
                        Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5).padding(.horizontal, 16)
                        actionRow("分享", icon: "square.and.arrow.up") {
                            let selectedURL = url
                            dismissActions { share(selectedURL) }
                        }
                    }
                    .glassEffect(.regular, in: .rect(cornerRadius: 26, style: .continuous))
                    Button { dismissActions() } label: {
                        Text("取消")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .contentShape(.rect)
                    }
                    .buttonStyle(PressableStyle())
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26, style: .continuous))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: 520)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom))
                .accessibilityAddTraits(.isModal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background {
            if closingActions { Color.clear.contentShape(.rect).onTapGesture {} }
        }
        .allowsHitTesting(showActions || closingActions)
    }

    private func actionRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 18)).frame(width: 24)
                Text(title).font(.system(size: 17))
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 56)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
    }

    private func dismissActions(then next: (@MainActor () -> Void)? = nil) {
        guard showActions, !closingActions else { return }
        closingActions = true
        withAnimation(.timingCurve(0.4, 0, 0.9, 0.6, duration: 0.3), completionCriteria: .removed) {
            showActions = false
        } completion: {
            closingActions = false
            next?()
        }
    }
}
