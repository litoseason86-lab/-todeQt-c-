.pragma library

// 只读测试数据；权限仅在读表条目上开启，不进入生产 QML。
function load(name) {
    var request = new XMLHttpRequest()
    request.open("GET", Qt.resolvedUrl("../fixtures/calibers/" + name + ".json"), false)
    request.send()
    var rows = JSON.parse(request.responseText)
    if (!Array.isArray(rows) || rows.length === 0) throw new Error("对照表为空：" + name)
    return rows
}

// 无时区文本按本地年月日构造，避免 ISO 日期串隐含 UTC。
function date(text) {
    var parts = text.split(/[-T:]/).map(Number)
    return new Date(parts[0], parts[1] - 1, parts[2], parts[3] || 0, parts[4] || 0, parts[5] || 0)
}

// JSON 无法表示非有限数字和 undefined；显式标签只由测试解码，不改变数组表结构。
function value(input) {
    if (input && typeof input === "object" && input.date) return date(input.date)
    if (input && typeof input === "object" && input.special) {
        switch (input.special) {
        case "NaN": return NaN
        case "Infinity": return Infinity
        case "-Infinity": return -Infinity
        case "undefined": return undefined
        }
        throw new Error("未知特殊值：" + input.special)
    }
    return input
}
