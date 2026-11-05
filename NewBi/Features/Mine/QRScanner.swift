import AVFoundation
import CoreImage
import PhotosUI
import SwiftUI
import Vision
import VisionKit

// MARK: - 识别结果

/// 扫到的内容要做什么：
/// - B 站视频（BV / av / b23.tv 短链）、个人空间：直接在 App 里打开
/// - 网页 / 电视的登录码：不代为确认登录（那是在替别的设备授权账号），提示用官方 App 扫
/// - 其它网址、纯文字：给出打开 / 复制，不自动跳转（防二维码钓鱼）
enum ScanTarget: Equatable {
    /// newbi:// 链接，交给 RootView 打开
    case open(URL)
    case loginCode
    case web(URL)
    case text(String)

    static func resolve(_ raw: String) async -> ScanTarget {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased() else {
            if let bvid = text.wholeMatch(of: /BV[0-9A-Za-z]{10}/), let link = AppLink.video(String(bvid.output)) {
                return .open(link)
            }
            return .text(text)
        }
        // 短链：跟着跳转拿到真实地址再判断
        if shortHosts.contains(host) {
            guard let target = await expand(url) else { return .web(url) }
            return await classify(target) ?? .web(target)
        }
        return await classify(url) ?? .web(url)
    }

    private static let shortHosts: Set<String> = ["b23.tv", "bili2233.cn", "bili22.cn", "bili23.cn", "bili33.cn"]

    /// B 站域名下认得的几种；认不出返回 nil（当普通网页）
    private static func classify(_ url: URL) async -> ScanTarget? {
        guard let host = url.host()?.lowercased(), host == "bilibili.com" || host.hasSuffix(".bilibili.com") else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if host.hasPrefix("passport.") || query.contains(where: { $0.name == "qrcode_key" || $0.name == "auth_code" }) {
            return .loginCode
        }
        let path = url.path()
        if let bvid = path.firstMatch(of: /BV[0-9A-Za-z]{10}/) {
            return AppLink.video(String(bvid.output)).map(ScanTarget.open)
        }
        if let range = path.range(of: "/video/av", options: .caseInsensitive),
           let aid = Int(path[range.upperBound...].prefix { $0.isNumber }),
           let info = try? await BiliClient.shared.get(.view(aid: aid), as: BvidLookup.self) {
            return AppLink.video(info.bvid).map(ScanTarget.open)
        }
        // space.bilibili.com/<mid> 或 m.bilibili.com/space/<mid>
        let parts = url.pathComponents.filter { $0 != "/" }
        if host == "space.bilibili.com", let mid = parts.first.flatMap({ Int($0) }) {
            return AppLink.space(mid).map(ScanTarget.open)
        }
        if parts.count >= 2, parts[0] == "space", let mid = Int(parts[1]) {
            return AppLink.space(mid).map(ScanTarget.open)
        }
        return nil
    }

    private struct BvidLookup: Decodable, Sendable {
        let bvid: String
    }

    private static func expand(_ url: URL) async -> URL? {
        var request = URLRequest(url: url)
        request.setValue(BiliClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return response.url
    }
}

// MARK: - 扫码页

/// 「我的」右上角扫一扫：相机实时识别二维码（系统 DataScanner），也可以从相册选图识别
struct QRScannerView: View {
    /// 要在 App 里打开的链接：交给调用方，在扫码页关掉之后再打开
    var onOpen: (URL) -> Void

    enum Access {
        case checking, granted, denied, unsupported
    }

    @State private var access: Access = .checking
    @State private var resolving = false
    @State private var result: ScanTarget?
    @State private var pickerItem: PhotosPickerItem?
    @State private var torchOn = false
    @State private var hits = 0
    @State private var sweep = false
    @State private var toast: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 识别出结果或正在解析时暂停，避免同一个码连续触发
    private var scanning: Bool { result == nil && !resolving }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if access == .granted {
                QRCameraView(isScanning: scanning) { handle($0) }
                    .ignoresSafeArea()
                if result == nil { viewfinder }
            } else if access == .denied || access == .unsupported {
                unavailable
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if let result {
                    resultCard(result)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    bottomBar
                }
            }

            if resolving {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .animation(Motion.component, value: result)
        .sensoryFeedback(.success, trigger: hits)
        .toast($toast, bottomPadding: 150)
        .statusBarHidden()
        .task { await checkAccess() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { await scanPhoto(item) }
        }
        .onDisappear { setTorch(false) }
    }

    // MARK: 取景框

