.pragma library

// 长期目标的「按这个速度来不来得及」。
//
// 这是目标页真正要回答的问题，此前界面只给出 forecastDays 和 deadline 两个数，
// 让用户自己心算。列表和网格两处都要用同一个结论，所以做成纯函数：
// 不碰 Theme、不碰服务，只吃一个 goal map 和一个「今天」。
//
// forecastDays 的口径来自 GoalService::forecastDaysFor：
//   0   目标已完成
//   -1  还没有任何有效番茄，无从推算速度——此时必须说「暂无预测」，
//       不能编一个天数出来
//   >0  按当前速度还需要的天数

function daysBetween(from, to) {
    if (!from || !to) {
        return NaN
    }
    // 都归零到本地午夜再相减，避免两端时分秒不同导致差一天。
    var a = new Date(from.getFullYear(), from.getMonth(), from.getDate())
    var b = new Date(to.getFullYear(), to.getMonth(), to.getDate())
    return Math.round((b.getTime() - a.getTime()) / 86400000)
}

function toDate(value) {
    if (!value) {
        return null
    }
    var d = value instanceof Date ? value : new Date(value)
    return isNaN(d.getTime()) ? null : d
}

function forecastOf(goal) {
    var raw = goal && goal.forecastDays !== undefined && goal.forecastDays !== null
            ? Number(goal.forecastDays) : -1
    return isNaN(raw) ? -1 : raw
}

// 结论。tone 只有四种，交给调用方映射到主题色：
//   "good" 达成/来得及、"warn" 偏慢/超期、"muted" 长期或暂无预测
function verdict(goal, today) {
    if (!goal) {
        return { text: "", tone: "muted" }
    }
    if (goal.achieved) {
        return { text: "已达成", tone: "good" }
    }

    var deadline = toDate(goal.deadline)
    var now = toDate(today) || new Date()
    var forecast = forecastOf(goal)

    if (!deadline) {
        // 没有截止日是一种正常配置（长期投入），不是「缺数据」，不该报警。
        return { text: "长期", tone: "muted" }
    }

    var daysLeft = daysBetween(now, deadline)
    if (daysLeft < 0) {
        return { text: "已超期 " + (-daysLeft) + " 天", tone: "warn" }
    }
    if (forecast < 0) {
        return { text: "暂无预测", tone: "muted" }
    }
    if (forecast <= daysLeft) {
        return { text: "来得及", tone: "good" }
    }
    return { text: "偏慢 " + (forecast - daysLeft) + " 天", tone: "warn" }
}

// 结论下面那行事实。只陈述数字，判断留给 verdict。
function detail(goal, today) {
    if (!goal) {
        return ""
    }
    if (goal.achieved) {
        var at = toDate(goal.achievedAt)
        return at ? "已达成 · " + (at.getMonth() + 1) + " 月 " + at.getDate() + " 日" : "已达成"
    }

    var parts = []
    var forecast = forecastOf(goal)
    if (forecast > 0) {
        parts.push("照此速度 " + forecast + " 天完成")
    } else if (forecast < 0) {
        parts.push("还没有专注记录，暂时无法预测")
    }

    var deadline = toDate(goal.deadline)
    if (!deadline) {
        parts.push("未设截止日")
    } else {
        var daysLeft = daysBetween(toDate(today) || new Date(), deadline)
        parts.push(daysLeft >= 0 ? "距截止 " + daysLeft + " 天"
                                 : "已过截止日 " + (-daysLeft) + " 天")
    }
    return parts.join(" · ")
}
