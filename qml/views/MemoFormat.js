.pragma library

// 用本地日历日期比较，而不是经过了多少个 24 小时，避免午夜和夏令时错档。
function formatUpdatedAt(value, now) {
    var date = new Date(value)
    var current = now === undefined ? new Date() : new Date(now)
    if (isNaN(date.getTime()) || isNaN(current.getTime())) return ""
    var day = Date.UTC(date.getFullYear(), date.getMonth(), date.getDate())
    var today = Date.UTC(current.getFullYear(), current.getMonth(), current.getDate())
    var distance = Math.round((today - day) / 86400000)
    if (distance === 0) return "今天 " + pad(date.getHours()) + ":" + pad(date.getMinutes())
    if (distance === 1) return "昨天"
    if (distance >= 2 && distance <= 6) return distance + " 天前"
    // 近日的称呼优先于年份；例如元旦看除夕的记录仍然显示“昨天”。
    return (date.getFullYear() === current.getFullYear() ? "" : date.getFullYear() + "年")
            + (date.getMonth() + 1) + "月" + date.getDate() + "日"
}

function pad(value) { return value < 10 ? "0" + value : String(value) }

// 服务按 Unicode 字符计数，不能把一个表情的两个 UTF-16 单元当成两个字。
function characterCount(value) { return Array.from(String(value)).length }
function firstCharacters(value, count) { return Array.from(String(value)).slice(0, count).join("") }
