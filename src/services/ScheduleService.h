#ifndef SCHEDULESERVICE_H
#define SCHEDULESERVICE_H

#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

class QSqlQuery;

// 课表服务：管理「按星期几循环」的时间表条目与节次预设。
//
// 与 TaskManager 的根本差别在时间锚点：任务锚定具体日期（2026-09-02），
// 课表项锚定「星期几 + 时段」（周一 08:00–09:40）并按周次循环。
// 因此课表项没有完成状态，也不写 tasks / focus_sessions，不参与任何统计与目标进度。
//
// 分层约定：本服务只负责存储与「给定周次筛选」，**不关心今天是第几周**。
// 日期到周次的换算在 QML 侧的 ScheduleWeeks.js 完成，服务层因此不依赖 AppSettings。
class ScheduleService : public QObject
{
    Q_OBJECT
    // 输入框 maximumLength 与服务端校验共用同一上限；QML 侧读取这些常量属性。
    Q_PROPERTY(int maxTitleLength READ maxTitleLength CONSTANT)
    Q_PROPERTY(int maxLocationLength READ maxLocationLength CONSTANT)
    Q_PROPERTY(int maxWeekIndex READ maxWeekIndex CONSTANT)
    Q_PROPERTY(int maxPeriodCount READ maxPeriodCount CONSTANT)

public:
    // 单双周规则。存库为整数，QML 侧按同一套取值传入。
    enum WeekParity {
        EveryWeek = 0,
        OddWeeks = 1,
        EvenWeeks = 2
    };
    Q_ENUM(WeekParity)

    // 课程名上限比任务标题短：课表格子宽度固定，超过这个长度在网格里必然被截断，
    // 与其存进去再显示成省略号，不如在录入时就挡住。
    static constexpr int kMaxTitleLength = 60;
    static constexpr int kMaxLocationLength = 60;
    // 周次上限。一个学期通常 16–20 周，取 60 给长学制和跨学期连排留足余量，
    // 同时避免用户误输入 9999 导致周次导航条无限长。
    static constexpr int kMaxWeekIndex = 60;
    // 一天的分钟总数。课表项的起止时间都以「当天第几分钟」存储。
    static constexpr int kMinutesPerDay = 24 * 60;
    // 节次数量上限。网格按「节次数 × 行高」算内容高度，没有上限时
    // 一次粘贴几百行就会撑出一张几万像素高、滚不到底的空网格。
    static constexpr int kMaxPeriodCount = 24;

    static ScheduleService* instance();

    int maxTitleLength() const { return kMaxTitleLength; }
    int maxLocationLength() const { return kMaxLocationLength; }
    int maxWeekIndex() const { return kMaxWeekIndex; }
    int maxPeriodCount() const { return kMaxPeriodCount; }

    // —— 课表项增删改查 ——
    // weekday 取 1..7（1 = 周一）；startMinutes/endMinutes 是当天第几分钟，要求 start < end。
    // categoryId <= 0 表示不设科目。weekParity 取 WeekParity 的三个值之一。
    Q_INVOKABLE bool addEntry(const QString& title, int weekday, int startMinutes, int endMinutes,
                              const QString& location, int categoryId,
                              int weekStart, int weekEnd, int weekParity);
    Q_INVOKABLE bool updateEntry(int id, const QString& title, int weekday,
                                 int startMinutes, int endMinutes,
                                 const QString& location, int categoryId,
                                 int weekStart, int weekEnd, int weekParity);
    Q_INVOKABLE bool deleteEntry(int id);

    // 全部课表项（不按周次筛选），按星期几和开始时间排序。
    // 注意：目前界面上没有任何调用方——原注释写的「课表设置页与导出用」
    // 是两个并不存在的去处，会让人白找。它现在只被测试当作读取全表的断言助手，
    // 保留是因为「导出课表」是这一页最自然的下一步。
    Q_INVOKABLE QVariantList getEntries() const;
    // 第 weekIndex 周实际生效的课表项。筛选判据是三段合取：
    // 周次落在 [week_start, week_end] 内、单双周奇偶命中、以及该项本身的 weekday。
    Q_INVOKABLE QVariantList getEntriesForWeek(int weekIndex) const;

    // 与给定时段冲突的课表项。冲突只用于**提示**，不做拦截：
    // 同一时段并列两门可选课是真实存在的排法，强行拒绝会让用户录不进去。
    // excludeId 传入正在编辑的条目 id，避免它和自己冲突；新增时传 -1。
    Q_INVOKABLE QVariantList findConflicts(int weekday, int startMinutes, int endMinutes,
                                           int weekStart, int weekEnd, int weekParity,
                                           int excludeId) const;

    // —— 节次预设 ——
    // 节次既是录入时的快捷填充来源，也是「按节次」显示模式的行定义。
    Q_INVOKABLE QVariantList getPeriods() const;
    // 整表替换节次。传入元素形如 { startMinutes, endMinutes }，
    // 服务按开始时间排序后重新编号为 1..N——「第 3 节」必须永远晚于「第 2 节」，
    // 让调用方自己维护编号迟早会排出乱序的节次表。
    Q_INVOKABLE bool setPeriods(const QVariantList& periods);

signals:
    void scheduleChanged();
    void periodsChanged();
    void operationFailed(const QString& message);

private:
    explicit ScheduleService(QObject* parent = nullptr);

    void reportFailure(const QString& message) const;
    // 写入前的统一校验。normalizedTitle/normalizedLocation 回传去除首尾空白后的值，
    // 避免调用方拿未规范化的原串再拼一次 SQL。
    bool validateEntryInput(const QString& title, int weekday, int startMinutes, int endMinutes,
                            const QString& location, int weekStart, int weekEnd, int weekParity,
                            QString* normalizedTitle, QString* normalizedLocation) const;
    QVariantMap entryFromQuery(const QSqlQuery& query) const;
    // 课表项查询共用的 SELECT 前缀，带科目左连接。
    static QString entrySelectSql();
};

#endif // SCHEDULESERVICE_H
