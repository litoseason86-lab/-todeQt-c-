#ifndef SNAPSHOTRETENTION_H
#define SNAPSHOTRETENTION_H

#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QString>
#include <QStringList>

#include <algorithm>

// 快照保留策略：迁移快照、恢复前快照、自动备份共用。只有头文件，免得每个编译
// DatabaseManager / BackupService 的测试目标都要改源文件清单。
namespace SnapshotRetention {

// 在 dir 里按 nameFilter 找快照，最多留 retention 份，其余删除。
//
// 刚建好的那份（keepPath）无条件保留，并占掉一个名额。不能单靠时间排序决定去留：
// 以前系统时钟偏快时留下的快照，文件名和修改时间都在「未来」，按时间倒序时
// 刚写好的快照反而排到最后、当场被删——那份恰恰是这次操作失败时唯一的退路。
//
// 其余快照按文件名倒序：名字里带创建时的时间戳（yyyyMMdd-HHmmss-zzz 这种定长格式），
// 字典序就是时间序；修改时间会被拷贝、同步盘之类的操作改掉，不如文件名可靠。
inline void prune(const QDir& dir, const QString& nameFilter, int retention, const QString& keepPath)
{
    const QString keptAbsolute = keepPath.isEmpty()
        ? QString() : QFileInfo(keepPath).absoluteFilePath();
    QStringList others;
    for (const QFileInfo& info : dir.entryInfoList(QStringList{nameFilter}, QDir::Files)) {
        if (info.absoluteFilePath() != keptAbsolute) {
            others.append(info.absoluteFilePath());
        }
    }
    std::sort(others.begin(), others.end(), std::greater<QString>());

    const bool keptExists = !keptAbsolute.isEmpty() && QFileInfo::exists(keptAbsolute);
    const int othersToKeep = std::max(0, retention - (keptExists ? 1 : 0));
    for (int index = othersToKeep; index < others.size(); ++index) {
        if (!QFile::remove(others.at(index))) {
            qWarning() << "删除过期快照失败:" << others.at(index);
        }
    }
}

} // namespace SnapshotRetention

#endif // SNAPSHOTRETENTION_H
