import SwiftUI
import AVKit

private let secondaryOnDark = Color.white.opacity(0.62)

/// 全屏右侧玻璃抽屉：弹幕设置 / 画质 / 倍速 / 更多 / 选集
struct PlayerDrawer: View {
    let panel: PlayerPanel
    let controller: PlayerController
    let model: VideoDetailModel
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch panel {
                case .danmaku: DanmakuPanel(controller: controller)
                case .quality: QualityPanel(controller: controller, onClose: onClose)
                case .speed: SpeedPanel(controller: controller, onClose: onClose)
                case .more: MorePanel(controller: controller)
                case .parts: PartsPanel(model: model)
                // 评论有自己的浮窗（FullscreenOverlay 里的 CommentsPanel），不走抽屉
                case .comments: EmptyView()
                }
            }
            .padding(.leading, 22)
            .padding(.trailing, 16)
            .padding(.vertical, 22)
        }
        .scrollIndicators(.hidden)
        .frame(width: 384)
        .background {
            // 大面积用 Material，比 glassEffect 便宜；颜色压暗到设计稿的 rgba(14,14,18,.72)
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color(red: 14 / 255, green: 14 / 255, blue: 18 / 255).opacity(0.55))
                .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.12)).frame(width: 0.5) }
                .ignoresSafeArea()
        }
    }
}

// MARK: - 通用

private struct PanelTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.serif(17))
            .tracking(1.4)
            .padding(.top, 6)
            .padding(.bottom, 12)
    }
}

private struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(.white.opacity(0.07), in: .rect(cornerRadius: 20))
            .padding(.bottom, 22)
    }
}

private struct CardDivider: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5)
    }
}

// MARK: - 选集

/// 全屏选集：竖向列表，当前 P 高亮；切换后面板保持打开，方便连续挑
private struct PartsPanel: View {
    let model: VideoDetailModel
    @Environment(\.accent) private var accent

    var body: some View {
        PanelTitle("选集 · \(model.partIndex + 1) / \(model.pages.count)")
        ScrollViewReader { proxy in
            PanelCard {
                ForEach(Array(model.pages.enumerated()), id: \.element.cid) { index, page in
                    if index > 0 { CardDivider() }
                    let on = index == model.partIndex
                    Button {
                        Task { await model.selectPart(index) }
                    } label: {
                        HStack(spacing: 10) {
                            Text("P\(page.page)")
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(on ? accent : secondaryOnDark)
                                .frame(width: 34, alignment: .leading)
                            Text(page.part)
                                .font(.system(size: 14, weight: on ? .semibold : .regular))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if on {
                                Image(systemName: "waveform")
                                    .foregroundStyle(accent)
                                    .symbolEffect(.variableColor.iterative, isActive: model.player.isPlaying)
                            } else {
                                Text(page.duration.durationText)
                                    .font(.system(size: 12))
                                    .monospacedDigit()
                                    .foregroundStyle(secondaryOnDark)
                            }
                        }
                        .frame(minHeight: 48)
                        .contentShape(.rect)
                    }
                    .buttonStyle(PressableStyle())
                    .id(index)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .onAppear { proxy.scrollTo(model.partIndex, anchor: .center) }
        }
        .sensoryFeedback(.selection, trigger: model.partIndex)
    }
}

// MARK: - 弹幕设置

private struct DanmakuPanel: View {
    let controller: PlayerController
    @State private var addingKeyword = false
    @State private var keyword = ""
    @Environment(\.accent) private var accent

    private static let areas: [CGFloat] = [0.1, 0.25, 0.5, 0.75, 1]
    private static let speedNames = ["极慢", "较慢", "适中", "较快", "极快"]

    private var settings: DanmakuSettings { controller.danmakuSettings }

    var body: some View {
        PanelTitle("弹幕设置")
        PanelCard {
            sliderRow("显示区域", "\(Int(settings.areaRatio * 100))%", in: 0...4, step: 1, value: Binding(
                get: { Double(Self.areas.firstIndex(of: settings.areaRatio) ?? 2) },
                set: { controller.danmakuSettings.areaRatio = Self.areas[Int($0.rounded())] }
            ))
            CardDivider()
            sliderRow("不透明度", "\(Int(settings.opacity * 100))%", in: 10...100, step: 5, value: Binding(
                get: { Double(settings.opacity * 100) },
                set: { controller.danmakuSettings.opacity = Float($0 / 100) }
            ))
            CardDivider()
            sliderRow("字体大小", "\(Int((settings.fontSize - 14) / 0.08))%", in: 0...100, step: 5, value: Binding(
                get: { Double((settings.fontSize - 14) / 0.08) },
                set: { controller.danmakuSettings.fontSize = 14 + CGFloat($0) * 0.08 }
            ))
            CardDivider()
            sliderRow("弹幕速度", Self.speedNames[settings.speedLevel], in: 0...4, step: 1, value: Binding(
                get: { Double(settings.speedLevel) },
                set: { controller.danmakuSettings.speedLevel = Int($0.rounded()) }
            ))
        }

        PanelTitle("画面防挡")
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("按弹幕类型屏蔽").font(.system(size: 14))
                HStack(spacing: 4) {
                    typeTile("固定", icon: "pin", \.hideFixed)
                    typeTile("滚动", icon: "arrow.left", \.hideScroll)
                    typeTile("彩色", icon: "paintpalette", \.hideColored)
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 12)
            CardDivider()
            toggleRow("重复弹幕隐藏", "大量内容相同的弹幕会被隐藏", \.hideDuplicates)
            CardDivider()
            toggleRow("底部字幕区域防挡", "底部弹幕会被隐藏", \.hideBottom)
            CardDivider()
            // 需要 B 站下发的人像蒙版（webmask），后续版本接入
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("人像防挡").font(.system(size: 15))
                    Text("后续版本支持").font(.system(size: 12)).foregroundStyle(secondaryOnDark)
                }
                Spacer()
                Toggle("人像防挡", isOn: .constant(false)).labelsHidden().disabled(true)
            }
            .padding(.vertical, 12)
        }

