import CoreTransferable
import Foundation
import IPadCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct SyncSettings: View {
    @Environment(SettingsSyncStore.self) private var store
    @State private var joinConfirmation = false
    @State private var iCloudConfirmation = false
    var body: some View {
        SettingsForm {
            Section {
                Toggle("启用同步", isOn: Binding(get: { store.snapshot.enabled }, set: store.setEnabled))
                    .disabled(store.snapshot.busy || store.snapshot.switchingTransport)
                Picker("同步方式", selection: Binding(
                    get: { store.snapshot.transport },
                    set: { value in
                        if value == "server" {
                            store.selectTransport("server")
                        } else if value == "icloud" {
                            iCloudConfirmation = true
                        }
                    })) {
                    Text("自建服务器").tag("server")
                    Text("iCloud 云盘").tag("icloud")
                }
                .pickerStyle(.menu)
                .disabled(store.snapshot.switchingTransport)
                .alert("改用 iCloud 云盘？", isPresented: $iCloudConfirmation) {
                    Button("取消", role: .cancel) {}
                    Button("改用 iCloud 云盘", role: .destructive) {
                        store.selectTransport("icloud")
                    }
                } message: {
                    Text("改用后要在「文件」里重新选择 Mac 新建的「番茄Todo同步」文件夹，并确认加入。")
                }
                if store.isServerTransport {
                    LabeledContent("同步服务器", value: store.snapshot.serverHost.isEmpty ? "—" : store.snapshot.serverHost)
                    Button("输入配对码", systemImage: "key") { store.requestPairingSheet() }
                        .disabled(store.snapshot.switchingTransport)
                } else {
                    LabeledContent("同步文件夹", value: store.snapshot.folderDisplayPath.isEmpty ? "—" : store.snapshot.folderDisplayPath)
                    if !store.snapshot.folderProblem.isEmpty {
                        Text(store.snapshot.folderProblem).foregroundStyle(ThemeColors.danger)
                    }
                    Button(store.folderActionTitle, systemImage: "folder") {
                        if store.snapshot.statusKey == "folderMissing" { store.rebuildFolder() }
                        else { store.chooseFolder() }
                    }.disabled(store.snapshot.busy || store.snapshot.choosingFolder)
                }
                if !store.transportProblem.isEmpty {
                    Text(store.transportProblem).foregroundStyle(ThemeColors.danger)
                }
                if store.snapshot.switchingTransport {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在切换同步方式…")
                    }
                }
            } header: {
                Text("同步")
            } footer: {
                if store.isServerTransport {
                    Text("在 Mac 的「设置 › 数据 › 设备间同步」里复制配对码，回到这里粘贴。")
                }
            }
            Section("状态") {
                Text(store.snapshot.summaryText).foregroundStyle(store.snapshot.hasProblem ? ThemeColors.danger : ThemeColors.ink)
                if !store.snapshot.statusText.isEmpty {
                    Text(store.snapshot.statusText).foregroundStyle(store.snapshot.hasProblem ? ThemeColors.danger : ThemeColors.ink)
                }
                if !store.snapshot.statusDetail.isEmpty && store.snapshot.hasProblem {
                    Text(store.snapshot.statusDetail).foregroundStyle(ThemeColors.danger)
                }
                LabeledContent("上次同步", value: SyncTimeText.display(store.snapshot.lastSyncedAt))
                LabeledContent("待同步", value: store.pendingText)
                Button("立即同步", systemImage: "arrow.triangle.2.circlepath") { store.syncNow() }
                    .disabled(!store.snapshot.enabled || store.snapshot.busy || !store.snapshot.hasFolder)
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
        .sheet(isPresented: Binding(
            get: { store.pairingSheetRequested },
            set: { if !$0 { store.cancelPairingSheet() } })) {
            PairingCodeSheet()
        }
        .alert(store.joinTitle, isPresented: $joinConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认加入", role: .destructive) { store.confirmJoin() }
        } message: { Text(store.joinConfirmationText) }
        .onAppear { store.clearNotice(); store.setActive(true) }
        .onDisappear { store.setActive(false) }
    }
}

@MainActor private struct PairingCodeSheet: View {
    @Environment(SettingsSyncStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        NavigationStack {
            SettingsForm {
                Section {
                    TextField("配对码", text: $code, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(4...8)
                    Button("从剪贴板粘贴", systemImage: "doc.on.clipboard") {
                        // UIPasteboard 只在 IPadUI 读取；IPadCore 的测试包不依赖 UIKit。
                        if let value = UIPasteboard.general.string { code = value }
                    }
                } footer: {
                    Text("在 Mac 的「设置 › 数据 › 设备间同步」里复制配对码，回到这里粘贴。")
                }
                if !store.transportProblem.isEmpty {
                    Section {
                        Text(store.transportProblem).foregroundStyle(ThemeColors.danger)
                    }
                } else if !store.errorMessage.isEmpty {
                    Section {
                        Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                    }
                }
                if store.snapshot.switchingTransport {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在连接同步服务器…")
                        }
                    }
                }
            }
            .navigationTitle("输入配对码").sheetChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        store.cancelPairingSheet()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入") { store.submitPairingCode(code) }
                        .disabled(!store.canSubmitPairingCode(code))
                }
            }
        }
    }
}

