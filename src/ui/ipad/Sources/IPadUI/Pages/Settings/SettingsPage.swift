import IPadCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct SettingsPage: View {
    @Environment(CoreBridges.self) private var bridges
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
        case .sync: SyncSettings(bridge: bridges.sync)
        case .backup: BackupSettings(bridge: bridges.backup, pendingDeletion: bridges.pendingDeletion, warning: bridges.sync.restoreWarning())
        case .export: ExportSettings(bridge: bridges.export, today: bridges.logicalDay.today)
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
            if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(ThemeColors.danger) }
            if !shell.errorMessage.isEmpty { Text(shell.errorMessage).foregroundStyle(ThemeColors.danger) }
        }.formStyle(.grouped).navigationTitle("外观")
    }
}

@MainActor private struct SidebarSettings: View {
    @Bindable var store: SettingsStore
    var body: some View {
        List {
            Section { ForEach(PageID.ordered(store.snapshot.sidebarOrder).filter { !PageID.fixed.contains($0) }, id: \.self) { page in Text(page.title) }.onMove { offsets, destination in var values = PageID.ordered(store.snapshot.sidebarOrder).filter { !PageID.fixed.contains($0) }; values.move(fromOffsets: offsets, toOffset: destination); store.setSidebarOrder(values) } }
            Section("固定入口") { ForEach(PageID.fixed, id: \.self) { Text($0.title) } }
            Section { Button("恢复默认顺序", systemImage: "arrow.counterclockwise") { store.resetSidebarOrder() } }
        }.toolbar { EditButton() }.navigationTitle("侧栏顺序")
    }
}

@MainActor private struct SyncSettings: View {
    let bridge: any SyncBridgeProtocol
    @State private var snapshot = SyncSnapshot(); @State private var logs: [SyncLogEntry] = []; @State private var error = ""
    var body: some View { Form { Section("同步") { Toggle("启用同步", isOn: Binding(get: { snapshot.enabled }, set: { bridge.setEnabled($0); refresh() })); Text(snapshot.summaryText); Button("选择同步文件夹", systemImage: "folder") { bridge.chooseFolder() }; Button("立即同步", systemImage: "arrow.triangle.2.circlepath") { bridge.syncNow() } }; Section("日志") { Button("刷新日志") { loadLogs() }; ForEach(logs) { entry in VStack(alignment: .leading) { Text("\(entry.time) · \(entry.title)"); if !entry.lostValue.isEmpty { Button("复制丢失值", systemImage: "doc.on.doc") { bridge.copyLostValue(entry.lostValue) }.font(.caption) } } } }; if !error.isEmpty { Text(error).foregroundStyle(ThemeColors.danger) } }.navigationTitle("同步与日志").task { refresh(); loadLogs() } }
    private func refresh() { snapshot = bridge.snapshot() }
    private func loadLogs() { do { logs = try bridge.syncLog(limit: 200); error = "" } catch let caught { error = caught.localizedDescription } }
}

