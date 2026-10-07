#ifndef SYNCNOTIFIER_H
#define SYNCNOTIFIER_H

#include "SyncStore.h"

// 同步改动提交之后，按这一批真的动过的表，发出与本机修改时相同的信号，界面与计时器据此刷新。
// 只刷新变了的：不整库重新初始化——那会让所有列表整体重载、丢掉滚动位置（sol6 审查第 7 条）。
namespace SyncNotifier {

// 只在 result.ok（事务已经提交）时发信号。提交失败时数据库回到原样，这时发信号会让计时器
// 解绑一个其实还在的任务、让界面刷新出并不存在的变化，所以一个都不发。
void publish(const SyncStore::ApplyResult& result);

// 「按表发信号」这一段，同步（publish）与废纸篓恢复共用：恢复直接写库，没有 ApplyResult，
// 但各页面要的刷新和同步改动之后完全一样，不另写一套。changedTables 用库里的表名；
// tasksDeleted 为真时任务列表也刷新（同步删了任务但 tasks 不在 changedTables 时用）。
void publishTableChanges(const QSet<QString>& changedTables, bool tasksDeleted = false);

} // namespace SyncNotifier

#endif // SYNCNOTIFIER_H
