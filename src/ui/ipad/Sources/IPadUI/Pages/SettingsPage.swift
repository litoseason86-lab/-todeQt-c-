import IPadCore
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "通用", categories = "科目", routines = "每日例行", sidebar = "侧栏顺序", sync = "同步与日志", backup = "备份与恢复", export = "导出", appearance = "外观"
    var id: String { rawValue }
}

@MainActor struct SettingsPage: View {
    @Environment(CoreBridges.self) private var bridges
    @Environment(ShellStore.self) private var shell
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: SettingsSection? = .general
    @State private var store: SettingsStore?

    var body: some View {
        Group {
            if let store { layout(store) }
            else { ProgressView().task { store = SettingsStore(bridge: bridges.settings) } }
        }.navigationTitle("设置")
    }
    @ViewBuilder private func layout(_ store: SettingsStore) -> some View {
        if sizeClass == .compact {
            List { ForEach(SettingsSection.allCases) { section in NavigationLink(section.rawValue, value: section) } }
                .navigationDestination(for: SettingsSection.self) { detail($0, store: store) }
        } else {
            NavigationSplitView {
                List(SettingsSection.allCases, selection: $selection) { Text($0.rawValue).tag(Optional($0)) }.navigationTitle("设置")
            } detail: { detail(selection ?? .general, store: store) }
        }
    }
    @ViewBuilder private func detail(_ section: SettingsSection, store: SettingsStore) -> some View {
        switch section {
        case .general: GeneralSettings(store: store)
        case .categories: CategoriesSettings(bridge: bridges.categories)
        case .routines: RoutinesSettings(bridge: bridges.routines)
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
                Stepper("专注时长：\(store.snapshot.workMinutes) 分钟", value: Binding(get: { store.snapshot.workMinutes }, set: { store.setWorkMinutes($0) }), in: 1...180)
                Stepper("休息时长：\(store.snapshot.breakMinutes) 分钟", value: Binding(get: { store.snapshot.breakMinutes }, set: { store.setBreakMinutes($0) }), in: 1...120)
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
                Picker("背景主题", selection: Binding(get: { store.snapshot.backgroundTheme }, set: { store.setBackgroundTheme($0) })) { Text("暖色").tag("warm"); Text("浅色").tag("light"); Text("星空").tag("starry"); Text("雨夜").tag("rainy"); Text("月光").tag("moon") }
            }
        }.formStyle(.grouped).navigationTitle("外观")
    }
}

@MainActor private struct SidebarSettings: View {
    @Bindable var store: SettingsStore
    var body: some View {
        List {
            Section { ForEach(PageID.ordered(store.snapshot.sidebarOrder), id: \.self) { page in Text(page.title) }.onMove { offsets, destination in var values = PageID.ordered(store.snapshot.sidebarOrder); values.move(fromOffsets: offsets, toOffset: destination); store.setSidebarOrder(values) } }
            Section { Button("恢复默认顺序", systemImage: "arrow.counterclockwise") { store.resetSidebarOrder() } }
        }.environment(\.editMode, .constant(.active)).toolbar { EditButton() }.navigationTitle("侧栏顺序")
    }
}

@MainActor private struct CategoriesSettings: View {
    let bridge: any CategoryBridgeProtocol
    @State private var values: [CategoryValue] = []; @State private var name = ""; @State private var error = ""
    @State private var editing: CategoryValue?; @State private var deletingID: Int?
    var body: some View {
        List {
            ForEach(values, id: \.id) { value in
                HStack {
                    Circle().fill(.gray).frame(width: 12, height: 12)
                    Text(value.name)
                    Spacer()
                    Button("编辑", systemImage: "pencil") { editing = value }.labelStyle(.iconOnly)
                }
                .swipeActions(edge: .trailing) {
                    Button("删除", systemImage: "trash", role: .destructive) { deletingID = value.id }
                        .disabled(value.isPreset || !bridge.canDelete(id: value.id))
                }
            }
            Section { TextField("新科目", text: $name); Button("新增") { add() } }
            if !error.isEmpty { Text(error).foregroundStyle(ThemeColors.danger) }
        }
        .navigationTitle("科目").task { reload() }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) { if let value = editing { CategoryEditor(value: value) { editedName, color in update(value.id, name: editedName, color: color) } } }
        .alert("确认删除科目？", isPresented: Binding(get: { deletingID != nil }, set: { if !$0 { deletingID = nil } })) {
            Button("删除", role: .destructive) { if let id = deletingID { delete(id); deletingID = nil } }
            Button("取消", role: .cancel) { deletingID = nil }
        } message: { Text("删除会解除任务、例行、课表和知识缺口的科目关联。") }
    }
    private func reload() { do { values = try bridge.allCategories(); error = "" } catch let caught { error = caught.localizedDescription } }
    private func add() { let value = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty else { return }; do { _ = try bridge.add(name: value, color: "#d4a574"); name = ""; reload() } catch let caught { error = caught.localizedDescription } }
    private func update(_ id: Int, name: String, color: String) { do { try bridge.update(id: id, name: name, color: color); reload() } catch let caught { error = caught.localizedDescription } }
    private func delete(_ id: Int) { do { try bridge.delete(id: id); reload() } catch let caught { error = caught.localizedDescription } }
}

