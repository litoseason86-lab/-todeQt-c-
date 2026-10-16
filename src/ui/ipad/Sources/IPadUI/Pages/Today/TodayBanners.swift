import IPadCore
import SwiftUI

// 列表顶部的一组提示：结转、知识缺口、错误。没有内容时整组不占位。
struct TodayBanners: View {
    let store: TodayStore
    var body: some View {
        // 每条提示是一张浅焦糖卡片，卡片之间与任务卡之间各留 12。
        if store.rolloverBannerActive {
            banner(text: store.rolloverBannerText) {
                Button("全部移到今天") { store.moveOverdueToToday() }.buttonStyle(ProminentPillStyle())
                Button("忽略") { store.ignoreOverdueForToday() }.buttonStyle(AccentTextButtonStyle(size: 15))
            }
        }
        if store.gapBannerActive {
            banner(text: store.gapBannerText) {
                Button("全部加到今天") { store.convertDueGaps() }.buttonStyle(ProminentPillStyle())
                Button("去看看") { shellSelect() }.buttonStyle(AccentTextButtonStyle(size: 15))
            }
        }
        if !store.gapConvertMessage.isEmpty {
            Text(store.gapConvertMessage).foregroundStyle(ThemeColors.danger).font(.callout)
                .plainRow(insets: EdgeInsets(top: 0, leading: 4, bottom: 12, trailing: 4))
        }
        if !store.loadError.isEmpty {
            HStack {
                Text(store.loadError).foregroundStyle(ThemeColors.danger).font(.callout)
                Spacer()
                Button("重试") { store.refresh() }.buttonStyle(SoftPillStyle())
            }
            .plainRow(insets: EdgeInsets(top: 0, leading: 4, bottom: 12, trailing: 4))
        }
    }
    @Environment(ShellStore.self) private var shell
    private func shellSelect() { shell.select(.knowledgeGap) }

    @ViewBuilder private func banner<Actions: View>(text: String, @ViewBuilder actions: () -> Actions) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(text).scaledSystemFont(size: 15, weight: .medium).foregroundStyle(ThemeColors.inkStrong)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(text).scaledSystemFont(size: 15, weight: .medium).foregroundStyle(ThemeColors.inkStrong)
                HStack(spacing: 12) { actions() }
            }
        }
        .cardRow(.single, fill: ThemeColors.accentFill, insets: EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 12))
        Color.clear.frame(height: 12).plainRow()
    }
}
