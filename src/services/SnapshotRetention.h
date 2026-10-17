#ifndef SNAPSHOTRETENTION_H
#define SNAPSHOTRETENTION_H

#include <QDebug>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QString>
#include <QStringList>
#include <QTimeZone>

#include <algorithm>
#include <optional>

// 快照保留策略：迁移快照、恢复前快照、自动备份共用。只有头文件，免得每个编译
// DatabaseManager / BackupService 的测试目标都要改源文件清单。
namespace SnapshotRetention {

inline std::optional<qint64> timestampUtcMillis(const QString& fileName)
{
    static const QRegularExpression backupPattern(QStringLiteral(
        "^(?:auto-|before-restore-|before-sync-)([0-9]{8})-([0-9]{6})-([0-9]{3})(Z?)\\.tomatobackup$"));
    static const QRegularExpression migrationPattern(QStringLiteral(
        "^pomodoro_backup_([0-9]{8})_([0-9]{6})_([0-9]{3})(Z?)(?:_[0-9]+)?\\.db$"));
    const auto match = (fileName.startsWith(QStringLiteral("pomodoro_backup_"))
        ? migrationPattern : backupPattern).match(fileName);
    if (!match.hasMatch()) {
        return std::nullopt;
    }

    // 旧名字没有时区信息，只能按本机本地时间兼容；Z 明确表示 UTC（协调世界时）。
    // 分开解析日期与时间后直接指定时区，避免 UTC 时间先被本地夏令时跳变调整。
    const QDate date = QDate::fromString(match.captured(1), QStringLiteral("yyyyMMdd"));
    const QTime time = QTime::fromString(match.captured(2) + u'.' + match.captured(3),
                                       QStringLiteral("HHmmss.zzz"));
    const QDateTime timestamp(date, time,
        match.captured(4).isEmpty() ? QTimeZone::LocalTime : QTimeZone::UTC);
    if (!timestamp.isValid()) {
        return std::nullopt;
    }
    return timestamp.toMSecsSinceEpoch();
}

// 在 dir 里按 nameFilter 找快照，最多留 retention 份，其余删除。
//
// 刚建好的那份（keepPath）无条件保留，并占掉一个名额。不能单靠时间排序决定去留：
// 以前系统时钟偏快时留下的快照，文件名和修改时间都在「未来」，按时间倒序时
// 刚写好的快照反而排到最后、当场被删——那份恰恰是这次操作失败时唯一的退路。
//
// 其余快照按名字里的时间戳换算成 UTC 毫秒后倒序；无法解析的视为最旧，优先删除，
// 同一时间点按文件名倒序稳定决胜。修改时间会被拷贝、同步盘之类的操作改掉，不如文件名可靠。
inline void prune(const QDir& dir, const QString& nameFilter, int retention, const QString& keepPath)
{
    const QString keptAbsolute = keepPath.isEmpty()
        ? QString() : QFileInfo(keepPath).absoluteFilePath();
    struct Snapshot {
        QString path;
        std::optional<qint64> utcMillis;
    };
    QList<Snapshot> others;
    for (const QFileInfo& info : dir.entryInfoList(QStringList{nameFilter}, QDir::Files)) {
        if (info.absoluteFilePath() != keptAbsolute) {
            others.append({info.absoluteFilePath(), timestampUtcMillis(info.fileName())});
        }
    }
    std::sort(others.begin(), others.end(), [](const Snapshot& left, const Snapshot& right) {
        if (left.utcMillis != right.utcMillis) {
            // 空值排在所有有效时间之后，包括早于 Unix 纪元的快照。
            return left.utcMillis > right.utcMillis;
        }
        return left.path > right.path;
    });

    const bool keptExists = !keptAbsolute.isEmpty() && QFileInfo::exists(keptAbsolute);
    const int othersToKeep = std::max(0, retention - (keptExists ? 1 : 0));
    for (int index = othersToKeep; index < others.size(); ++index) {
        if (!QFile::remove(others.at(index).path)) {
            qWarning() << "删除过期快照失败:" << others.at(index).path;
        }
    }
}

} // namespace SnapshotRetention

#endif // SNAPSHOTRETENTION_H
