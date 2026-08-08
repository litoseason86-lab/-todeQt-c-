.pragma library

// 分钟数的中文展示。任务行、周复盘卡都要把「计划/实际用时」写成同一种样子，
// 各自实现一遍必然出现「1 小时 5 分」和「65 分钟」并存的情况。
function format(minutes) {
    var safe = Math.max(0, Math.round(Number(minutes || 0)))
    var h = Math.floor(safe / 60)
    var m = safe % 60
    if (h > 0 && m > 0) {
        return h + " 小时 " + m + " 分"
    }
    if (h > 0) {
        return h + " 小时"
    }
    return m + " 分钟"
}

// 秒数版本：向下取整到分钟，不足 1 分钟仍显示 0 分钟而不是空串。
function formatSeconds(seconds) {
    return format(Math.floor(Math.max(0, Number(seconds || 0)) / 60))
}
