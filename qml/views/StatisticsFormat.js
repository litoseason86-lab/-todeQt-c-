.pragma library

var LEVELS = [
    { lv: 1, min: 0, name: "起步" },
    { lv: 2, min: 3, name: "上路" },
    { lv: 3, min: 8, name: "成习" },
    { lv: 4, min: 20, name: "丰收" },
    { lv: 5, min: 40, name: "燎原" }
]

function levelOf(count) {
    var normalized = Math.max(0, Math.floor(Number(count || 0)))
    var current = LEVELS[0]
    for (var i = 0; i < LEVELS.length; ++i) {
        if (normalized >= LEVELS[i].min)
            current = LEVELS[i]
    }
    return current
}

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

// 统计卡的「数字」与「单位」始终分两个值返回，不要把单位拼进数字里：
// 卡片用大号数据字排数字、小号弱色排单位，中文单位混进数字串会走字体回退，
// 同一排卡片的字重和基线就对不上了。
// 满一小时后切成小数小时，卡片不会过宽。
function totalDurationValue(seconds) {
    var safe = Math.max(0, Math.floor(Number(seconds || 0)))
    if (safe >= 3600) {
        return decimalHours(safe)
    }
    if (safe > 0 && safe < 60) {
        return String(safe)
    }
    return String(Math.floor(safe / 60))
}

function totalDurationUnit(seconds) {
    var safe = Math.max(0, Math.floor(Number(seconds || 0)))
    if (safe >= 3600) {
        return "小时"
    }
    // 不足一分钟才按秒读；0 秒归到「分钟」，空数据仍读作「0 分钟」。
    return (safe > 0 && safe < 60) ? "秒" : "分钟"
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
