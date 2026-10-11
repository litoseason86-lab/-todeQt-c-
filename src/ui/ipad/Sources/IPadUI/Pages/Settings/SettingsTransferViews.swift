import Foundation
import IPadCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct SyncSettings: View {
    @Environment(SettingsSyncStore.self) private var store
    @State private var joinConfirmation = false
    var body: some View {
        SettingsForm {
            Section("同步") {
                Toggle("启用同步", isOn: Binding(get: { store.snapshot.enabled }, set: store.setEnabled))
                    .disabled(store.snapshot.busy)
                LabeledContent("同步文件夹", value: store.snapshot.folderDisplayPath.isEmpty ? "—" : store.snapshot.folderDisplayPath)
                if !store.snapshot.folderProblem.isEmpty { Text(store.snapshot.folderProblem).foregroundStyle(ThemeColors.danger) }
                Button(store.folderActionTitle, systemImage: "folder") {
                    if store.snapshot.statusKey == "folderMissing" { store.rebuildFolder() }
                    else { store.chooseFolder() }
                }.disabled(store.snapshot.busy || store.snapshot.choosingFolder)
            }
            Section("状态") {
                Text(store.snapshot.statusText).foregroundStyle(store.snapshot.hasProblem ? ThemeColors.danger : ThemeColors.ink)
                if !store.snapshot.statusDetail.isEmpty && store.snapshot.hasProblem {
                    Text(store.snapshot.statusDetail).foregroundStyle(ThemeColors.danger)
                }
                LabeledContent("上次同步", value: SyncTimeText.display(store.snapshot.lastSyncedAt))
                LabeledContent("待同步", value: store.pendingText)
                Button("立即同步", systemImage: "arrow.triangle.2.circlepath") { store.syncNow() }
                    .disabled(store.snapshot.busy || !store.snapshot.hasFolder)
                if store.snapshot.statusKey == "needsConfirmation" {
                    Button("确认加入") { joinConfirmation = true }
                    Button("暂不加入") { store.setEnabled(false) }
                }
            }
            Section { NavigationLink("同步日志（\(store.snapshot.logCount)）") { SyncLogSettings() } }
            if !store.notice.isEmpty { Text(store.notice).foregroundStyle(ThemeColors.ink) }
            if !store.errorMessage.isEmpty {
                Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                Button("重试读取同步状态") { store.refresh() }
            }
        }.formStyle(.grouped)
        .alert("加入同步文件夹？", isPresented: $joinConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认加入", role: .destructive) { store.confirmJoin() }
        } message: { Text("本机数据先自动备份，再换成同步文件夹里的数据。") }
        .task { store.refresh() }
    }
}

@MainActor private struct SyncLogSettings: View {
    @Environment(SettingsSyncStore.self) private var store
    var body: some View {
        List {
            if !store.errorMessage.isEmpty {
                Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                Button("重试读取日志") { store.reloadLogs() }
            }
            ForEach(store.logs) { entry in
                NavigationLink {
                    SettingsForm {
                        LabeledContent("时间", value: entry.time)
                        LabeledContent("类型", value: entry.kindLabel)
                        Text(entry.summary)
                        if !entry.detail.isEmpty { Text(entry.detail) }
                        if !entry.fieldLabel.isEmpty { LabeledContent("字段", value: entry.fieldLabel) }
                        if !entry.lostValue.isEmpty {
                            Section("未生效的值") {
                                Text(entry.lostValue).textSelection(.enabled)
                                if entry.canCopyLostValue {
                                    Button("复制丢失值", systemImage: "doc.on.doc") { store.copy(entry) }
                                }
                            }
                        }
                        if !entry.keptValue.isEmpty { Section("保留的值") { Text(entry.keptValue).textSelection(.enabled) } }
                        if !store.notice.isEmpty { Text(store.notice) }
                    }.navigationTitle(entry.title)
                } label: {
                    VStack(alignment: .leading) {
                        Text(entry.title)
                        Text(entry.time + " · " + entry.kindLabel).font(.caption).foregroundStyle(ThemeColors.inkMuted)
                        Text(entry.summary).font(.caption).foregroundStyle(ThemeColors.inkMuted).lineLimit(2)
                    }
                }
            }
        }.navigationTitle("同步日志")
        .toolbar { Button("刷新日志", systemImage: "arrow.clockwise") { store.reloadLogs() } }
        .task { store.reloadLogs() }
    }
}