@MainActor private struct CategoryEditor: View {
    let value: CategoryValue; let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String; @State private var color: String
    init(value: CategoryValue, onSave: @escaping (String, String) -> Void) { self.value = value; self.onSave = onSave; _name = State(initialValue: value.name); _color = State(initialValue: value.color) }
    var body: some View { NavigationStack { Form { TextField("名称", text: $name); TextField("颜色", text: $color) }.navigationTitle("编辑科目").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), color); dismiss() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } } } }
}

@MainActor private struct RoutinesSettings: View {
    let bridge: any RoutineBridgeProtocol
    @State private var values: [[String: Any]] = []; @State private var title = ""; @State private var error = ""
    @State private var editing: [String: Any]?; @State private var deletingID: Int?
    var body: some View {
        List {
            ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                let id = item["id"] as? Int ?? -1
                HStack {
                    VStack(alignment: .leading) { Text(item["title"] as? String ?? "每日例行"); Text(weekdayText(item["weekdays"] as? Int ?? 127)).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Toggle("启用", isOn: Binding(get: { item["active"] as? Bool ?? false }, set: { setActive(id, $0) })).labelsHidden()
                    Button("编辑", systemImage: "pencil") { editing = item }.labelStyle(.iconOnly)
                }
                .swipeActions { Button("删除", systemImage: "trash", role: .destructive) { deletingID = id } }
            }
            Section { TextField("新例行", text: $title); Button("新增") { add() } }
            if !error.isEmpty { Text(error).foregroundStyle(ThemeColors.danger) }
        }
        .navigationTitle("每日例行").task { reload() }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) { if let editing { RoutineEditor(item: editing) { id, newTitle, weekdays in update(id, title: newTitle, weekdays: weekdays) } } }
        .alert("确认删除每日例行？", isPresented: Binding(get: { deletingID != nil }, set: { if !$0 { deletingID = nil } })) { Button("删除", role: .destructive) { if let id = deletingID { delete(id); deletingID = nil } }; Button("取消", role: .cancel) { deletingID = nil } }
    }
    private func reload() { values = bridge.routines() }
    private func add() { do { try bridge.add(title: title.trimmingCharacters(in: .whitespacesAndNewlines), categoryID: -1, weekdays: 127); title = ""; reload() } catch let caught { error = caught.localizedDescription } }
    private func setActive(_ id: Int, _ active: Bool) { do { try bridge.setActive(id: id, active: active); reload() } catch let caught { error = caught.localizedDescription } }
    private func update(_ id: Int, title: String, weekdays: Int) { do { try bridge.update(id: id, changes: ["title": title]); try bridge.setWeekdays(id: id, weekdays: weekdays); reload() } catch let caught { error = caught.localizedDescription } }
    private func delete(_ id: Int) { do { try bridge.delete(id: id); reload() } catch let caught { error = caught.localizedDescription } }
    private func weekdayText(_ mask: Int) -> String { let names = ["一", "二", "三", "四", "五", "六", "日"]; let selected = names.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? "周\($0.element)" : nil }; return selected.isEmpty ? "不重复" : selected.joined(separator: "、") }
}

@MainActor private struct RoutineEditor: View {
    let item: [String: Any]; let onSave: (Int, String, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String; @State private var weekdays: Int
    init(item: [String: Any], onSave: @escaping (Int, String, Int) -> Void) { self.item = item; self.onSave = onSave; _title = State(initialValue: item["title"] as? String ?? ""); _weekdays = State(initialValue: item["weekdays"] as? Int ?? 127) }
    var body: some View { NavigationStack { Form { TextField("标题", text: $title); Stepper("星期掩码：\(weekdays)", value: $weekdays, in: 0...127) }.navigationTitle("编辑每日例行").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { if let id = item["id"] as? Int { onSave(id, title.trimmingCharacters(in: .whitespacesAndNewlines), weekdays); dismiss() } }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } } } }
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
