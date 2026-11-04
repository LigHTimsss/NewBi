import UIKit
import CoreImage.CIFilterBuiltins

/// 扫码登录状态机：生成二维码 → 每 2 秒轮询 → 成功后 Cookie 由 HTTPCookieStorage 自动保存
@MainActor
@Observable
final class QRLoginModel {
    enum Phase: Equatable {
        case loading, waiting, scanned, expired, success
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var qrImage: UIImage?
    private var task: Task<Void, Never>?

    func start() {
        task?.cancel()
        task = Task { await run() }
    }

    func stop() {
        task?.cancel()
    }

    private func run() async {
        phase = .loading
        do {
            let qr = try await BiliClient.shared.get(.qrGenerate, as: QRGenerate.self)
            qrImage = Self.makeQR(qr.url)
            phase = .waiting
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(2))
                let poll = try await BiliClient.shared.get(.qrPoll(key: qr.qrcodeKey), as: QRPoll.self)
                switch poll.code {
                case 0:
                    // TODO: refresh_token 存 Keychain，用于 Cookie 刷新（DESIGN.md §9）
                    phase = .success
                    return
                case 86090: phase = .scanned
                case 86038: phase = .expired; return
                default: break // 86101 未扫码
                }
            }
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private static func makeQR(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