@MainActor struct BackupSettings: View {
    @Environment(SettingsBackupStore.self) private var store
    @State private var document: TransferDocument?
    @State private var exportPresented = false
    @State private var importPresented = false
    var body: some View {
        SettingsForm {
            Section {
                Toggle("自动备份", isOn: Binding(get: { store.autoBackupEnabled }, set: store.setAutoBackupEnabled))
                LabeledContent("上次备份", value: store.snapshot.lastBackupTimeIso.isEmpty ? "尚未备份" : store.snapshot.lastBackupTimeIso)
                Button("创建备份", systemImage: "externaldrive") { store.createBackup() }
                    .disabled(store.working || store.snapshot.busy || store.exportURL != nil)
                Button("恢复备份", systemImage: "arrow.uturn.backward") { importPresented = true }
                    .disabled(store.working || store.snapshot.busy || store.exportURL != nil)
                if store.working || store.snapshot.busy { ProgressView(store.snapshot.operationText) }
            }
            Section("已有备份") {
                ForEach(store.backups) { entry in
                    Button { importURL(URL(fileURLWithPath: entry.path)) } label: {
                        VStack(alignment: .leading) {
                            Text(entry.name)
                            Text(entry.modified).font(.caption).foregroundStyle(ThemeColors.inkMuted)
                        }
                    }.disabled(store.working || store.snapshot.busy || store.exportURL != nil)
                }
                Button("刷新备份列表") { store.reloadBackups() }
            }
            if !store.notice.isEmpty { Text(store.notice) }
            if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(ThemeColors.danger) }
        }.formStyle(.grouped)
        .fileExporter(isPresented: $exportPresented, document: document, contentType: .data,
                      defaultFilename: store.exportURL?.lastPathComponent) { result in
            document = nil
            switch result { case .success: store.finishExport(error: nil); case .failure(let error): store.finishExport(error: error) }
        }
        .fileImporter(isPresented: $importPresented, allowedContentTypes: [.data]) { result in
            switch result { case .success(let url): importURL(url); case .failure(let error): store.importFailed(error) }
        }
        .onChange(of: store.exportURL, initial: true) { _, url in
            guard let url else { return }
            do { document = try TransferDocument(url: url); exportPresented = true }
            catch { store.finishExport(error: error) }
        }
        .alert("从备份恢复？", isPresented: Binding(get: { store.restoreInfo != nil }, set: { _ in })) {
            Button("取消", role: .cancel) { store.cancelRestore() }
            Button("恢复", role: .destructive) { store.confirmRestore() }
        } message: {
            if let info = store.restoreInfo {
                Text(["恢复将替换当前所有任务、专注记录和设置。程序会先自动备份当前数据。",
                      "备份时间：" + info.createdAt, "应用版本：" + info.appVersion,
                      "任务 \(info.taskCount) 条，专注记录 \(info.sessionCount) 条", store.confirmationWarning]
                    .filter { !$0.isEmpty }.joined(separator: "\n"))
            }
        }
        .task { store.refresh(); store.reloadBackups() }
    }
    private func importURL(_ url: URL) {
        // 安全作用域只覆盖同步复制，立即释放；服务异步读取自有副本，不持有外部授权。
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do { try store.importBackup(url) } catch { store.importFailed(error) }
    }
}

