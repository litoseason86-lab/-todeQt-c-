.pragma library

function formatDuration(seconds) {
    var safe = Math.max(0, Math.floor(Number(seconds || 0)))
    if (safe > 0 && safe < 60) {
        return safe + "秒"
    }
    var hours = Math.floor(safe / 3600)
    var minutes = Math.floor((safe % 3600) / 60)
    if (hours > 0) {
        return hours + "小时" + minutes + "分钟"
    }
    return minutes + "分钟"
}

function decimalHours(seconds) {
    return (Math.max(0, Number(seconds || 0)) / 3600).toFixed(1)
}

function totalDurationValue(seconds) {
    // 小于一小时显示分钟/秒；超过一小时后切成小数小时，卡片不会过宽。
    var safe = Math.max(0, Math.floor(Number(seconds || 0)))
    if (safe < 3600) {
        return formatDuration(safe)
    }
    return decimalHours(safe)
}

function totalDurationUnit(seconds) {
    var safe = Math.max(0, Math.floor(Number(seconds || 0)))
    return safe >= 3600 ? "小时" : ""
}

function mondayOf(value) {
    var date = new Date(value)
    var day = date.getDay()
    var diff = day === 0 ? -6 : 1 - day
    date.setDate(date.getDate() + diff)
    date.setHours(0, 0, 0, 0)
    return date
}

function endOfWeek(start) {
    var date = new Date(start)
    date.setDate(date.getDate() + 6)
    return date
}

function formatWeekRange(start, end) {
    return (start.getMonth() + 1) + "." + start.getDate()
            + "-" + (end.getMonth() + 1) + "." + end.getDate()
}

function dayStart(value) {
    var date = new Date(value)
    date.setHours(0, 0, 0, 0)
    return date
}

function weekdayLabel(dateValue, indexValue) {
    var fallback = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    var date = dateValue instanceof Date ? dateValue : new Date(dateValue)
    if (isNaN(date.getTime())) {
        return fallback[indexValue % fallback.length]
    }
    var labels = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
    return labels[date.getDay()]
}
