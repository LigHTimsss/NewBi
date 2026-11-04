import SwiftUI

struct ImageViewerRequest: Identifiable {
    let urls: [String]
    let index: Int
    var id: String { "\(index)-\(urls.first ?? "")" }
}

extension View {
    /// 全屏大图：左右翻页、双指 / 双击缩放、下滑或点关闭退出
    func imageViewer(_ request: Binding<ImageViewerRequest?>) -> some View {
        fullScreenCover(item: request) { request in
            ImageViewer(urls: request.urls, index: request.index)
        }
    }
}

struct ImageViewer: View {
    let urls: [String]
    @State private var index: Int
    @State private var dragOffset: CGFloat = 0
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
        .overlay(alignment: .top) {
            HStack {
                GlassCircleButton(systemImage: "xmark", label: "关闭", glass: .clear) { dismiss() }
                Spacer()
                if urls.count > 1 {
                    Text("\(index + 1) / \(urls.count)")
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .glassEffect(.clear, in: .capsule)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .opacity(dragOffset > 0 ? 0 : 1)
        }
        .animation(Motion.micro, value: index)
        .statusBarHidden()
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