        PanelTitle("更多工具")
        PanelCard {
            toggleRow("弹幕观看屏蔽词", "仅对我不展示特定弹幕", \.keywordFilterEnabled)
            Button { addingKeyword = true } label: {
                HStack {
                    Text("添加屏蔽词")
                    Spacer()
                    if !settings.blockedKeywords.isEmpty {
                        Text("已添加 \(settings.blockedKeywords.count) 个").foregroundStyle(secondaryOnDark)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                }
                .font(.system(size: 14))
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.white.opacity(0.07), in: .rect(cornerRadius: 14))
                .contentShape(.rect)
            }
            .buttonStyle(PressableStyle())
            .padding(.bottom, 12)
            if !settings.blockedKeywords.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(settings.blockedKeywords, id: \.self) { word in
                            Button {
                                controller.danmakuSettings.blockedKeywords.removeAll { $0 == word }
                            } label: {
                                Label(word, systemImage: "xmark")
                                    .labelStyle(TrailingIconLabelStyle())
                                    .font(.system(size: 13))
                                    .padding(.horizontal, 10)
                                    .frame(height: 28)
                                    .background(.white.opacity(0.1), in: .capsule)
                            }
                            .accessibilityLabel("移除屏蔽词 \(word)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .padding(.bottom, 12)
            }
        }

        Button {
            withAnimation(Motion.component) { controller.danmakuSettings = DanmakuSettings() }
        } label: {
            Label("重置弹幕设置", systemImage: "arrow.clockwise")
                .font(.system(size: 14))
                .foregroundStyle(secondaryOnDark)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .alert("添加屏蔽词", isPresented: $addingKeyword) {
            TextField("包含该词的弹幕将不显示", text: $keyword)
            Button("取消", role: .cancel) { keyword = "" }
            Button("添加") {
                let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                if !word.isEmpty, !settings.blockedKeywords.contains(word) {
                    controller.danmakuSettings.blockedKeywords.append(word)
                }
                keyword = ""
            }
        }
    }

    private func sliderRow(_ title: String, _ value: String, in range: ClosedRange<Double>, step: Double, value binding: Binding<Double>) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.system(size: 15))
                Spacer()
                Text(value)
                    .font(.system(size: 14))
                    .monospacedDigit()
                    .foregroundStyle(secondaryOnDark)
                    .contentTransition(.numericText())
            }
            Slider(value: binding, in: range, step: step)
                .tint(accent)
                .accessibilityLabel(title)
                .accessibilityValue(value)
        }
        .padding(.vertical, 12)
    }

    private func typeTile(_ title: String, icon: String, _ keyPath: WritableKeyPath<DanmakuSettings, Bool>) -> some View {
        let on = settings[keyPath: keyPath]
        return Button {
            withAnimation(Motion.micro) { controller.danmakuSettings[keyPath: keyPath].toggle() }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(width: 52, height: 52)
                    .background(on ? accent.opacity(0.22) : Color.white.opacity(0.08), in: .rect(cornerRadius: 16))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(on ? accent : .white)
            .frame(width: 60)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("屏蔽\(title)弹幕")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func toggleRow(_ title: String, _ subtitle: String, _ keyPath: WritableKeyPath<DanmakuSettings, Bool>) -> some View {
        Toggle(isOn: Binding(
            get: { controller.danmakuSettings[keyPath: keyPath] },
            set: { controller.danmakuSettings[keyPath: keyPath] = $0 }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(secondaryOnDark)
            }
        }
        .tint(accent)
        .padding(.vertical, 12)
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}

// MARK: - 画质

private struct QualityPanel: View {
    let controller: PlayerController
    var onClose: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        PanelTitle("画质")
        if controller.qualities.isEmpty {
            ProgressView().frame(maxWidth: .infinity)
        }
        VStack(spacing: 2) {
            ForEach(controller.qualities) { option in
                let on = option.id == controller.quality
                Button {
                    onClose()
                    Task { await controller.changeQuality(option.id) }
                } label: {
                    HStack(spacing: 8) {
                        Text(option.name).frame(maxWidth: .infinity, alignment: .leading)
                        if option.needsVIP || !option.available {
                            // 拿不到的档位：大会员档标「大会员」，其余多为未登录限制
                            Text(option.needsVIP ? "大会员" : "登录")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5)
                                .frame(height: 16)
                                .overlay { RoundedRectangle(cornerRadius: 4).stroke(lineWidth: 1) }
                                .opacity(0.85)
                        }
                    }
                    .font(.system(size: 15, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? accent : .white)
                    .opacity(option.available ? 1 : 0.4)
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(on ? Color.white.opacity(0.1) : Color.clear, in: .rect(cornerRadius: 14))
                    .contentShape(.rect)
                }
                .buttonStyle(PressableStyle())
                .disabled(!option.available)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityHint(option.available ? "" : "当前账号无法播放此画质")
            }
        }
        if let label = controller.streamLabel {
            Label(label, systemImage: "info.circle")
                .labelStyle(CompactLabelStyle())
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(secondaryOnDark)
                .padding(.top, 12)
        }
        Text("编码优先级、默认画质可在「设置 → 播放设置」中调整")
            .font(.system(size: 12))
            .foregroundStyle(secondaryOnDark)
            .padding(.top, 4)
    }
}

// MARK: - 倍速

private struct SpeedPanel: View {
    let controller: PlayerController
    var onClose: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        PanelTitle("倍速")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(PlayerController.speeds, id: \.self) { speed in
                let on = speed == controller.rate
                Button {
                    controller.setRate(speed)
                    onClose()
                } label: {
                    Text(speed.speedLabel)
                        .font(.system(size: 15, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(on ? accent : .white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(.white.opacity(on ? 0.16 : 0.08), in: .rect(cornerRadius: 14))
                        .overlay {
                            if on { RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.3), lineWidth: 0.5) }
                        }
                        .shadow(color: on ? accent.opacity(0.3) : .clear, radius: 7)
                }
                .buttonStyle(PressableStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        Text("播放中长按画面，可临时倍速播放")
            .font(.system(size: 12))
            .foregroundStyle(secondaryOnDark)
            .padding(.top, 12)
    }
}

// MARK: - 更多

private struct MorePanel: View {
    let controller: PlayerController
    @AppStorage("backgroundPlay") private var backgroundPlay = true
    @Environment(\.accent) private var accent

    var body: some View {
        PanelTitle("更多")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 14) {
            Menu {
                ForEach([15, 30, 60], id: \.self) { minutes in
                    Button("\(minutes) 分钟后") { controller.sleep(after: minutes) }
                }
                Button("不开启") { controller.sleep(after: nil) }
            } label: {
                tileLabel("timer", controller.sleepDeadline == nil ? "定时关闭" : "定时中", on: controller.sleepDeadline != nil)
            }
            Menu {
                Picker("播放方式", selection: Binding(get: { controller.endAction }, set: { controller.endAction = $0 })) {
                    ForEach(PlayerController.EndAction.allCases, id: \.self) { action in
                        Label(action.title, systemImage: action.icon).tag(action)
                    }
                }
            } label: {
                tileLabel(controller.endAction.icon, controller.endAction.title, on: controller.endAction != .next)
            }
            tile(
                controller.fillScreen ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                controller.fillScreen ? "铺满" : "画面尺寸", on: controller.fillScreen
            ) {
                controller.fillScreen.toggle()
            }
            tile("arrow.left.and.right.righttriangle.left.righttriangle.right", "镜像翻转", on: controller.mirrored) {
                controller.mirrored.toggle()
            }
            tile("headphones", "后台播放", on: backgroundPlay) { backgroundPlay.toggle() }
            // FFmpeg 引擎暂不支持系统画中画
            tile("pip.enter", controller.supportsPictureInPicture ? "画中画" : "画中画不可用") { controller.togglePictureInPicture() }
                .disabled(!controller.supportsPictureInPicture)
                .opacity(controller.supportsPictureInPicture ? 1 : 0.4)
            VStack(spacing: 6) {
                RoutePicker(activeTint: UIColor(accent))
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 16))
                Text("投屏").font(.system(size: 11)).foregroundStyle(secondaryOnDark)
            }
        }
    }

    private func tile(_ icon: String, _ title: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(icon, title, on: on) }
            .buttonStyle(PressableStyle())
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func tileLabel(_ icon: String, _ title: String, on: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(on ? accent : .white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 48, height: 48)
                .background(on ? accent.opacity(0.22) : Color.white.opacity(0.08), in: .rect(cornerRadius: 16))
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(on ? accent : secondaryOnDark)
        }
    }
}

/// 系统投屏按钮（AirPlay；也能选蓝牙耳机、HomePod 等音频输出）
struct RoutePicker: UIViewRepresentable {
    var activeTint: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.activeTintColor = activeTint
    }
}
