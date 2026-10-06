#ifndef SYNCSCHEMA_H
#define SYNCSCHEMA_H

#include <QHash>
#include <QList>
#include <QPair>
#include <QString>
#include <QStringList>

// 设备间同步（050 阶段 2）的数据库结构：哪些表、哪些列参与同步，同步用的附属表，
// 以及在本机增删改时记下「字段版本」和「待发送」的触发器。
//
// 建库迁移（DatabaseManager）、恢复备份前的安全检查（BackupOperations）和同步核心（SyncStore）
// 共用这一份定义。三处各写一份的话，改了一处漏了另一处，结果不是备份被误拒，就是触发器漏记某一列。
//
// 几个贯穿全文的名词：
// - sync_id：一条记录在所有设备上都相同的身份。本机自增的 id 在两台设备上会撞号，不能拿来对应。
// - 版本：「逻辑时间 + 设备标识」，按字典序比较。逻辑时间来自混合逻辑时钟：取「此刻」和「见过的最大值 + 1」
//   中较大的一个，所以看过对方的修改之后再改，新版本一定排在对方后面，哪怕本机时钟比对方慢。
// - 待发送队列（sync_outbox）：本机改过、还没写进同步文件的记录。
// - 删除记录（sync_tombstones）：删掉的记录留下身份和删除时的版本，「删除优先」据此判定。
namespace SyncSchema {

// 一列参与同步的数据。
struct Field {
    // 列名。它同时就是同步记录里的字段名、也是 sync_field_versions.field 里存的名字。
    QString column;
    // 冲突日志里给人看的名字。
    QString label;
    // 非空表示这一列存的是另一张表的本机编号：写进同步记录时换成那条记录的 sync_id，
    // 应用远端改动时再换回本机编号。
    QString refTable;
};

struct Table {
    QString name;
    // 给人看的名字（任务、科目……），冲突日志用。
    QString label;
    QList<Field> fields;
    // 行满足什么条件才发布，SQL 布尔表达式，%1 代表行（NEW、OLD 或表别名）。为空表示总是发布。
    // 专注记录只发布已经结束的：进行中的那一行只属于本机的计时器，见 SyncSchema.cpp 的说明。
    QString publishCondition;
    // 只属于本机、不同步却不许为空的列（各表的 updated_at）：对方新建的行插进本机时，用本机此刻的时间补上。
    QStringList stampOnInsert = {};
    // 派生的内容更新时间不参与同步；本机触发器与远端应用都从这些内容字段的版本时间计算。
    // 空列名表示不用这条规则。排序列不列在下面的驱动字段清单内，拖动不会伪装成内容更新。
    struct VersionStamp {
        QString column;
        QStringList fields;
    };
    VersionStamp versionStamp = {};
};

// 参与同步的表，按依赖顺序排列：被引用的在前（科目 → 例行 → 任务 → 专注 → 休息 → 课表、知识缺口、倒计时、备忘录、废纸篓）。
// 应用远端改动时也按这个顺序，先有科目，任务才能指向它；废纸篓排在最后，被删的原记录先处理。
const QList<Table>& tables();
// 按表名查规格；不是同步表时返回 nullptr。
const Table* table(const QString& name);
// 某一列的规格；不存在时返回 nullptr。
const Field* field(const QString& tableName, const QString& column);
// 把行条件里的 %1 换成具体的行名（NEW、OLD 或别名）；条件为空时返回 "1"。
QString publishConditionFor(const Table& table, const QString& row);

// 表的同步列名写成 SQL 的 (VALUES ('a'), ('b')) 子查询，列名是 column1。回填和触发器用它逐列展开。
QString fieldValuesSql(const Table& table);

// 同步附属表的表名，判断结构是否完整时用。
QStringList infrastructureTableNames();
// 同步附属表的建表语句（可重复执行）。
QStringList tableStatements();
// 五张业务表 sync_id 唯一索引的建立语句（可重复执行）。
QStringList indexStatements();
// 附属表里必须存在的初始行（运行标记与设备标识等），可重复执行，已存在的不改。
QStringList seedStatements();
// 维护字段版本、删除记录与待发送队列的触发器：（触发器名, CREATE TRIGGER 语句）。
// 语句不带 IF NOT EXISTS：启动时按规范文本比较，不一致就删掉重建，这样以后改了触发器也能升级上去。
QList<QPair<QString, QString>> triggers();
// 触发器名 → SQLite 存进 sqlite_master 的文本。SQLite 保存触发器时会改写语句开头，
// 所以比较前必须让双方经过同一道处理：在临时内存库里真的建一遍，再读回来。
QHash<QString, QString> canonicalTriggerSql();
// 是不是本应用命名的同步触发器（「表名_sync_」开头）。启动时据此清掉旧版本留下、现已不用的同步触发器，
// 不碰别人建的触发器。
bool isSyncTriggerName(const QString& name);

// SQL 片段。
// 此刻的 UTC 毫秒数。测试可以往 sync_runtime.test_now_ms 写一个值来固定时钟，正式运行时这一列恒为 NULL。
QString sqlNowMs();
// 推进混合逻辑时钟的一条完整语句（带分号）。
QString sqlAdvanceClock();
// 当前逻辑时间与本设备标识（表达式）。
QString sqlCurrentClock();
QString sqlDeviceId();
// 版本毫秒时间转换为与 MemoService 相同的 UTC、带毫秒文本。
QString sqlVersionTimestamp(const QString& milliseconds);
// 「现在不是在应用远端改动」（表达式）。应用远端改动时同一事务里置位，触发器全部跳过，
// 收到的改动不会被当成本机修改再发回去。
QString sqlNotApplyingRemote();

// ── 跟着同步的设置（计划 050 的逻辑日起点，加上 051 的 D1 选定的内容类设置）──
// 值在同步里一律是文本。这里只管「哪些键、叫什么、怎么显示」；读出、写回本机的值在 SyncedSettings。
// 「这台设备怎么显示、怎么提醒」的设置（外观、提示音、窗口、自动开始、快捷键、课表显示方式……）不在其中。
// 固定的几项（不含按日期的今日目标）。课表节次的键 schedule/periods 不在 QSettings 里：整张节次表序列化成一项。
QStringList syncedSettingKeys();
// 今日目标按日期各算一项：focus/dailyGoalHistory/yyyy-MM-dd，与 AppSettings 存它的键相同。
QString dailyGoalSettingKey(const QString& isoDate);
// 是今日目标的键时返回日期，否则返回空。
QString dailyGoalDateOf(const QString& key);
bool isSyncedSettingKey(const QString& key);
// 同步日志里给人看的名字与取值。
QString settingLabel(const QString& key);
QString settingDisplay(const QString& key, const QString& value);

// 预置科目的固定身份：按预置位置（display_order 1..5）。两台设备各自建库时预置的是同一组科目，
// 用位置当身份才不会同步成两份「数学」。
QString presetCategorySyncId(int slot);
// 例行生成的实例的身份：例行的 sync_id + 日期。两台设备各自生成的同一天实例是同一条记录。
QString routineInstanceSyncId(const QString& routineSyncId, const QString& isoDate);
// 同一规则的 SQL 版本（参数是两个 SQL 表达式）。
QString routineInstanceSyncIdSql(const QString& routineSyncIdExpr, const QString& dateExpr);

} // namespace SyncSchema

#endif // SYNCSCHEMA_H
