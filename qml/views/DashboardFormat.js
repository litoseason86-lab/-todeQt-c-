.pragma library

// 仪表盘纯格式函数：不读时钟、不碰服务，生产传实时值、测试传固定值。

function greetingFor(hour) {
    if (hour < 5) {
        return "夜深了"
    }
    if (hour < 11) {
        return "早上好"
    }
    if (hour < 13) {
        return "中午好"
    }
    if (hour < 18) {
        return "下午好"
    }
    if (hour < 23) {
        return "晚上好"
    }
    return "夜深了"
}

// 累计秒数 → 小时文案：破百后小数位失去意义，改为取整。
function totalHoursText(totalSeconds) {
    var hours = Math.max(0, Number(totalSeconds) || 0) / 3600
    if (hours >= 100) {
        return String(Math.round(hours))
    }
    return String(Math.round(hours * 10) / 10)
}

// 累计秒数 → “相当于 N 天”文案，保留一位小数。
function equivalentDaysText(totalSeconds) {
    var days = Math.max(0, Number(totalSeconds) || 0) / 86400
    return String(Math.round(days * 10) / 10)
}

// 每天换一条的轮播文案：按“年内第几天”取模，避免每次刷新都变。
function dailyPick(items, date) {
    if (!items || items.length === 0) {
        return ""
    }
    var start = new Date(date.getFullYear(), 0, 1)
    var dayOfYear = Math.floor((date.getTime() - start.getTime()) / 86400000)
    return items[((dayOfYear % items.length) + items.length) % items.length]
}
