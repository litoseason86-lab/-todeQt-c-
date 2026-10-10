import IPadCore
import SwiftUI

@MainActor struct SettingsPage: View {
    @Environment(ShellStore.self) private var shell
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: SettingsSection? = .general
    @Environment(SettingsStore.self) private var store

    var body: some View {
        layout(store).navigationTitle("设置")
    }
    @ViewBuilder private func layout(_ store: SettingsStore) -> some View {
        if sizeClass == .compact {
            List { ForEach(SettingsAvailability.sections) { section in NavigationLink(section.rawValue, value: section) } }
                .navigationDestination(for: SettingsSection.self) { detail($0, store: store) }
        } else {
            NavigationSplitView {
                List(SettingsAvailability.sections, selection: $selection) { Text($0.rawValue).tag(Optional($0)) }.navigationTitle("设置")
            } detail: { detail(selection ?? .general, store: store) }
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
        Form {
            Section("专注") {
                Stepper("专注时长：\(store.snapshot.workMinutes) 分钟", value: Binding(get: { store.snapshot.workMinutes }, set: store.setWorkMinutes), in: 5...180)
                Stepper("休息时长：\(store.snapshot.breakMinutes) 分钟", value: Binding(get: { store.snapshot.breakMinutes }, set: store.setBreakMinutes), in: 1...60)
                Toggle("长休息", isOn: Binding(get: { store.snapshot.longBreakEnabled }, set: store.setLongBreakEnabled))
                if store.snapshot.longBreakEnabled {
                    Stepper("长休息：\(store.snapshot.longBreakMinutes) 分钟", value: Binding(get: { store.snapshot.longBreakMinutes }, set: store.setLongBreakMinutes), in: 5...60)
                    Stepper("每 \(store.snapshot.longBreakInterval) 个番茄长休息", value: Binding(get: { store.snapshot.longBreakInterval }, set: store.setLongBreakInterval), in: 2...8)
                }
                Toggle("快速开始", isOn: Binding(get: { store.snapshot.quickStartEnabled }, set: store.setQuickStartEnabled))
                Toggle("自动开始休息", isOn: Binding(get: { store.snapshot.autoStartBreak }, set: store.setAutoStartBreak))
                Toggle("自动开始下个番茄", isOn: Binding(get: { store.snapshot.autoStartNextPomodoro }, set: store.setAutoStartNextPomodoro))
                Stepper("自由计时超时确认：\(store.snapshot.freeTimerWarningHours) 小时", value: Binding(get: { store.snapshot.freeTimerWarningHours }, set: store.setFreeTimerWarningHours), in: 1...24)
                Toggle("阶段结束提示音", isOn: Binding(get: { store.snapshot.soundEnabled }, set: store.setSoundEnabled))
            }
            Section("个人") {
                TextField("昵称", text: Binding(get: { store.snapshot.nickname }, set: store.setNickname))
            }
            Section("日期") { Stepper("日界：\(store.snapshot.dayStartHour):00", value: Binding(get: { store.snapshot.dayStartHour }, set: { store.setDayStartHour($0) }), in: 0...23) }
            if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(ThemeColors.danger) }
        }.formStyle(.grouped).navigationTitle("通用")
    }
}

@MainActor private struct AppearanceSettings: View {
    @Bindable var store: SettingsStore
    @Bindable var shell: ShellStore
    var body: some View {
        Form {
            Section("背景") {
                Toggle("使用壁纸", isOn: Binding(get: { shell.snapshot.useWallpaper }, set: { shell.setUseWallpaper($0) }))
                Picker("背景主题", selection: Binding(get: { store.snapshot.backgroundTheme }, set: store.setBackgroundTheme)) {
                    ForEach(SettingsAvailability.themes, id: \.id) { Text($0.title).tag($0.id) }
                }
                Toggle("纤细时钟字体", isOn: Binding(get: { store.snapshot.slimClockFont }, set: store.setSlimClockFont))
                Toggle("仪表盘计时摘要", isOn: Binding(get: { store.snapshot.dashboardTimerVisible }, set: store.setDashboardTimerVisible))
            }
            Section("界面") {
                Button("使用旧版界面（下次启动生效）") { shell.useLegacyUIOnNextLaunch() }
                    .disabled(shell.snapshot.operationBlocksUI)
            }
            if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(ThemeColors.danger) }
            if !shell.errorMessage.isEmpty { Text(shell.errorMessage).foregroundStyle(ThemeColors.danger) }
        }.formStyle(.grouped).navigationTitle("外观")
    }
}

@MainActor private struct SidebarSettings: View {
    @Bindable var store: SettingsStore
    private var movablePages: [PageID] {
        PageID.ordered(store.snapshot.sidebarOrder).filter { !PageID.fixed.contains($0) }
    }
    var body: some View {
        List {
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
        }.toolbar { EditButton() }.navigationTitle("侧栏顺序")
    }
}
