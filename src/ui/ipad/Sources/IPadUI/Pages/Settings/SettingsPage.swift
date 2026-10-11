import IPadCore
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
                }
            }
            .navigationTitle("设置")
                .navigationDestination(for: SettingsSection.self) { detail($0, store: store) }
        } else {
            HStack(spacing: 0) {
                List(SettingsAvailability.sections,
                     selection: Binding(get: { Optional(store.selectedSection) },
                                        set: { if let section = $0 { store.selectSection(section) } })) { section in
                    Text(section.rawValue).tag(Optional(section))
                }
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 300)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(store.selectedSectionTitle).font(.title2.bold()).padding(.horizontal, 20)
                    detail(store.selectedSection, store: store)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 32).padding(.vertical, 16)
            .navigationTitle("设置")
        }
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
                Stepper("专注时长：\(store.snapshot.workMinutes) 分钟", value: Binding(get: { store.snapshot.workMinutes }, set: store.setWorkMinutes), in: 5...180)
                Stepper("休息时长：\(store.snapshot.breakMinutes) 分钟", value: Binding(get: { store.snapshot.breakMinutes }, set: store.setBreakMinutes), in: 1...60)
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
        }.formStyle(.grouped).navigationTitle("通用")
    }
    private var longBreakForm: some View {
        SettingsForm {
            Section {
                Toggle("长休息", isOn: Binding(get: { store.snapshot.longBreakEnabled }, set: store.setLongBreakEnabled))
                Stepper("长休息：\(store.snapshot.longBreakMinutes) 分钟", value: Binding(get: { store.snapshot.longBreakMinutes }, set: store.setLongBreakMinutes), in: 5...60)
                    .disabled(!store.snapshot.longBreakEnabled)
                Stepper("每 \(store.snapshot.longBreakInterval) 个番茄", value: Binding(get: { store.snapshot.longBreakInterval }, set: store.setLongBreakInterval), in: 2...8)
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
    var body: some View {
        SettingsForm {
            Section("系统外观") {
                ForEach(systemModes, id: \.0) { mode in
                    appearanceChoice(mode.1, selected: shell.selectedSystemAppearance == mode.0) {
                        shell.setAppearance(mode.0)
                    }
                }
            }
            Section("主题") {
                ForEach(SettingsAvailability.themes, id: \.id) { theme in
                    appearanceChoice(theme.title, selected: shell.selectedTheme == theme.id) {
                        shell.selectTheme(theme.id)
                    }
                }
                Toggle("使用壁纸", isOn: Binding(
                    get: { shell.wallpaperVisible },
                    set: { shell.setUseWallpaper($0) }))
                .disabled(!shell.wallpaperAvailable || shell.snapshot.operationBlocksUI)
            }
            Section("界面") {
                Toggle("纤细时钟字体", isOn: Binding(get: { store.snapshot.slimClockFont }, set: store.setSlimClockFont))
                Button("使用旧版界面（下次启动生效）") { shell.useLegacyUIOnNextLaunch() }
                    .disabled(shell.snapshot.operationBlocksUI)
            }
            if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(ThemeColors.danger) }
            if !shell.errorMessage.isEmpty { Text(shell.errorMessage).foregroundStyle(ThemeColors.danger) }
        }.formStyle(.grouped).navigationTitle("外观")
    }
    private func appearanceChoice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(ThemeColors.ink)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(ThemeColors.accentInk) }
            }
        }.accessibilityValue(selected ? "已选中" : "未选中")
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
        }.formStyle(.grouped).toolbar { EditButton() }.navigationTitle("侧栏顺序")
    }
}

// 设置分组统一使用系统 Form（分组表单）；主题下只换语义纸面和底色，不仿制系统控件。
@MainActor struct SettingsForm<Content: View>: View {
    @Environment(ShellStore.self) private var shell
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        Form { content.listRowBackground(shell.selectedTheme != nil ? ThemeColors.surface : nil) }
            .formStyle(.grouped)
            .scrollContentBackground(shell.selectedTheme != nil ? .hidden : .visible)
            .background { WallpaperBackground(theme: shell.snapshot.backgroundTheme, enabled: shell.wallpaperVisible) }
    }
}
