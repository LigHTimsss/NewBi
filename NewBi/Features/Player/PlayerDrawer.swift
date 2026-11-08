import SwiftUI
import AVKit

private let secondaryOnDark = Color.white.opacity(0.62)

/// 全屏右侧玻璃抽屉：弹幕设置 / 画质 / 倍速 / 更多 / 选集。
/// 竖屏全屏时弹幕设置、更多、倍速、画质改成从底部升起的面板（`sheet`）
struct PlayerDrawer: View {
    let panel: PlayerPanel
    let controller: PlayerController
    /// 直播间没有视频详情：为 nil 时「更多」里只留和画面、播放相关的几格，没有选集
    let model: VideoDetailModel?
    /// 底部面板：屏宽、顶部圆角、高度随内容，超过 `maxHeight` 才滚动
    var sheet = false
    var maxHeight: CGFloat = .infinity
    /// 底部面板铺到屏幕最底下，内容自己让开 Home 条
    var bottomInset: CGFloat = 0
    /// 全屏直播容器覆盖整个屏幕；只让内容避开安全区，材质仍贴边。
    var contentSafeAreaInsets = EdgeInsets()
    /// 收起抽屉，收起动画结束后执行传入的动作（换画质、改倍速）
    var onClose: (@escaping @MainActor () -> Void) -> Void

    /// 倍速、画质只放一列按钮：收窄到刚好放得下文字
    private var width: CGFloat {
        switch panel {
        case .speed: 150
        case .quality: 236
        default: 384
        }
    }

    private var narrow: Bool { panel == .speed || panel == .quality }

    var body: some View {
        if sheet {
            bottomSheet.geometryGroup()
        } else if narrow {
            // 在固定宽度的抽屉边界解析滑动位移，文字、描边和材质一起移动。
            drawer.geometryGroup()
        } else {
            drawer
        }
    }

    private static let sheetShape = UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)

    private var bottomSheet: some View {
        // 内容放得下就按内容高度，放不下（弹幕设置）才在 maxHeight 内滚动
        CappedHeight(max: maxHeight) {
            ViewThatFits(in: .vertical) {
                contents.fixedSize(horizontal: false, vertical: true)
                ScrollView { contents }
            }
        }
        .scrollIndicators(.hidden)
        // iPhone 竖屏是整屏宽；iPad 上收到 560 居中
        .frame(maxWidth: 560)
        .background {
            // 和右侧抽屉同一套材质和压暗色，描边换到顶边
            Self.sheetShape
                .fill(.ultraThinMaterial)
                .overlay(Self.sheetShape.fill(Color(red: 14 / 255, green: 14 / 255, blue: 18 / 255).opacity(0.55)))
                .overlay(Self.sheetShape.stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
        .clipShape(Self.sheetShape)
        .frame(maxWidth: .infinity)
    }

    private var drawer: some View {
        Group {
            if panel == .speed {
                // 五档都放得下时用普通按钮列。按实际可用高度决定，较矮的窗口仍能滚到最后一档。
                ViewThatFits(in: .vertical) {
                    contents.fixedSize(horizontal: false, vertical: true)
                    ScrollView { contents }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView { contents }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.top, contentSafeAreaInsets.top)
        .padding(.bottom, contentSafeAreaInsets.bottom)
        .padding(.trailing, contentSafeAreaInsets.trailing)
        .frame(width: width + contentSafeAreaInsets.trailing)
        .background {
            // 大面积用 Material，比 glassEffect 便宜；颜色压暗到设计稿的 rgba(14,14,18,.72)
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color(red: 14 / 255, green: 14 / 255, blue: 18 / 255).opacity(0.55))
                .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.12)).frame(width: 0.5) }
                .ignoresSafeArea()
        }
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch panel {
            case .danmaku: DanmakuPanel(controller: controller)
            case .quality: QualityPanel(controller: controller, grid: sheet, onClose: onClose)
            case .speed: SpeedPanel(controller: controller, row: sheet, onClose: onClose)
            case .more: MorePanel(controller: controller, model: model)
            case .parts: if let model { PartsPanel(model: model) }
            case .comments: EmptyView()
            }
        }
        .padding(.leading, sheet ? 20 : narrow ? 14 : 22)
        .padding(.trailing, sheet ? 20 : narrow ? 14 : 16)
        .padding(.top, sheet ? 14 : 22)
        .padding(.bottom, sheet ? 14 + bottomInset : 22)
    }
}