@MainActor private struct SyncLogSettings: View {
    @Environment(SettingsSyncStore.self) private var store
    @Environment(ShellStore.self) private var shell
    var body: some View {
        List {
            Group {
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
                        }.modifier(PageBackground()).navigationTitle(entry.title)
                            .onAppear { store.clearNotice() }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(entry.title)
                            Text(entry.time + " · " + entry.kindLabel).font(.caption).foregroundStyle(ThemeColors.inkMuted)
                            Text(entry.summary).font(.caption).foregroundStyle(ThemeColors.inkMuted).lineLimit(2)
                        }
                    }
                }
            }
            .listRowBackground(shell.selectedTheme != nil ? ThemeColors.surface : nil)
        }.modifier(PageBackground()).navigationTitle("同步日志")
        .toolbar { Button("刷新日志", systemImage: "arrow.clockwise") { store.reloadLogs() } }
        .onAppear { store.setLogsActive(true) }
        .onDisappear { store.setLogsActive(false) }
    }
}

@MainActor struct BackupSettings: View {
    @Environment(SettingsBackupStore.self) private var store
    @State private var exportItem: TransferFile?
    @State private var exportPresented = false
    @State private var importPresented = false
    var body: some View {
        SettingsForm {
            Section {
                Toggle("自动备份", isOn: Binding(get: { store.autoBackupEnabled }, set: store.setAutoBackupEnabled))
                LabeledContent("上次备份", value: store.snapshot.lastBackupTimeIso.isEmpty ? "尚未备份" : BackupTimeText.display(store.snapshot.lastBackupTimeIso))
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
                            Text(BackupTimeText.display(entry.modified)).font(.caption).foregroundStyle(ThemeColors.inkMuted)
                        }
                    }.disabled(store.working || store.snapshot.busy || store.exportURL != nil)
                }
                Button("刷新备份列表") { store.reloadBackups() }
            }
            if !store.notice.isEmpty { Text(store.notice) }
            if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(ThemeColors.danger) }
        }.formStyle(.grouped)
        // 用户在系统文件面板点取消时不触发 onCompletion；必须接入 onCancellation 清理临时目录并解除按钮禁用。
        .fileExporter(isPresented: $exportPresented, item: exportItem, contentTypes: [.data],
                      defaultFilename: store.exportURL?.lastPathComponent,
                      onCompletion: { result in
            exportItem = nil
            switch result { case .success: store.finishExport(error: nil); case .failure(let error): store.finishExport(error: error) }
        }, onCancellation: {
            exportItem = nil
            store.finishExport(error: CocoaError(.userCancelled))
        })
        .fileImporter(isPresented: $importPresented, allowedContentTypes: [.data]) { result in
            switch result { case .success(let url): importURL(url); case .failure(let error): store.importFailed(error) }
        }
        .onChange(of: store.exportURL, initial: true) { _, url in
            guard let url else { exportItem = nil; exportPresented = false; return }
            exportItem = TransferFile(url: url, contentType: .data)
            exportPresented = true
        }
        .alert("从备份恢复？", isPresented: Binding(get: { store.restoreInfo != nil }, set: { if !$0 { store.cancelRestore() } })) {
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
        // 最大 512 MiB 的备份文件在后台任务内开启安全作用域并复制，避免阻塞主线程。
        Task { await store.importBackupAsync(url) }
    }
}

@MainActor struct ExportSettings: View {
    @Environment(SettingsExportStore.self) private var store
    @State private var exportItem: TransferFile?
    @State private var exportPresented = false
    var body: some View {
        @Bindable var store = store
        SettingsForm {
            Section("日期范围") {
                // 起止日期缺失或非法时退回 C++ 的逻辑今天，凌晨日界前不显示成第二天（062 A040）。
                DatePicker("开始日期", selection: Binding(
                    get: { ContentDateFormat.date(store.startDate) ?? LogicalDateNavigation.dateOrLogicalToday(store.startDate) },
                    set: { store.startDate = ContentDateFormat.isoDate($0) }), displayedComponents: .date)
                DatePicker("结束日期", selection: Binding(
                    get: { ContentDateFormat.date(store.endDate) ?? LogicalDateNavigation.dateOrLogicalToday(store.endDate) },
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
        .fileExporter(isPresented: $exportPresented, item: exportItem,
                      contentTypes: [store.kind == .all ? .folder : .commaSeparatedText],
                      defaultFilename: store.exportURL?.lastPathComponent,
                      onCompletion: { result in
            exportItem = nil
            switch result { case .success: store.finishExport(error: nil); case .failure(let error): store.finishExport(error: error) }
        }, onCancellation: {
            exportItem = nil
            store.finishExport(error: CocoaError(.userCancelled))
        })
        .onChange(of: store.exportURL, initial: true) { _, url in
            guard let url else { exportItem = nil; exportPresented = false; return }
            exportItem = TransferFile(url: url, contentType: store.kind == .all ? .folder : .commaSeparatedText)
            exportPresented = true
        }
    }
}

// 仅把沙盒临时文件或目录的 URL 交给系统导出器流式复制，不将最高 512 MiB 的备份或整批 CSV 预读进内存。
private struct TransferFile: Transferable {
    let url: URL
    let contentType: UTType
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { SentTransferredFile($0.url) }
            .exportingCondition { $0.contentType == .data }
        FileRepresentation(exportedContentType: .commaSeparatedText) { SentTransferredFile($0.url) }
            .exportingCondition { $0.contentType == .commaSeparatedText }
        FileRepresentation(exportedContentType: .folder) { SentTransferredFile($0.url) }
            .exportingCondition { $0.contentType == .folder }
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
