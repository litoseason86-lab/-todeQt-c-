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
    return isoOf(todayDate(dayStartHour, nowDate))
}

// 已经换算好的逻辑日（本地午夜的 Date）转成 yyyy-MM-dd：只取年、月、日三个整数拼接，
// 不经过 Qt.formatDate 与时区换算，也不再减一次日界。
function isoOf(date) {
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

// 统一将 QDate / JS Date / ISO 日期文本转为本地午夜 Date：
// Qt 将无时间的 QDate 转为 JS Date 时落在 UTC 00:00:00.000，在负时区直接取本地日会提前一天；
// 识别纯 UTC 午夜并按 UTC 年月日重建本地午夜，同时保留已是本地午夜的 JS Date 与 ISO 字符串语义。
function toLocalDate(value) {
    if (value === null || value === undefined || value === "")
        return null
    if (typeof value === "string") {
        var trimmed = value.trim()
        var parsedIso = parseIsoDate(trimmed.substring(0, 10))
        if (parsedIso)
            return parsedIso
        var parsed = new Date(trimmed)
        if (isNaN(parsed.getTime()))
            return null
        return new Date(parsed.getFullYear(), parsed.getMonth(), parsed.getDate())
    }
    if (value instanceof Date) {
        if (isNaN(value.getTime()))
            return null
        if (value.getUTCHours() === 0 && value.getUTCMinutes() === 0
                && value.getUTCSeconds() === 0 && value.getUTCMilliseconds() === 0) {
            return new Date(value.getUTCFullYear(), value.getUTCMonth(), value.getUTCDate())
        }
        return new Date(value.getFullYear(), value.getMonth(), value.getDate())
    }
    return toLocalDate(String(value))
}

function isoFromValue(value) {
    var local = toLocalDate(value)
    return local ? isoOf(local) : ""
}

function formatChineseDate(value) {
    var local = toLocalDate(value)
    if (!local)
        return ""
    var month = local.getMonth() + 1
    var day = local.getDate()
    return local.getFullYear() + "年"
            + (month < 10 ? "0" : "") + month + "月"
            + (day < 10 ? "0" : "") + day + "日"
}
