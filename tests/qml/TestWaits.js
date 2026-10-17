.pragma library

// QML 测试里不直接写 wait(<毫秒>)（062 A059，由 tests/qml_fixed_wait_gate.py 把关）：固定时长要么白等，
// 要么在慢机器上不够长。等「某个状态出现」一律用 tryCompare / tryVerify，等待对象就是紧接着被断言的那个状态，
// 等布局排好用 waitForItemPolished / waitForRendering。只有下面两种确实需要一段时间窗的情况才调这里，
// reason 必填，写清楚为什么不能改成等状态：
//
// observe：确认某件事在一段时间里**没有**发生（例如到点后不会自动开始休息、不会多发一次信号）。
//          没有可等的信号，只能给它一个窗口；窗口太短只会让测试漏报，不会误报。
// letElapse：让计时器、动画、去抖或 Qt.callLater 之后的下一拍自然走完，接下来要断言的状态没有单独可等的属性。

function requireReason(reason) {
    if (typeof reason !== "string" || reason.trim().length === 0)
        throw new Error("TestWaits：固定等待必须写明原因")
}

function observe(testCase, ms, reason) {
    requireReason(reason)
    testCase.wait(ms)
}

function letElapse(testCase, ms, reason) {
    requireReason(reason)
    testCase.wait(ms)
}
