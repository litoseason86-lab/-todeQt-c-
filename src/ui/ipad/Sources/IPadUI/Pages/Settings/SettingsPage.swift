import IPadCore
import ImageIO
import PTBridge
import SwiftUI

@MainActor struct SettingsPage: View {
    @Environment(ShellStore.self) private var shell
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(SettingsStore.self) private var store

    var body: some View {
        layout(store)
    }
    @ViewBuilder private func layout(_ store: SettingsStore) -> some View {
        if sizeClass == .compact {
            List {
                ForEach(SettingsAvailability.sections) { section in
                    NavigationLink(section.rawValue, value: section)
                        .listRowBackground(shell.selectedTheme != nil ? ThemeColors.surface : nil)
                }
            }
            .navigationTitle("设置")
            .navigationDestination(for: SettingsSection.self) { detail($0, store: store).modifier(PageBackground()).navigationTitle($0.rawValue) }
        } else {
            // 055-R4：左栏每行是明确的按钮。List(selection:) 放在分栏侧栏之外时，iPadOS 上点按不会改选中，
            // 10-11 真机实测点「科目」「每日例行」都切不过去。
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(SettingsAvailability.sections) { section in
                        sectionButton(section, selected: section == store.selectedSection)
                    }
                }
                .frame(width: 240)
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.selectedSectionTitle).font(.title2.bold()).foregroundStyle(ThemeColors.inkStrong)
                        .padding(.horizontal, 20).padding(.top, 8)
                    detail(store.selectedSection, store: store)
                }
                .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 32).padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("设置")
        }
    }
    private func sectionButton(_ section: SettingsSection, selected: Bool) -> some View {
        Button { store.selectSection(section) } label: {
            Text(section.rawValue)
                .font(.body.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? ThemeColors.surface : ThemeColors.inkStrong)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 14)
                .background(selected ? ThemeColors.accentInk : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    @ViewBuilder private func detail(_ section: SettingsSection, store: SettingsStore) -> some View {
        switch section {
        case .general: GeneralSettings(store: store)
        case .categories: CategoriesSettings()
        case .routines: RoutinesSettings()
        case .sidebar: SidebarSettings(store: store)
        case .sync: SyncSettings()
        case .backup: BackupSettings()
        case .export: ExportSettings()
        case .appearance: AppearanceSettings(store: store, shell: shell)
        }
    }
}

@MainActor private struct GeneralSettings: View {
    @Bindable var store: SettingsStore
    var body: some View {
        SettingsForm {
            Section("专注") {
                // 定稿：左边名称，右边数值紧挨步进器。
                valueStepper("专注时长", "\(store.snapshot.workMinutes) 分钟", value: Binding(get: { store.snapshot.workMinutes }, set: store.setWorkMinutes), in: 5...180)
                valueStepper("休息时长", "\(store.snapshot.breakMinutes) 分钟", value: Binding(get: { store.snapshot.breakMinutes }, set: store.setBreakMinutes), in: 1...60)
                NavigationLink {
                    longBreakForm
                } label: { LabeledContent("长休息", value: store.longBreakSummary) }
                Toggle("自动开始休息", isOn: Binding(get: { store.snapshot.autoStartBreak }, set: store.setAutoStartBreak))
                Toggle("自动开始下个番茄", isOn: Binding(get: { store.snapshot.autoStartNextPomodoro }, set: store.setAutoStartNextPomodoro))
                Toggle("快速开始", isOn: Binding(get: { store.snapshot.quickStartEnabled }, set: store.setQuickStartEnabled))
                Picker("自由计时超时确认", selection: Binding(get: { store.snapshot.freeTimerWarningHours }, set: store.setFreeTimerWarningHours)) {
                    ForEach(1...24, id: \.self) { Text("\($0) 小时").tag($0) }
                }.pickerStyle(.menu)
            }
            Section("提示、日期与个人") {
                Toggle("阶段结束提示音", isOn: Binding(get: { store.snapshot.soundEnabled }, set: store.setSoundEnabled))
                Picker("一天从几点开始", selection: Binding(get: { store.snapshot.dayStartHour }, set: store.setDayStartHour)) {
                    ForEach(0...23, id: \.self) { Text("\($0):00").tag($0) }
                }.pickerStyle(.menu)
                LabeledContent("昵称") {
                    TextField("昵称", text: Binding(get: { store.snapshot.nickname }, set: store.setNickname))
                        .multilineTextAlignment(.trailing)
                }
            }
            if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(ThemeColors.danger) }
        }.formStyle(.grouped)
    }
    private var longBreakForm: some View {
        SettingsForm {
            Section {
                Toggle("长休息", isOn: Binding(get: { store.snapshot.longBreakEnabled }, set: store.setLongBreakEnabled))
                valueStepper("长休息时长", "\(store.snapshot.longBreakMinutes) 分钟", value: Binding(get: { store.snapshot.longBreakMinutes }, set: store.setLongBreakMinutes), in: 5...60)
                    .disabled(!store.snapshot.longBreakEnabled)
                valueStepper("间隔", "每 \(store.snapshot.longBreakInterval) 个番茄", value: Binding(get: { store.snapshot.longBreakInterval }, set: store.setLongBreakInterval), in: 2...8)
                    .disabled(!store.snapshot.longBreakEnabled)
            }
            if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(ThemeColors.danger) }
        }.formStyle(.grouped).navigationTitle("长休息")
    }

}

