#include "SyncNotifier.h"

#include "AppSettings.h"
#include "CategoryManager.h"
#include "CountdownService.h"
#include "FocusHistoryService.h"
#include "KnowledgeGapService.h"
#include "RoutineManager.h"
#include "ScheduleService.h"
#include "TaskManager.h"

namespace SyncNotifier {

void publish(const SyncStore::ApplyResult& result)
{
    if (!result.ok) {
        return;
    }
    const QSet<QString>& changed = result.changedTables;

    // 顺序与 TaskManager::deleteTask 一致：先逐条发删除事实，让计时器这类持有任务编号的服务先解绑，
    // 再发列表刷新。反过来的话，订阅 tasksChanged 的页面会先看到「任务已删、计时器还绑着旧编号」的中间状态。
    for (const int taskId : result.deletedTaskIds) {
        emit TaskManager::instance()->taskDeleted(taskId);
    }

    // 设置先写回：逻辑日起点变了，「今天」是哪天随之改变，后面刷新的列表要按新的日期取数。
    // 写回会发 dayStartHourChanged，LogicalDayService 据此让「今天」失效并补生成新一天的例行。
    const auto dayStart = result.changedSettings.constFind(QStringLiteral("logic/dayStartHour"));
    if (dayStart != result.changedSettings.constEnd()) {
        bool valid = false;
        const int hour = dayStart.value().toInt(&valid);
        if (valid) {
            AppSettings::instance()->setDayStartHour(hour);
        }
    }

    // 科目变了会连带例行列表（RoutineManager 把 categoriesChanged 转成 routinesChanged），不必再单独发一次。
    if (changed.contains(QStringLiteral("categories"))) {
        emit CategoryManager::instance()->categoriesChanged();
    } else if (changed.contains(QStringLiteral("routines"))) {
        emit RoutineManager::instance()->routinesChanged();
    }
    if (changed.contains(QStringLiteral("focus_sessions")) || changed.contains(QStringLiteral("rest_sessions"))) {
        emit FocusHistoryService::instance()->historyChanged();
    }
    // 专注记录变了，任务上的累计时长也跟着变，所以任务列表同样要刷新。应用里装配层已经把 historyChanged
    // 接到了 tasksChanged 上，这里仍然直接发一次：不依赖那条接线还在，多刷新一次的代价很小。
    if (changed.contains(QStringLiteral("tasks")) || changed.contains(QStringLiteral("focus_sessions"))
        || !result.deletedTaskIds.isEmpty()) {
        emit TaskManager::instance()->tasksChanged();
    }
    // 第二期（计划 051）的三张表，各自发自己的刷新信号。倒计时服务把目标缓存在列表模型里，要重新读一遍库，
    // 它读完会发 goalsReloaded；另外两个服务的页面收到信号后自己重查。
    if (changed.contains(QStringLiteral("schedule_entries"))) {
        emit ScheduleService::instance()->scheduleChanged();
    }
    if (changed.contains(QStringLiteral("knowledge_gaps"))) {
        emit KnowledgeGapService::instance()->gapsChanged();
    }
    if (changed.contains(QStringLiteral("countdown_goals"))) {
        CountdownService::instance()->reload();
    }
}

} // namespace SyncNotifier