/// 把子视图的高度上限压到 `max`，但大小仍跟着子视图走。
/// `.frame(maxHeight:)` 在父视图给的高度更大时会直接撑到上限，底部面板就总是一样高
private struct CappedHeight: Layout {
    var max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = min(proposal.height ?? max, max)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
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
        LazyVStack(alignment: .leading, spacing: 0) { sections }
    }

    @ViewBuilder private var sections: some View {
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
    /// 竖屏底部面板：两列方块，屏宽下一列一档太空、太长
    var grid = false
    var onClose: (@escaping @MainActor () -> Void) -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        PanelTitle("画质")
        if controller.qualities.isEmpty {
            ProgressView().frame(maxWidth: .infinity)
        }
        if grid {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                ForEach(controller.qualities) { option(for: $0) }
            }
        } else {
            LazyVStack(spacing: 2) {
                ForEach(controller.qualities) { option(for: $0) }
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

    private func option(for option: QualityOption) -> some View {
        let on = option.id == controller.quality
        return Button {
            // 选了立即生效，面板留着，由用户自己收起
            Task { await controller.changeQuality(option.id) }
        } label: {
            HStack(spacing: 8) {
                Text(option.name).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity, alignment: .leading)
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
            .frame(height: grid ? 46 : 42)
            // 方块排布时每格都有底色，选中的更亮；列表排布只给选中的一行底色
            .background(on ? Color.white.opacity(grid ? 0.16 : 0.1) : Color.white.opacity(grid ? 0.08 : 0), in: .rect(cornerRadius: 14))
            .overlay {
                if grid && on { RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.3), lineWidth: 0.5) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .disabled(!option.available)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(option.available ? "" : "当前账号无法播放此画质")
    }
}

// MARK: - 倍速

/// 倍速：横屏抽屉里竖排一列，从快到慢；竖屏底部面板里横排一行，从慢到快。
/// 选中立即生效，面板不自动收起
private struct SpeedPanel: View {
    private static let options = PlayerController.speeds.map { (rate: $0, title: $0.speedLabel) }
    let controller: PlayerController
    /// 竖屏底部面板：五档排成一行
    var row = false
    var onClose: (@escaping @MainActor () -> Void) -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        PanelTitle("倍速")
        if row {
            HStack(spacing: 8) {
                ForEach(Self.options, id: \.rate) { button(for: $0, height: 48) }
            }
        } else {
            VStack(spacing: 6) {
                ForEach(Self.options.reversed(), id: \.rate) { button(for: $0, height: 42) }
            }
        }
        Text("播放中长按画面，临时 2 倍速")
            .font(.system(size: 11))
            .foregroundStyle(secondaryOnDark)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
    }

    private func button(for option: (rate: Float, title: String), height: CGFloat) -> some View {
        let on = option.rate == controller.rate
        return Button {
            controller.setRate(option.rate)
        } label: {
            Text(verbatim: option.title)
                .font(.system(size: 15, weight: on ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(on ? accent : .white)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(.white.opacity(on ? 0.16 : 0.08), in: .rect(cornerRadius: 12))
                .overlay {
                    if on { RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.3), lineWidth: 0.5) }
                }
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - 更多

struct MorePanel: View {
    let controller: PlayerController
    /// nil：直播间。不显示播放方式（直播不会播完）、稍后再看和删除
    let model: VideoDetailModel?

    init(model: VideoDetailModel) {
        controller = model.player
        self.model = model
    }

    init(controller: PlayerController, model: VideoDetailModel?) {
        self.controller = controller
        self.model = model
    }
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
            if model != nil {
                Menu {
                    Picker("播放方式", selection: Binding(get: { controller.endAction }, set: { controller.endAction = $0 })) {
                        ForEach(PlayerController.EndAction.allCases, id: \.self) { action in
                            Label(action.title, systemImage: action.icon).tag(action)
                        }
                    }
                } label: {
                    tileLabel(controller.endAction.icon, controller.endAction.title, on: controller.endAction != .next)
                }
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
            if let model {
                // 和其他七格同一套方块图标；加过之后换成打勾的钟、点亮成主题色
                Button(action: addToWatchLater) {
                    tileLabel(addedToWatchLater ? "已加稍后看" : "稍后再看", on: addedToWatchLater) {
                        WatchLaterGlyph(added: addedToWatchLater)
                    }
                }
                .buttonStyle(PressableStyle())
                .accessibilityAddTraits(addedToWatchLater ? .isSelected : [])
                .disabled(aid <= 0)
                DeleteVideoControl(card: model.deletionCard)
            }
        }
    }

    @State private var addedToWatchLater = false

    private var aid: Int {
        guard let model else { return 0 }
        return model.detail?.aid ?? model.offline?.aid ?? model.card.id
    }

    private func addToWatchLater() {
        // 加过了不再变灰（禁用态会把点亮的主题色压暗），再点只提示
        guard !addedToWatchLater else {
            ToastCenter.shared.show("已经在稍后再看里了")
            return
        }
        let aid = aid
        Task {
            do {
                try await WatchLater.add(aid: aid)
                withAnimation(Motion.micro) { addedToWatchLater = true }
                ToastCenter.shared.show("已添加到稍后再看")
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func tile(_ icon: String, _ title: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(icon, title, on: on) }
            .buttonStyle(PressableStyle())
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func tileLabel(_ icon: String, _ title: String, on: Bool) -> some View {
        tileLabel(title, on: on) {
            Image(systemName: icon).contentTransition(.symbolEffect(.replace))
        }
    }

    private func tileLabel(_ title: String, on: Bool, @ViewBuilder glyph: () -> some View) -> some View {
        VStack(spacing: 6) {
            glyph()
                .font(.system(size: 20))
                .foregroundStyle(on ? accent : .white)
                .frame(width: 48, height: 48)
                .background(on ? accent.opacity(0.22) : Color.white.opacity(0.08), in: .rect(cornerRadius: 16))
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(on ? accent : secondaryOnDark)
        }
    }
}

/// 稍后再看的图标：时钟右上角挂一个小「+」，加过后换成「✓」。
/// 系统的 clock.badge.plus 在当前系统上画不出来（格子是空的），用两个一定存在的符号拼
private struct WatchLaterGlyph: View {
    let added: Bool

    var body: some View {
        Image(systemName: "clock")
            .overlay(alignment: .topTrailing) {
                Image(systemName: added ? "checkmark" : "plus")
                    .font(.system(size: 10, weight: .heavy))
                    .contentTransition(.symbolEffect(.replace))
                    .offset(x: 7, y: -5)
            }
            // 角标往右上挪了，整体往左下回一点，看起来仍在格子正中
            .offset(x: -2, y: 1)
            .accessibilityHidden(true)
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