@MainActor private struct BackupSettings: View {
    let bridge: any BackupBridgeProtocol
    let pendingDeletion: PendingDeletionStore
    let warning: String
    @State private var snapshot: (lastBackupTimeIso: String, busy: Bool, operationBlocksUI: Bool, operationText: String) = ("", false, false, "")
    @State private var document = TransferDocument(data: Data()); @State private var exportPresented = false; @State private var importPresented = false; @State private var tempURL: URL?; @State private var restoreWarning = ""
    @State private var backups: [[String: Any]] = []; @State private var error = ""
    var body: some View {
        Form { Toggle("自动备份", isOn: Binding(get: { bridge.autoBackupEnabled() }, set: { try? bridge.setAutoBackupEnabled($0) })); Text(snapshot.lastBackupTimeIso.isEmpty ? "尚未备份" : snapshot.lastBackupTimeIso); Button("创建备份", systemImage: "externaldrive") { createBackup() }; Button("恢复备份", systemImage: "arrow.uturn.backward") { restoreWarning = warning.isEmpty ? "恢复会替换本机数据。" : warning; importPresented = true }; Section("已有备份") { ForEach(Array(backups.enumerated()), id: \.offset) { _, item in Text(item["name"] as? String ?? "备份文件") } }; if !restoreWarning.isEmpty { Text(restoreWarning).foregroundStyle(.secondary) }; if !error.isEmpty { Text(error).foregroundStyle(ThemeColors.danger) } }
            .navigationTitle("备份与恢复")
            .fileExporter(isPresented: $exportPresented, document: document, contentType: .data, defaultFilename: bridge.suggestedBackupFileName()) { _ in cleanup() }
            .fileImporter(isPresented: $importPresented, allowedContentTypes: [.data]) { result in if case let .success(url) = result { guard pendingDeletion.commitIfNeeded() else { error = "还有待提交的删除，恢复已取消"; return }; _ = url.startAccessingSecurityScopedResource(); bridge.requestRestore(path: url.path); url.stopAccessingSecurityScopedResource() } }
            .task { [bridge] in snapshot = bridge.snapshot(); do { backups = try bridge.readBackups() } catch { self.error = error.localizedDescription }; bridge.onBackupCompleted = { [bridge] ok, _ in guard ok, let tempURL else { return }; document = TransferDocument(url: tempURL); exportPresented = true; bridge.onBackupCompleted = nil } }
    }
    private func createBackup() { let url = FileManager.default.temporaryDirectory.appendingPathComponent(bridge.suggestedBackupFileName()); tempURL = url; bridge.requestBackup(path: url.path) }
    private func cleanup() { if let tempURL { try? FileManager.default.removeItem(at: tempURL) }; tempURL = nil }
}

@MainActor private struct ExportSettings: View {
    let bridge: any ExportBridgeProtocol
    let today: String
    @State private var document = TransferDocument(data: Data()); @State private var exportPresented = false; @State private var tempURL: URL?
    @State private var kind = "tasks"; @State private var startDate = "2026-01-01"; @State private var endDate = ""
    var body: some View { Form { TextField("开始日期（yyyy-MM-dd）", text: $startDate); TextField("结束日期（yyyy-MM-dd）", text: $endDate); Button("导出任务", systemImage: "square.and.arrow.up") { start("tasks") }; Button("导出专注记录", systemImage: "square.and.arrow.up") { start("focus_sessions") }; Button("导出全部", systemImage: "square.and.arrow.up") { start("all") } }.navigationTitle("导出").fileExporter(isPresented: $exportPresented, document: document, contentType: .commaSeparatedText, defaultFilename: bridge.generateFileName(type: kind, startDate: startDate, endDate: endDate.isEmpty ? today : endDate)) { _ in cleanup() }.task { [bridge] in if endDate.isEmpty { endDate = today }; bridge.onCompleted = { [bridge] ok, _ in guard ok, let tempURL else { return }; document = TransferDocument(url: tempURL); exportPresented = true; bridge.onCompleted = nil } } }
    private func start(_ value: String) { kind = value; let finish = endDate.isEmpty ? today : endDate; let url = FileManager.default.temporaryDirectory.appendingPathComponent(bridge.generateFileName(type: value, startDate: startDate, endDate: finish)); tempURL = url; if value == "tasks" { bridge.exportTasks(startDate: startDate, endDate: finish, path: url.path) } else if value == "focus_sessions" { bridge.exportFocusSessions(startDate: startDate, endDate: finish, path: url.path) } else { bridge.exportAll(startDate: startDate, endDate: finish, directory: url.deletingLastPathComponent().path) } }
    private func cleanup() { if let tempURL { try? FileManager.default.removeItem(at: tempURL) }; tempURL = nil }
}

private struct TransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .commaSeparatedText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(url: URL) { data = (try? Data(contentsOf: url)) ?? Data() }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