    private var viewfinder: some View {
        VStack(spacing: 22) {
            ZStack {
                ViewfinderCorners()
                    .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                if !reduceMotion {
                    Capsule()
                        .fill(LinearGradient(colors: [.clear, accent, .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 2)
                        .padding(.horizontal, 18)
                        .shadow(color: accent, radius: 6)
                        .offset(y: sweep ? 112 : -112)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { sweep = true }
                        }
                }
            }
            .frame(width: 250, height: 250)
            Text("将二维码放入框内，即可自动扫描")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.8))
        }
        .allowsHitTesting(false)
    }

    // MARK: 顶栏、底栏

    private var topBar: some View {
        HStack {
            GlassCircleButton(systemImage: "xmark", label: "关闭", glass: .clear) { dismiss() }
            Spacer()
            Text("扫一扫").font(.serif(18)).tracking(1.6)
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var bottomBar: some View {
        HStack(spacing: 56) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                roundLabel("photo.on.rectangle", "相册")
            }
            .buttonStyle(PressableStyle())
            if access == .granted, AVCaptureDevice.default(for: .video)?.hasTorch == true {
                Button { setTorch(!torchOn) } label: {
                    roundLabel(torchOn ? "flashlight.on.fill" : "flashlight.off.fill", torchOn ? "关闭手电筒" : "手电筒")
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(.bottom, 36)
    }

    private func roundLabel(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 56, height: 56)
                .glassEffect(.clear.interactive(), in: .circle)
            Text(title).font(.system(size: 12))
        }
        .foregroundStyle(.white)
    }

    // MARK: 结果

    private func resultCard(_ target: ScanTarget) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch target {
            case .loginCode:
                Label("这是网页或电视的登录二维码", systemImage: "lock.shield")
                    .font(.system(size: 16, weight: .semibold))
                Text("为了账号安全，NewBi 不代为确认其他设备的登录。请用哔哩哔哩官方 App 扫这个码。")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            case .web(let url):
                Label("识别到网址", systemImage: "link")
                    .font(.system(size: 16, weight: .semibold))
                Text(url.absoluteString)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button("在浏览器打开") {
                        onOpen(url)
                        dismiss()
                    }
                    Button("复制") { copy(url.absoluteString) }
                }
                .buttonStyle(.glass)
            case .text(let text):
                Label("识别到文字", systemImage: "text.alignleft")
                    .font(.system(size: 16, weight: .semibold))
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(6)
                    .textSelection(.enabled)
                Button("复制") { copy(text) }.buttonStyle(.glass)
            case .open:
                EmptyView()
            }
            Button {
                result = nil
            } label: {
                Text("继续扫描")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(accent.accentFill, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(20)
        .frame(maxWidth: 460, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    // MARK: 相机不可用

    private var unavailable: some View {
        VStack(spacing: 14) {
            Image(systemName: access == .denied ? "camera.fill" : "camera.metering.unknown")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.7))
            Text(access == .denied ? "需要相机权限才能扫码" : "这台设备不能用相机扫码")
                .font(.system(size: 16, weight: .semibold))
            Text("也可以点下面的「相册」，从图片里识别二维码")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
            if access == .denied {
                Button("去设置开启") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.glass)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
    }

    // MARK: 逻辑

    private func checkAccess() async {
        guard DataScannerViewController.isSupported else {
            access = .unsupported
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            access = DataScannerViewController.isAvailable ? .granted : .denied
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            access = granted && DataScannerViewController.isAvailable ? .granted : .denied
        default:
            access = .denied
        }
    }

    private func handle(_ code: String) {
        guard scanning else { return }
        hits += 1
        resolving = true
        Task {
            let target = await ScanTarget.resolve(code)
            resolving = false
            if case .open(let url) = target {
                onOpen(url)
                dismiss()
            } else {
                result = target
            }
        }
    }

    private func scanPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            toast = "读取图片失败"
            return
        }
        let code = await Task.detached(priority: .userInitiated) { Self.detectQR(in: data) }.value
        if let code {
            handle(code)
        } else {
            toast = "图片里没有找到二维码"
        }
    }

    private nonisolated static func detectQR(in data: Data) -> String? {
        guard let image = CIImage(data: data),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        return detector.features(in: image).lazy.compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        toast = "已复制"
    }

    private func setTorch(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch,
              (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
        torchOn = on
    }
}

/// 取景框四个角
private struct ViewfinderCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length: CGFloat = 28
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        return path
    }
}

// MARK: - 相机

/// 系统的 DataScanner：只认二维码，识别到的码会被系统高亮
private struct QRCameraView: UIViewControllerRepresentable {
    var isScanning: Bool
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        if isScanning, !scanner.isScanning {
            try? scanner.startScanning()
        } else if !isScanning, scanner.isScanning {
            scanner.stopScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue, !value.isEmpty {
                    onCode(value)
                    return
                }
            }
        }
    }
}
