.pragma library

// QML 逻辑日算法与系统时钟解耦：生产传 new Date()，测试传固定 Date。
// Date 返回值归零到本地午夜，供页面做日期和周期比较。
function todayDate(dayStartHour, nowDate) {
    var shifted = new Date(nowDate.getTime() - dayStartHour * 3600 * 1000)
    return new Date(shifted.getFullYear(), shifted.getMonth(), shifted.getDate())
}

function todayIso(dayStartHour, nowDate) {
    var date = todayDate(dayStartHour, nowDate)
    var month = date.getMonth() + 1
    var day = date.getDate()
    return date.getFullYear() + "-" + (month < 10 ? "0" : "") + month
            + "-" + (day < 10 ? "0" : "") + day
}
