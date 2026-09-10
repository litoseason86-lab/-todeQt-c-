.pragma library

// QML 逻辑日算法与系统时钟解耦：生产传 new Date()，测试传固定 Date。
// Date 返回值归零到本地午夜，供页面做日期和周期比较。
function todayDate(dayStartHour, nowDate) {
    var logicalDate = new Date(nowDate.getFullYear(), nowDate.getMonth(), nowDate.getDate())
    if (nowDate.getHours() < dayStartHour) {
        logicalDate.setDate(logicalDate.getDate() - 1)
    }
    return logicalDate
}

function todayIso(dayStartHour, nowDate) {
    var date = todayDate(dayStartHour, nowDate)
    var month = date.getMonth() + 1
    var day = date.getDate()
    return date.getFullYear() + "-" + (month < 10 ? "0" : "") + month
            + "-" + (day < 10 ? "0" : "") + day
}

// JavaScript Date 会把 2 月 31 日滚到 3 月；表单必须回查年月日，不能只检查 NaN。
function parseIsoDate(text) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(text))
        return null
    var parts = text.split("-").map(Number)
    var date = new Date(parts[0], parts[1] - 1, parts[2])
    return parts[0] >= 2000 && parts[0] <= 2100 && date.getFullYear() === parts[0]
        && date.getMonth() === parts[1] - 1 && date.getDate() === parts[2] ? date : null
}
