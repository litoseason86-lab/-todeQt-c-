#ifndef STATISTICSPERIOD_H
#define STATISTICSPERIOD_H

#include <QDate>
#include <QString>

// 统计页的周期翻页（日 / 周 / 月）。纯计算、不读时钟：调用方传同一份逻辑今日，
// 一次刷新里的周期范围、是否当前期、能否往后翻和比较距离都出自这一份，跨日界时不会前后不一。
// Mac 的同一套规则写在 StatisticsView.qml（canGoForward、翻页函数、比较标签），周一归位与
// StatisticsFormat.js 的 mondayOf / endOfWeek 共用 tests/fixtures/calibers/statistics-format.json。
namespace StatisticsPeriod {

enum class Range { Day, Week, Month };

struct Period {
    QDate start;
    QDate end;
    // 比较对象（所选周期的前一期）离当前期隔几个周期：1 显示「昨天 / 上周 / 上月」，2 为「上上周」等。
    int comparisonDistance = 0;
    bool current = false;
    // 所选周期早于当前期，还能往后翻；当前期与未来期都不能。
    bool canAdvance = false;
    bool isValid() const { return start.isValid() && end.isValid(); }
};

// 只认 "day" / "week" / "month"，其它文本返回 false，不猜测成某个默认范围。
bool parseRange(const QString& text, Range* range);

// anchor 所在周期平移 shift 个周期。周从周一开始，月从 1 号开始；anchor、logicalToday 无效
// 或平移后越出 QDate 的范围时返回无效 Period。
Period forAnchor(const QDate& anchor, Range range, int shift, const QDate& logicalToday);

} // namespace StatisticsPeriod

#endif // STATISTICSPERIOD_H
