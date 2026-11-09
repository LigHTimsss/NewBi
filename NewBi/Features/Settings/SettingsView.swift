import SwiftUI

/// 「设置」画板：分组卡片 + 原生开关（iOS 26 开关自带玻璃质感）
struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearance") private var appearance = 0
    @AppStorage("customAccentRGB") private var customAccentRGB = 0xFB7299
    @AppStorage("accentIndex") private var accentIndex = 0
    @AppStorage("clipboardVideoAutoOpen") private var clipboardVideoAutoOpen = false
    @AppStorage("homeAutoRefresh") private var homeAutoRefresh = true
    @AppStorage("autoplay") private var autoplay = true
    @AppStorage("cellularAlert") private var cellularAlert = false
    @AppStorage("backgroundPlay") private var backgroundPlay = true
    /// 播放中回到主屏幕时自动进入画中画（系统播放器）；关掉后按「后台播放」只出声或暂停
    @AppStorage(AVPlayerEngine.autoPictureInPictureKey) private var autoPictureInPicture = true
    /// 播放中返回时缩成迷你播放条继续播
    @AppStorage("miniPlayer") private var miniPlayer = true
    /// 多 P 视频播完自动播下一 P
    @AppStorage("autoNextPart") private var autoNextPart = true
    /// 离线缓存默认只走 Wi-Fi，省流量
    @AppStorage("downloadWifiOnly") private var downloadWifiOnly = true
    /// 超出账号权限时服务器自动降到可用的最高档
    @AppStorage("defaultQuality") private var defaultQuality = 80
    @AppStorage("codecPreference") private var codecPreference = "auto"
    /// 自动：系统播放器失败时切 FFmpeg；FFmpeg 不支持系统画中画
    @AppStorage("enginePreference") private var enginePreference = "auto"

    private var customAccent: Binding<Color> {
        Binding(get: { Color(hex: UInt32(clamping: customAccentRGB) & 0xFFFFFF) }, set: { color in
            let resolved = color.resolve(in: EnvironmentValues())
            func channel(_ value: Float) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            customAccentRGB = (channel(resolved.red) << 16) | (channel(resolved.green) << 8) | channel(resolved.blue)
            accentIndex = 4
        })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                group {
                    HStack {
                        Text("深色模式")
                        Spacer()
                        Picker("深色模式", selection: $appearance) {
                            Text("跟随系统").tag(0)
                            Text("浅色").tag(1)
                            Text("深色").tag(2)
                            Text("柔和浅色").tag(3)
                            Text("柔和深色").tag(4)
                        }
                        .labelsHidden()
                    }
                    .frame(minHeight: 50)
                    divider
                    HStack {
                        Text("主题色")
                        Spacer()
                        ForEach([0, 2], id: \.self) { index in
                            Button {
                                withAnimation(Motion.component) { accentIndex = index }
                            } label: {
                                Circle()
                                    .fill(Theme.accents[index])
                                    .frame(width: 22, height: 22)
                                    .padding(3)
                                    .overlay { if accentIndex == index { Circle().stroke(.primary, lineWidth: 1.5) } }
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel(index == 0 ? "粉色" : "苹果蓝")
                        }
                        ColorPicker("自定义主题色", selection: customAccent, supportsOpacity: false)
                            .labelsHidden()
                            .frame(width: 44, height: 44)
                            .overlay { if accentIndex == 4 { Circle().stroke(.primary, lineWidth: 1.5).padding(6).allowsHitTesting(false) } }
                    }
                    .frame(minHeight: 50)
                }
                // 播放设置
                group {
                    pickerRow("默认画质", selection: $defaultQuality) {
                        Text("4K 超清").tag(120)
                        Text("1080P 60帧").tag(116)
                        Text("1080P 高码率").tag(112)
                        Text("1080P 高清").tag(80)
                        Text("720P 准高清").tag(64)
                        Text("480P 清晰").tag(32)
                    }
                    divider
                    pickerRow("视频编码", selection: $codecPreference) {
                        Text("自动（AV1 → HEVC）").tag("auto")
                        Text("兼容优先（H.264）").tag("compat")
                    }
                    divider
                    pickerRow("播放引擎", selection: $enginePreference) {
                        Text("自动（系统优先）").tag("auto")
                        Text("仅系统播放器").tag("system")
                        if EngineFactory.ffmpegAvailable {
                            Text("始终 FFmpeg").tag("ffmpeg")
                        }
                    }
                    divider
                    Toggle("自动播放", isOn: $autoplay).frame(minHeight: 50)
                    divider
                    Toggle("后台播放", isOn: $backgroundPlay).frame(minHeight: 50)
                    divider
                    Toggle("退到后台时自动画中画", isOn: $autoPictureInPicture).frame(minHeight: 50)
                    divider
                    Toggle("返回时小窗继续播放", isOn: $miniPlayer).frame(minHeight: 50)
                    divider
                    Toggle("首页自动刷新", isOn: $homeAutoRefresh).frame(minHeight: 50)
                    divider
                    Toggle("自动读取剪贴板跳转视频", isOn: $clipboardVideoAutoOpen).frame(minHeight: 50)
                    divider
                    Toggle("多 P 自动连播", isOn: $autoNextPart).frame(minHeight: 50)
                    divider
                    Toggle("移动网络播放提醒", isOn: $cellularAlert).frame(minHeight: 50)
                    divider
                    Toggle("仅在 Wi-Fi 下缓存", isOn: $downloadWifiOnly).frame(minHeight: 50)
                }
                .tint(accent)
                group {
                    NavigationLink(value: Route.storage) {
                        row("清理存储空间", value: nil).contentShape(.rect)
                    }
                    .foregroundStyle(.primary)
                    divider
                    row("关于", value: "版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")")
                }
                if session.isLoggedIn {
                    group {
                        Button("退出登录") {
                            session.logout()
                            dismiss()
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent.accentText(scheme))
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                }
            }
            .padding(.horizontal, 16)
            .font(.system(size: 16))
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .background(Theme.background)
    }

    private var divider: some View {
        Theme.separator.frame(height: 1).padding(.trailing, -16)
    }

    private func group(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Theme.card, in: .rect(cornerRadius: 22))
    }

    private func pickerRow<Value: Hashable>(
        _ title: String, selection: Binding<Value>, @ViewBuilder options: () -> some View
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: selection, content: options).labelsHidden()
        }
        .frame(minHeight: 50)
    }

    private func row(_ title: String, value: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let value { Text(value).foregroundStyle(Theme.secondaryText) }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(minHeight: 50)
    }
}
