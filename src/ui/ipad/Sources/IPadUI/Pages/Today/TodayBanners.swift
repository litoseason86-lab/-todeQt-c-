import IPadCore
import SwiftUI

// 列表顶部的一组提示：结转、知识缺口、错误。没有内容时整组不占位。
struct TodayBanners: View {
    let store: TodayStore
    var body: some View {
        if store.rolloverBannerActive || store.gapBannerActive || !store.loadError.isEmpty || !store.gapConvertMessage.isEmpty {
            Section {
                if store.rolloverBannerActive {
                    banner(text: store.rolloverBannerText) {
                        Button("全部移到今天") { store.moveOverdueToToday() }
                            .buttonStyle(.borderedProminent).tint(ThemeColors.accentFill)
                        Button("忽略") { store.ignoreOverdueForToday() }.buttonStyle(.bordered)
                    }
                }
                if store.gapBannerActive {
                    banner(text: store.gapBannerText) {
                        Button("全部加到今天") { store.convertDueGaps() }
                            .buttonStyle(.borderedProminent).tint(ThemeColors.accentFill)
                        Button("去看看") { shellSelect() }.buttonStyle(.bordered)
                    }
                }
                if !store.gapConvertMessage.isEmpty {
                    Text(store.gapConvertMessage).foregroundStyle(ThemeColors.danger).font(.callout)
                }
                if !store.loadError.isEmpty {
                    HStack {
                        Text(store.loadError).foregroundStyle(ThemeColors.danger).font(.callout)
                        Spacer()
                        Button("重试") { store.refresh() }.buttonStyle(.bordered)
                    }
                }
            }
        }
    }
    @Environment(ShellStore.self) private var shell
    private func shellSelect() { shell.select(.knowledgeGap) }

    private func banner<Actions: View>(text: String, @ViewBuilder actions: () -> Actions) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(text).font(.callout.weight(.medium)).foregroundStyle(ThemeColors.inkStrong).frame(maxWidth: .infinity, alignment: .leading)
                actions()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.callout.weight(.medium)).foregroundStyle(ThemeColors.inkStrong)
                HStack(spacing: 12) { actions() }
            }
        }
        .listRowBackground(ThemeColors.glassAccent)
    }
}
