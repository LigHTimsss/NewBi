import UIKit
import CoreImage.CIFilterBuiltins

/// 扫码登录状态机：生成二维码 → 每 2 秒轮询 → 仍有效的登录才提交 Cookie。
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
    private var generation: UUID?

    func start() {
        stop()
        let generation = Credentials.beginLogin()
        self.generation = generation
        task = Task { await run(generation: generation) }
    }

    func stop() {
        task?.cancel()
        if let generation { Credentials.cancelLogin(generation) }
        generation = nil
        task = nil
    }

    private func run(generation: UUID) async {
        let client = BiliClient(isolatedCookies: Credentials.deviceCookies)
        defer { Task { await client.invalidate() } }
        phase = .loading
        do {
            let qr = try await client.get(.qrGenerate, as: QRGenerate.self)
            guard !Task.isCancelled, Credentials.isCurrent(generation) else { return }
            qrImage = Self.makeQR(qr.url)
            phase = .waiting
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(2))
                let poll = try await client.get(.qrPoll(key: qr.qrcodeKey), as: QRPoll.self)
                guard !Task.isCancelled, Credentials.isCurrent(generation) else { return }
                switch poll.code {
                case 0:
                    let cookies = await client.cookies()
                    guard !Task.isCancelled, Credentials.isCurrent(generation) else { return }
                    guard Credentials.commit(cookies: cookies, token: poll.refreshToken, generation: generation) else {
                        if Credentials.isCurrent(generation) { phase = .failed("没有收到有效的登录凭据，请重新扫码") }
                        return
                    }
                    phase = .success
                    return
                case 86090: phase = .scanned
                case 86038: phase = .expired; return
                default: break // 86101 未扫码
                }
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, Credentials.isCurrent(generation) else { return }
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
