.pragma library
.import "../Duration.js" as Duration
.import "../RoutineWeekdays.js" as Weekdays
.import "../ScheduleWeeks.js" as ScheduleWeeks

// 废纸篓页的文字格式化。服务只给结构化数据，句子在这里拼（同周复盘的做法）。
//
// 日期一律拆年月日三个整数来拼，不经过 Date 换算（业务规则「界面与验证约定」）；
// 「今天」只认服务给的 today（逻辑今天，yyyy-MM-dd），页面不自己算。
// 唯一用到 Date.UTC 的地方是「今天往前一天」，UTC 下没有时区和夏令时，不会差出一天。

var TYPE_NAMES = {
    "task": "任务",
    "focus_session": "专注记录",
    "rest_session": "休息记录",
    "knowledge_gap": "知识缺口",
    "memo": "备忘录",
    "routine": "每日例行",
    "schedule_entry": "课表",
    "countdown_goal": "倒计时"
}

function parseIso(text) {
    var match = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(text === undefined || text === null ? "" : text))
    if (!match) {
        return null
    }
    return { year: Number(match[1]), month: Number(match[2]), day: Number(match[3]) }
}

function pad(value) {
    return value < 10 ? "0" + value : String(value)
}

// 「M月d日」；与 today 不是同一年（或 today 缺失）时带年份「yyyy年M月d日」。无法解析返回空串。
function dateLabel(iso, today) {
    var parts = parseIso(iso)
    if (!parts) {
        return ""
    }
    var now = parseIso(today)
    var core = parts.month + "月" + parts.day + "日"
    return now && now.year === parts.year ? core : parts.year + "年" + core
}

// 倒计时一律带年份：目标日期常常在明年，省略年份会读不出是哪一年。
function dateLabelWithYear(iso) {
    var parts = parseIso(iso)
    return parts ? parts.year + "年" + parts.month + "月" + parts.day + "日" : ""
}

function yesterdayOf(today) {
    var parts = parseIso(today)
    if (!parts) {
        return ""
    }
    var moved = new Date(Date.UTC(parts.year, parts.month - 1, parts.day - 1))
    return moved.getUTCFullYear() + "-" + pad(moved.getUTCMonth() + 1) + "-" + pad(moved.getUTCDate())
}

// 分组标签：删除日期为空 → 「删除时间不详」；今天 / 昨天 / M月d日（跨年带年份）。
function groupLabel(deletedDate, today) {
    var text = String(deletedDate === undefined || deletedDate === null ? "" : deletedDate)
    if (text.length === 0 || !parseIso(text)) {
        return "删除时间不详"
    }
    if (text === today) {
        return "今天"
    }
    if (text === yesterdayOf(today)) {
        return "昨天"
    }
    return dateLabel(text, today)
}

// 把按服务顺序（从新到旧）排好的列表按 deletedDate 分组，保持服务给的顺序。
// 返回 [{ key, label, remaining, items }]；remaining 取组内第一项的 remainingDays，没有日期的组不写剩余天数。
function groupItems(items, today) {
    var groups = []
    var byKey = {}
    for (var i = 0; i < items.length; ++i) {
        var item = items[i]
        var key = String(item.deletedDate === undefined || item.deletedDate === null ? "" : item.deletedDate)
        var group = byKey[key]
        if (!group) {
            group = {
                key: key,
                label: groupLabel(key, today),
                remaining: key.length > 0 ? "还剩 " + Number(item.remainingDays) + " 天" : "",
                items: []
            }
            byKey[key] = group
            groups.push(group)
        }
        group.items.push(item)
    }
    return groups
}

function groupHeading(group) {
    return group.label + " · " + group.items.length
}

// ISO 时间文本里的 HH:mm（「2026-10-06T14:05:00.000」→「14:05」）；不是这个形状返回空串。
function timeOf(iso) {
    var match = /^\d{4}-\d{2}-\d{2}[T ](\d{2}):(\d{2})/.exec(String(iso === undefined || iso === null ? "" : iso))
    return match ? match[1] + ":" + match[2] : ""
}

