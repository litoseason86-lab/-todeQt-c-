import QtQuick

// 实时专注秒数的唯一口径：已落库累计 + 进行中会话秒数。
// 只有番茄工作阶段(phase=1)和自由专注(phase=0 且有会话)累计，休息(phase=2)不计，
// 与统计服务的有效会话口径一致。仪表盘与今日任务页共用本组件，
// 禁止在页面里复制这段拼接（口径漂移守护）。
QtObject {
    id: root

    property var timerRef: null
    property int baseSeconds: 0

    readonly property int phase: root.timerRef ? Number(root.timerRef.phase) : 0
    readonly property bool hasSession: root.timerRef ? Boolean(root.timerRef.hasActiveSession) : false

    // 显式经由 timerRef.elapsedSeconds 读取，tick 信号才能驱动逐秒刷新。
    readonly property int liveSeconds: {
        var base = Math.max(0, Number(root.baseSeconds || 0))
        if (root.timerRef && (root.phase === 1 || (root.phase === 0 && root.hasSession))) {
            base += Math.max(0, Number(root.timerRef.elapsedSeconds || 0))
        }
        return base
    }
}
