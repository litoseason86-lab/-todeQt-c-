#ifndef FOCUSSESSIONRULES_H
#define FOCUSSESSIONRULES_H

namespace FocusSessionRules {

// 少于 3 分钟的会话属于误触或测试残留，不进入历史、统计和导出。
inline constexpr int kMinimumValidDurationSeconds = 3 * 60;

// 自动完成任务的门槛高于“有效记录”门槛：3 分钟可以记历史，5 分钟才算任务推进完成。
inline constexpr int kAutoCompleteTaskDurationSeconds = 5 * 60;

}

#endif // FOCUSSESSIONRULES_H
