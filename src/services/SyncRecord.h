#ifndef SYNCRECORD_H
#define SYNCRECORD_H

#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QString>
#include <QVariant>

// 在设备之间传递的同步数据：一条记录、一批记录，以及它们和 JSON 之间的互转。
// 数据库怎么读写它们在 SyncStore；云盘里的文件怎么组织在阶段 3 的传输层。

// 版本：逻辑时间 + 设备标识，先比时间、再比设备，所有设备对「谁更新」得出同一结论。
// (0, "") 是最小版本：预置科目、例行生成的实例这类两台设备各自生成的默认值用它，输给任何一次真实修改。
struct SyncVersion {
    qint64 time = 0;
    QString device;

    bool isMinimal() const { return time == 0 && device.isEmpty(); }
};
bool operator<(const SyncVersion& a, const SyncVersion& b);
bool operator==(const SyncVersion& a, const SyncVersion& b);
inline bool operator!=(const SyncVersion& a, const SyncVersion& b) { return !(a == b); }

// 一个字段的值与版本。引用列（例如任务的科目）存的是对方表里那条记录的 sync_id，不是本机编号。
struct SyncFieldValue {
    QVariant value;
    SyncVersion version;
    // 改动前、对方可能已经见过的那一版。只用来判断冲突算不算「同时修改」，不参与决定谁赢。
    SyncVersion base;
};

struct SyncRecord {
    QString table;
    QString syncId;
    bool deleted = false;
    // 删除记录（deleted 为真时有效）：删除时的版本、类别（delete / reclaim / merge）与合并去向。
    SyncVersion deleteVersion;
    QString deleteKind;
    QString mergedInto;
    // 列名 → 值与版本。缺的列表示发送方没有这一列（更老的版本），应用时按本机默认值处理。
    QHash<QString, SyncFieldValue> fields;
    // 读出时这条记录在待发送队列里的 change_time；确认发送时据此判断期间有没有再改过。只在本机用，不写进文件。
    qint64 changeTime = 0;

    // 所有字段里最新的版本；删除记录返回删除时的版本。
    SyncVersion latestVersion() const;
};

// 同步的设置项（第一期只有 logic/dayStartHour）。值一律按文本传递。
struct SyncSettingRecord {
    QString key;
    QString value;
    SyncVersion version;
    SyncVersion base;
};

struct SyncBatch {
    // 写出这批改动的设备与当时的同步纪元。纪元不同的批次不能直接合并（见 SyncStore::applyRemote）。
    QString device;
    qint64 epoch = 0;
    QList<SyncRecord> records;
    QList<SyncSettingRecord> settings;

    bool isEmpty() const { return records.isEmpty() && settings.isEmpty(); }
};

// 云盘里的一个位置：某台设备在某个纪元里写出的第几批改动（从 1 开始数，0 表示一批都还没有）。
// 「已经应用到对方第几批」「本机写到第几批」「快照覆盖到第几批」都用它表示。
// 纪元换了（有设备恢复了备份），序号从头数，旧纪元的位置一律作废。
struct SyncPosition {
    qint64 epoch = 0;
    qint64 seq = 0;
};
inline bool operator==(const SyncPosition& a, const SyncPosition& b)
{
    return a.epoch == b.epoch && a.seq == b.seq;
}
inline bool operator!=(const SyncPosition& a, const SyncPosition& b) { return !(a == b); }

namespace SyncJson {
// 格式版本：以后改了字段含义就加一，读到更高版本的文件时拒绝，而不是按旧含义猜。
// 2（计划 051）：批次里多了课表、知识缺口、倒计时三张表和更多设置项。v18 的应用读到 2 会停下、提示更新，
// 而不是把不认识的表当成坏记录跳过——跳过之后读取进度已经往前走了，更新应用也补不回来。
// 3（计划 052）：加入备忘录。旧版 Applier 不认识 memos 会跳过记录、照常推进读取进度，
// 更新应用后也不会补读。提升格式让旧版停在文件前等更新，保住全部记录。
// 4（计划 054）：加入废纸篓 trash_items。理由同 3：旧版不认识这张表，会把记录当坏记录跳过、
// 照常推进读取进度，更新应用后也补不回来；提升格式让旧版停在这一批前等更新。
constexpr int kFormatVersion = 4;
// 格式 1–3 是当前格式的子集，仍然接受。
constexpr int kOldestReadableFormat = 1;

QJsonObject toJson(const SyncBatch& batch);
// 解析失败（格式不认识、必需字段缺失、类型不对）返回 false，并在 error 里说明原因。
bool fromJson(const QJsonObject& object, SyncBatch* batch, QString* error);

// 值的规范文本：比较两个值是否相同、以及版本相同时决定取哪一个，都用它。
// 带类型前缀，所以数字 1 和文本 "1" 不相同；空值也有自己的写法。
QString canonicalValue(const QVariant& value);
}

#endif // SYNCRECORD_H
