import QtQuick

// 将同一事件循环内的多个数据失效通知合并为一次刷新；不使用毫秒延迟，
// 因此不会吞掉下一轮事件循环里真实发生的更新。
QtObject {
    id: root

    property bool active: true
    // 仅供测试与诊断读取；调用页面只能通过 request() 请求刷新。
    property bool scheduled: false
    // 以下划线开头的是组件内部状态，不是调用方接口。
    property int _generation: 0
    // 回调保留普通 JS 对象而非外部页面引用；组件销毁后先短路，不能触碰失效 QML 对象。
    property var _lifecycleGuard: ({ alive: true })

    signal triggered()

    function request() {
        if (root.scheduled)
            return

        root.scheduled = true
        const scheduledGeneration = root._generation
        const guard = root._lifecycleGuard
        Qt.callLater(function() {
            if (!guard.alive)
                return
            // cancel() 后又有新请求时，旧回调绝不能清掉新请求的排队状态。
            if (scheduledGeneration !== root._generation)
                return

            root.scheduled = false
            if (root.active)
                root.triggered()
        })
    }

    function cancel() {
        // 递增代次让已排队回调失效，供完成动画的定时刷新消除尾随刷新。
        root._generation += 1
        root.scheduled = false
    }

    Component.onDestruction: {
        root._lifecycleGuard.alive = false
    }
}