@MainActor private struct AppearanceSettings: View {
    @Bindable var store: SettingsStore
    @Bindable var shell: ShellStore
    private let systemModes: [(String, String)] = [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")]
    // 定稿外观：「明暗」一行三段（选了主题时三段都不亮）；主题是七张壁纸缩略图网格；再下「使用壁纸」。
    var body: some View {
        SettingsForm {
            Section("系统外观") {
                HStack {
                    Text("明暗").foregroundStyle(ThemeColors.inkStrong)
                    Spacer()
                    HStack(spacing: 2) {
                        ForEach(systemModes, id: \.0) { mode in
                            let selected = shell.selectedSystemAppearance == mode.0
                            Button { shell.setAppearance(mode.0) } label: {
                                Text(mode.1).scaledSystemFont(size: 14, weight: selected ? .semibold : .regular)
                                    .foregroundStyle(selected ? ThemeColors.accentFillInk : ThemeColors.ink)
                                    .padding(.horizontal, 14).frame(height: 32)
                                    .background(selected ? ThemeColors.surface : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    .padding(3)
                    .background(ThemeColors.accentFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            Section("主题") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 132), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(SettingsAvailability.themes, id: \.id) { theme in
                        let selected = shell.selectedTheme == theme.id
                        Button { shell.selectTheme(theme.id) } label: {
                            VStack(spacing: 6) {
                                ThemeThumbnail(theme: theme.id)
                                    .frame(height: 68)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(selected ? ThemeColors.accentInk : ThemeColors.border, lineWidth: selected ? 3 : 1)
                                    }
                                Text(theme.title).scaledSystemFont(size: 13, weight: selected ? .semibold : .regular)
                                    .foregroundStyle(ThemeColors.inkStrong)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(theme.title)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 8)
                Toggle("使用壁纸", isOn: Binding(
                    get: { shell.wallpaperVisible },
                    set: { shell.setUseWallpaper($0) }))
                .disabled(!shell.wallpaperAvailable || shell.operationBlocksUI)
            }
            Section {
                Toggle("纤细时钟字体", isOn: Binding(get: { store.snapshot.slimClockFont }, set: store.setSlimClockFont))
                Button("使用旧版界面（下次启动生效）") { shell.useLegacyUIOnNextLaunch() }
                    .foregroundStyle(ThemeColors.accentInk)
                    .disabled(shell.operationBlocksUI)
            }
            if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(ThemeColors.danger) }
            if !shell.errorMessage.isEmpty { Text(shell.errorMessage).foregroundStyle(ThemeColors.danger) }
        }.formStyle(.grouped)
    }
}

// 主题缩略图：从 Qt 已打包的壁纸按 320 像素缩略解码（ImageIO 直接出小图，不先解出整张大图），
// 解过的留在内存里；没有壁纸的主题只画它的底色。
@MainActor private struct ThemeThumbnail: View {
    let theme: String
    @State private var image: UIImage?
    private static var cache: [String: UIImage] = [:]
    var body: some View {
        ZStack {
            ThemeColors.themeBase(theme)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .task(id: theme) {
            guard !Task.isCancelled else { return }
            image = nil
            if let cached = Self.cache[theme] { image = cached; return }
            // 桥接只能在主线程读取资源；解码 PNG 和缩小图片会占住主线程，交给不继承 MainActor 的独立任务。
            guard let data = PTShellBridge.wallpaperData(forTheme: theme) else { return }
            let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 320,
                               kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
                return UIImage(cgImage: thumbnail)
            }.value
            guard let value = decoded else { return }
            Self.cache[theme] = value
            // 离页或换主题后仍可复用已解码缓存，但旧任务不能再覆盖当前视图的状态。
            guard !Task.isCancelled else { return }
            image = value
        }
    }
}

@MainActor private struct SidebarSettings: View {
    @Bindable var store: SettingsStore
    private var movablePages: [PageID] {
        PageID.ordered(store.snapshot.sidebarOrder).filter { !PageID.fixed.contains($0) }
    }
    var body: some View {
        SettingsForm {
            Section {
                ForEach(movablePages, id: \.self) { Text($0.title) }
                    .onMove { offsets, destination in
                        var values = movablePages
                        values.move(fromOffsets: offsets, toOffset: destination)
                        store.setSidebarOrder(values)
                    }
            }
            Section("固定入口") { ForEach(PageID.fixed, id: \.self) { Text($0.title) } }
            Section { Button("恢复默认顺序", systemImage: "arrow.counterclockwise") { store.resetSidebarOrder() } }
            if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(ThemeColors.danger) }
        }.formStyle(.grouped).toolbar { EditButton() }
    }
}

// 设置分组统一使用系统 Form（分组表单）；主题下只换语义纸面和底色，不仿制系统控件。
// 设置里的数值行：名称在左，当前值与步进器在右。
@MainActor func valueStepper(_ title: String, _ value: String, value binding: Binding<Int>, in range: ClosedRange<Int>) -> some View {
    HStack {
        Text(title).foregroundStyle(ThemeColors.inkStrong)
        Spacer()
        Text(value).monospacedDigit().foregroundStyle(ThemeColors.ink)
        AccentStepper(title: "\(title)，\(value)", value: binding, range: range)
    }
}

// 定稿的步进器：浅焦糖底、焦糖色「− +」；系统 Stepper 的灰底改不了色，所以自己排两个按钮。
// 长按连续加减沿用系统按钮的重复触发；读屏仍按系统步进器读（可上下轻扫调整）。
@MainActor struct AccentStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        HStack(spacing: 0) {
            button("minus", enabled: value > range.lowerBound) { value = max(range.lowerBound, value - step) }
            button("plus", enabled: value < range.upperBound) { value = min(range.upperBound, value + step) }
        }
        .background(ThemeColors.accentFill.opacity(isEnabled ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityRepresentation { Stepper(title, value: $value, in: range, step: step) }
    }
    private func button(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).scaledSystemFont(size: 13, weight: .semibold)
                .frame(width: 44, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .buttonRepeatBehavior(.enabled)
        .foregroundStyle(enabled && isEnabled ? ThemeColors.accentInk : ThemeColors.inkMuted)
        .disabled(!enabled)
    }
}

@MainActor struct SettingsForm<Content: View>: View {
    @Environment(ShellStore.self) private var shell
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        // 页底与壁纸由外壳统一铺，表单只把滚动底色放开，不再叠一层壁纸。
        Form { content.listRowBackground(shell.selectedTheme != nil ? ThemeColors.surface : nil) }
            .formStyle(.grouped)
            .scrollContentBackground(shell.selectedTheme != nil ? .hidden : .visible)
    }
}