// 「10月6日 14:05–14:50」。专注、休息记录的要点和「恢复失败」提示里的冲突时间段共用。
// 缺的部分整段省略：没有结束时间就只写起点，不留悬空的「–」。
function sessionSpan(details, today) {
    var start = String(details && details.startTime ? details.startTime : "")
    var end = String(details && details.endTime ? details.endTime : "")
    var date = dateLabel(start, today)
    var startTime = timeOf(start)
    var endTime = timeOf(end)
    var clock = startTime.length > 0 && endTime.length > 0 ? startTime + "–" + endTime : startTime
    return [date, clock].filter(function (part) { return part.length > 0 }).join(" ")
}

function blockedText(reason) {
    if (reason === "corrupted") {
        return "内容已损坏，无法恢复"
    }
    if (reason === "needsUpdate") {
        return "需要更新应用后才能恢复"
    }
    return ""
}

function scheduleParts(details) {
    var parts = []
    var weekday = Number(details.weekday)
    var days = Weekdays.DAYS
    if (weekday >= 1 && weekday <= days.length) {
        parts.push(days[weekday - 1].fullLabel)
    }
    var hasTimes = details.startMinutes !== undefined && details.endMinutes !== undefined
    var clock = hasTimes
            ? ScheduleWeeks.formatMinutes(details.startMinutes) + "–" + ScheduleWeeks.formatMinutes(details.endMinutes)
            : ""
    // 星期与时间写在同一段里：「周四 14:00–15:40」。
    if (parts.length > 0 && clock.length > 0) {
        parts[0] = parts[0] + " " + clock
    } else if (clock.length > 0) {
        parts.push(clock)
    }
    var start = Number(details.weekStart)
    var end = Number(details.weekEnd)
    if (start > 0 && end > 0) {
        // 不用 ScheduleWeeks.weekRangeLabel：它在「整学期每周都上」时返回空串、范围用半角连字符，
        // 而这里要把范围原样写出来（设计稿是「第 1–16 周」）。单双周文案仍复用 parityLabel。
        parts.push(start === end ? "第 " + start + " 周" : "第 " + start + "–" + end + " 周")
    }
    var parity = ScheduleWeeks.parityLabel(details.weekParity)
    if (parity.length > 0) {
        parts.push(parity)
    }
    var location = String(details.location === undefined || details.location === null ? "" : details.location)
    if (location.length > 0) {
        parts.push(location)
    }
    return parts
}

// 卡片第二行：类型和要点，缺的部分整段省略。不能恢复的项写原因（认得类型时前面加类型名）。
function metaText(item, today) {
    var details = item.details || {}
    var typeName = TYPE_NAMES[item.kind] || ""
    var category = String(item.categoryName === undefined || item.categoryName === null ? "" : item.categoryName)
    var parts = []
    if (typeName.length > 0) {
        parts.push(typeName)
    }
    var reason = item.restorable === false ? blockedText(String(item.blockedReason || "")) : ""
    if (reason.length > 0) {
        parts.push(reason)
        return parts.join(" · ")
    }
    switch (item.kind) {
    case "task":
        parts.push(dateLabel(details.date, today))
        parts.push(category)
        break
    case "focus_session":
        parts.push(sessionSpan(details, today))
        parts.push(Duration.formatSeconds(details.durationSeconds))
        parts.push(category)
        break
    case "rest_session":
        parts.push(sessionSpan(details, today))
        parts.push(Duration.formatSeconds(details.durationSeconds))
        break
    case "memo":
        parts.push(category)
        break
    case "knowledge_gap":
        parts.push(category)
        var due = dateLabel(details.dueDate, today)
        parts.push(due.length > 0 ? "计划 " + due : "")
        break
    case "routine":
        parts.push(category)
        parts.push(Weekdays.text(details.weekdays))
        break
    case "schedule_entry":
        parts = parts.concat(scheduleParts(details))
        break
    case "countdown_goal":
        parts.push(dateLabelWithYear(details.targetDate))
        break
    default:
        break
    }
    return parts.filter(function (part) { return part.length > 0 }).join(" · ")
}

// 恢复失败的提示。冲突（专注 / 休息撞时间）时在原因前写出这一项的时间段，让用户知道撞的是哪一段。
function restoreFailureText(item, result, today) {
    var title = String(item.title)
    var reason = String(result && result.error ? result.error : "")
    var conflict = String(result && result.conflict ? result.conflict : "")
    var span = conflict.length > 0 ? sessionSpan(item.details || {}, today) : ""
    return "没能恢复「" + title + "」：" + (span.length > 0 ? span + " " : "") + reason
}
