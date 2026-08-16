import QtQuick

// 「哪些后台作业不能被打断」的唯一清单。main.qml 的关窗与菜单栏退出两条路径都只执行
// 这里的返回值——决策留在 main.qml 里就没法测（offscreen 下起不了真窗口、也触发不了
// onClosing），拆成纯函数才能直接断言。以后再加长时间后台作业，在这里加分支，
// 不要回到 main.qml 里堆 if。
QtObject {
    id: guard

    // 返回空串表示可以关闭；非空表示必须挡住，且该字符串就是直接展示给用户的原因。
    function blockReason(backupBusy, backupText, exportBusy) {
        // 备份/恢复排在导出前面：它会原子替换整个数据库文件，是两者中更危险的那个，
        // 同时进行时报它更准确。
        if (backupBusy) {
            return (backupText || "数据操作正在进行") + "，完成后再关闭"
        }
        // 导出跑在工作线程上，进程退出会让它连同未写完的文件一起消失，
        // 而用户以为已经导好了。
        if (exportBusy) {
            return "正在导出数据，完成后再关闭"
        }
        return ""
    }
}
