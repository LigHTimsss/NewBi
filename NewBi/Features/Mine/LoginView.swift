import SwiftUI
import WebKit

/// 登录：扫码 / 密码 / 短信验证码三种方式。密码和验证码登录前要完成一次 B 站的人机验证（极验）
struct LoginView: View {
    enum Mode: String, CaseIterable {
        case qr = "扫码", password = "密码", sms = "验证码"
    }

    enum Field {
        case account, password, phone, code
    }

    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme
    @State private var mode: Mode = .sms
    @State private var qr = QRLoginModel()
    @State private var account = AccountLoginModel()
    @State private var finishing = false
    @FocusState private var focus: Field?

    var body: some View {
        VStack(spacing: 18) {
            Text("登录").font(.serif(24)).tracking(2).padding(.top, 28)
            NativeSegmented(options: Mode.allCases, selection: $mode, title: \.rawValue)
                .frame(width: 240)

            Group {
                switch mode {
                case .qr: qrContent
                case .password: passwordForm
                case .sms: smsForm
                }
            }
            .frame(maxWidth: 360)
            .transition(.opacity)

            Spacer(minLength: 0)
            Text(footnote)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .animation(Motion.component, value: mode)
        .presentationDetents([.large])
        .appPageBackground()
        .presentationBackground(Theme.background)
        .onAppear { if mode == .qr { qr.start() } }
        .onDisappear {
            qr.stop()
            account.stop()
        }
        .onChange(of: mode) { _, new in
            focus = nil
            if new == .qr { qr.start() } else { qr.stop() }
        }
        .onChange(of: qr.phase) { _, phase in
            if phase == .success { completeLogin() }
        }
        .onChange(of: account.succeeded) { _, succeeded in
            if succeeded { completeLogin() }
        }
        .sheet(item: Binding(get: { account.challenge }, set: { account.challenge = $0 }), onDismiss: { account.captchaDismissed() }) { challenge in
            GeetestSheet(challenge: challenge) { result, message in
                account.captchaFinished(result, for: challenge, message: message)
            }
        }
    }

    private var footnote: String {
        switch mode {
        case .qr: "用哔哩哔哩 App 扫码登录，不经过账号密码"
        case .password: "密码先用 B 站公开的密钥加密，再直接发给 B 站；NewBi 不保存密码"
        case .sms: "验证码短信由 B 站发送"
        }
    }

    private func completeLogin() {
        guard !finishing else { return }
        finishing = true
        focus = nil
        Task {
            await session.didLogin()
            dismiss()
        }
    }

    // MARK: 扫码

    private var qrContent: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(.white)
                if let image = qr.qrImage {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                        .blur(radius: qr.phase == .expired ? 6 : 0)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 220, height: 220)
            .animation(Motion.component, value: qr.phase)

            Text(qrStatus)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .contentTransition(.opacity)

            HStack(spacing: 12) {
                if qr.phase == .expired {
                    Button("刷新二维码") { qr.start() }
                }
                // 同一台 iPhone：保存二维码后在官方 App「扫一扫 → 相册」识别
                if let image = qr.qrImage {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("登录二维码", image: Image(uiImage: image))) {
                        Label("保存二维码", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .buttonStyle(.glass)
        }
    }

    private var qrStatus: String {
        switch qr.phase {
        case .loading: "正在生成二维码…"
        case .waiting: "请使用哔哩哔哩 App 扫码"
        case .scanned: "已扫码，请在手机上确认"
        case .expired: "二维码已过期"
        case .success: "登录成功"
        case .failed(let message): message
        }
    }

    // MARK: 密码

    private var passwordForm: some View {
        @Bindable var model = account
        return VStack(spacing: 14) {
            inputField {
                TextField("手机号或邮箱", text: $model.account)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .account)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
            }
            inputField {
                SecureField("密码", text: $model.password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submitPassword)
            }
            status
            primaryButton("登录", enabled: model.canSubmitPassword, action: submitPassword)
        }
    }

    private func submitPassword() {
        guard account.canSubmitPassword else { return }
        focus = nil
        account.startPasswordLogin()
    }

    // MARK: 短信验证码

    private var smsForm: some View {
        @Bindable var model = account
        return VStack(spacing: 14) {
            inputField {
                Menu {
                    Picker("国家或地区", selection: $model.countryCode) {
                        ForEach(LoginCountry.all, id: \.self) { country in
                            Text("\(country.name) +\(country.code)").tag(country.code)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("+\(model.countryCode)")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .accessibilityLabel("国家或地区代码")
                Theme.separator.frame(width: 1, height: 22)
                TextField("手机号", text: $model.phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused($focus, equals: .phone)
            }
            inputField {
                TextField("短信验证码", text: $model.code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focus, equals: .code)
                Button(model.countdown > 0 ? "\(model.countdown) 秒后重发" : "获取验证码") {
                    focus = nil
                    model.sendCode()
                }
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(model.canSendCode ? accent.accentText(scheme) : Theme.secondaryText)
                .disabled(!model.canSendCode)
            }
            status
            primaryButton("登录", enabled: model.canSubmitSMS) {
                focus = nil
                model.loginWithSMS()
            }
        }
    }

    // MARK: 通用

    private func inputField(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 10) { content() }
            .font(.system(size: 16))
            .padding(.horizontal, 18)
            .frame(height: 50)
            .background(Theme.selection, in: .capsule)
    }

    @ViewBuilder
    private var status: some View {
        if let error = account.error {
            Text(error)
                .font(.system(size: 13))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .transition(.opacity)
        } else if let hint = account.hint {
            Text(hint)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .transition(.opacity)
        }
    }

    private func primaryButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if account.isBusy {
                    ProgressView().tint(.white)
                } else {
                    Text(title).font(.system(size: 16, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(accent.accentFill.opacity(enabled || account.isBusy ? 1 : 0.45), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
    }
}

// MARK: - 人机验证页

/// B 站登录接口要求的极验拼图：网页里加载极验官方脚本，用户完成后把结果交回来
private struct GeetestSheet: View {
    let challenge: CaptchaChallenge
    var onFinish: (GeetestResult?, String?) -> Void
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("安全验证").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("取消") { onFinish(nil, nil) }
                    .font(.system(size: 16))
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            ZStack {
                GeetestWebView(challenge: challenge, onReady: { loading = false }, onFinish: onFinish)
                if loading { ProgressView() }
            }
        }
        .presentationDetents([.large])
    }
}

private struct GeetestWebView: UIViewRepresentable {
    let challenge: CaptchaChallenge
    var onReady: () -> Void
    var onFinish: (GeetestResult?, String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady, onFinish: onFinish)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: Coordinator.channel)
        // 极验自己的 Cookie / 缓存不和别处混用
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(Self.page(for: challenge), baseURL: URL(string: "https://passport.bilibili.com/"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onReady = onReady
        context.coordinator.onFinish = onFinish
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.channel)
    }

    /// 极验 v3「bind」模式：脚本就绪后直接弹出拼图；参数用 JSON 序列化写进页面
    private static func page(for challenge: CaptchaChallenge) -> String {
        let config: [String: Any] = [
            "gt": challenge.gt, "challenge": challenge.challenge,
            "offline": false, "new_captcha": true, "product": "bind", "https": true, "lang": "zh-cn",
        ]
        let json = (try? JSONSerialization.data(withJSONObject: config)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>html,body{margin:0;height:100%;background:transparent;}</style>
        <script src="https://static.geetest.com/static/tools/gt.js"></script>
        </head><body><script>
        function post(m) { window.webkit.messageHandlers.\(Coordinator.channel).postMessage(m); }
        if (typeof initGeetest !== 'function') {
          post({ error: '验证组件加载失败，请检查网络后重试' });
        } else {
          initGeetest(\(json), function (captcha) {
            captcha.onReady(function () { post({ ready: true }); captcha.verify(); });
            captcha.onSuccess(function () {
              var r = captcha.getValidate();
              if (r) { post({ challenge: r.geetest_challenge, validate: r.geetest_validate, seccode: r.geetest_seccode }); }
              else { post({ error: '验证失败，请重试' }); }
            });
            captcha.onClose(function () { post({ closed: true }); });
            captcha.onError(function () { post({ error: '验证出错，请重试' }); });
          });
        }
        </script></body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency WKScriptMessageHandler, @preconcurrency WKNavigationDelegate {
        nonisolated static let channel = "geetest"
        var onReady: () -> Void
        var onFinish: (GeetestResult?, String?) -> Void
        private var finished = false

        init(onReady: @escaping () -> Void, onFinish: @escaping (GeetestResult?, String?) -> Void) {
            self.onReady = onReady
            self.onFinish = onFinish
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if body["ready"] != nil {
                onReady()
                return
            }
            guard !finished else { return }
            if let challenge = body["challenge"] as? String, let validate = body["validate"] as? String,
               let seccode = body["seccode"] as? String {
                finish(GeetestResult(challenge: challenge, validate: validate, seccode: seccode), nil)
            } else if body["closed"] != nil {
                finish(nil, nil)
            } else if let error = body["error"] as? String {
                finish(nil, error)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(nil, "验证页加载失败：\(error.localizedDescription)")
        }

        private func finish(_ result: GeetestResult?, _ message: String?) {
            guard !finished else { return }
            finished = true
            onFinish(result, message)
        }
    }
}