@MainActor struct ExportSettings: View {
    @Environment(SettingsExportStore.self) private var store
    @State private var document: TransferDocument?
    @State private var exportPresented = false
    var body: some View {
        @Bindable var store = store
        SettingsForm {
            Section("日期范围") {
                DatePicker("开始日期", selection: Binding(
                    get: { ContentDateFormat.date(store.startDate) ?? .now },
                    set: { store.startDate = ContentDateFormat.isoDate($0) }), displayedComponents: .date)
                DatePicker("结束日期", selection: Binding(
                    get: { ContentDateFormat.date(store.endDate) ?? .now },
                    set: { store.endDate = ContentDateFormat.isoDate($0) }), displayedComponents: .date)
                Button("本周") { store.selectRange("week") }
                Button("本月") { store.selectRange("month") }
            }.disabled(store.busy || store.exportURL != nil)
            Section {
                Button("导出任务", systemImage: "square.and.arrow.up") { store.start(.tasks) }
                Button("导出专注记录", systemImage: "square.and.arrow.up") { store.start(.focus) }
                Button("导出全部", systemImage: "square.and.arrow.up") { store.start(.all) }
            }.disabled(store.busy || store.exportURL != nil)
            if store.busy { ProgressView(value: Double(store.progress), total: Double(max(1, store.total))).accessibilityLabel("导出进度") }
            if !store.notice.isEmpty { Text(store.notice) }
            if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(ThemeColors.danger) }
        }.formStyle(.grouped)
        .fileExporter(isPresented: $exportPresented, document: document,
                      contentType: store.kind == .all ? .folder : .commaSeparatedText,
                      defaultFilename: store.exportURL?.lastPathComponent) { result in
            document = nil
            switch result { case .success: store.finishExport(error: nil); case .failure(let error): store.finishExport(error: error) }
        }
        .onChange(of: store.exportURL, initial: true) { _, url in
            guard let url else { return }
            do { document = try TransferDocument(url: url); exportPresented = true }
            catch { store.finishExport(error: error) }
        }
    }
}

// 先复制为 Sendable 值树（可跨线程的不可变数据）；系统每次请求都生成独立 FileWrapper，
// 避免把非线程安全的 Foundation 引用跨 SwiftUI 导出线程共享。
private struct TransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .commaSeparatedText, .folder] }
    let value: TransferValue
    init(url: URL) throws { value = try TransferValue(FileWrapper(url: url, options: .immediate)) }
    init(configuration: ReadConfiguration) throws { value = try TransferValue(configuration.file) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { value.wrapper() }
}
private indirect enum TransferValue: Sendable {
    case file(Data)
    case directory([String: TransferValue])
    init(_ wrapper: FileWrapper) throws {
        if wrapper.isRegularFile, let data = wrapper.regularFileContents { self = .file(data) }
        else if wrapper.isDirectory, let children = wrapper.fileWrappers {
            self = .directory(try children.mapValues { try TransferValue($0) })
        } else { throw CocoaError(.fileReadUnknown) }
    }
    func wrapper() -> FileWrapper {
        switch self {
        case .file(let data): return FileWrapper(regularFileWithContents: data)
        case .directory(let children): return FileWrapper(directoryWithFileWrappers: children.mapValues { $0.wrapper() })
        }
    }
}

// 「上次同步」按设备时钟写成「今天 19:42」「昨天 08:10」「10月8日 21:30」；原始时间串解析不了就原样显示。
// 只是展示口径，同步状态与时间本身都来自服务。
enum SyncTimeText {
    static func display(_ value: String) -> String {
        guard !value.isEmpty else { return "—" }
        guard let date = LogicalDateNavigation.timestampDate(value) else { return value }
        let calendar = Calendar(identifier: .gregorian)
        let clock = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDateInToday(date) { return "今天 " + clock }
        if calendar.isDateInYesterday(date) { return "昨天 " + clock }
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0)月\(parts.day ?? 0)日 " + clock
    }
}
