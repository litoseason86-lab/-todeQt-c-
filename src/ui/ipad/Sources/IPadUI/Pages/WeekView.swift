import IPadCore
import SwiftUI

@MainActor struct WeekView: View {
    @Bindable var store: WeekStore
    var body: some View {
        List {
            if !store.error.isEmpty { Text(store.error).foregroundStyle(ThemeColors.danger) }
            ForEach(store.groups) { group in
                Section { ForEach(group.tasks, id: \.id) { task in HStack { Image(systemName: task.completed ? "checkmark.circle.fill" : "circle"); Text(task.title); Spacer(); Text(task.estimatedMinutes > 0 ? "\(task.estimatedMinutes) 分钟" : "") }.padding(.vertical, 6) }; if store.canAdd(on: group.date) { Button("添加", systemImage: "plus") {} } } header: { HStack { Text(group.date); Spacer(); Text("已排 \(group.plannedMinutes) 分钟").foregroundStyle(ThemeColors.inkSoft) } }
            }
        }.navigationTitle("本周计划")
    }
}
