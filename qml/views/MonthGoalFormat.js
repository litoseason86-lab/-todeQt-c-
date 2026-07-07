.pragma library

function isoDate(value) {
    return Qt.formatDate(value, "yyyy-MM-dd")
}

function formatClock(value) {
    if (value === undefined || value === null) {
        return "--:--"
    }

    var text = String(value).trim()
    if (text.length === 0) {
        return "--:--"
    }

    // 服务层可能返回 Qt ISODate 或 SQLite 时间文本；先按字符串截取，避免 JS Date 在不同平台解析空格格式不一致。
    var separatorIndex = text.indexOf("T")
    if (separatorIndex < 0) {
        separatorIndex = text.indexOf(" ")
    }
    if (separatorIndex >= 0 && text.length >= separatorIndex + 6) {
        var clockText = text.substring(separatorIndex + 1, separatorIndex + 6)
        if (/^\d{2}:\d{2}$/.test(clockText)) {
            return clockText
        }
    }

    var parsed = new Date(text)
    if (!isNaN(parsed.getTime())) {
        return Qt.formatTime(parsed, "HH:mm")
    }

    return "--:--"
}
