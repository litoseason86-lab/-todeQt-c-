.pragma library

// 每日例行「重复日」的共享口径：位掩码与中文文案。
// 列表行上的重复药丸和「重复」弹窗都要显示同一套星期名字，各写一份必然分家。
// 与 C++ 的 src/services/RoutineRules.h 同一口径：第 0 位周一 … 第 6 位周日。

var EVERY_DAY = 0x7F        // 一周七天全选
var MON_TO_FRI = 0x1F       // 周一至周五
var WEEKEND = 0x60          // 周六 + 周日

// 顺序即位序：第 0 项是周一，正好对应 QDate::dayOfWeek() - 1。
var DAYS = [
    { shortLabel: "一", fullLabel: "周一", bit: 0x01 },
    { shortLabel: "二", fullLabel: "周二", bit: 0x02 },
    { shortLabel: "三", fullLabel: "周三", bit: 0x04 },
    { shortLabel: "四", fullLabel: "周四", bit: 0x08 },
    { shortLabel: "五", fullLabel: "周五", bit: 0x10 },
    { shortLabel: "六", fullLabel: "周六", bit: 0x20 },
    { shortLabel: "日", fullLabel: "周日", bit: 0x40 }
]

// 掩码转中文。这段文案要塞进列表行上一个固定宽度的药丸里，所以「短」是硬要求，
// 不只是好看：带顿号的写法（周一、二、四、六）到四天就是 8 个字符，药丸装不下会省略号收尾，
// 用户反而看不出自己选了哪几天。
//
// 规则由短到长：
//   七天            → 每天
//   周一至周五      → 工作日
//   周六日          → 周末
//   正好缺一天      → 除周日（比罗列六天短得多，也更好懂）
//   其余            → 周一三五（去掉顿号；课表口语本来就说「一三五」「二四六」）
// 最长的情况是五天里不成「工作日」的组合，如周一二三四六，共 6 个字符。
function text(mask) {
    var normalized = Number(mask)
    if (!(normalized > 0)) {
        // 0 或非数字都属于坏数据（服务层已经拒绝写入）。显示成「未设置」而不是空白，
        // 免得看起来像这一处漏渲染了。
        return "未设置"
    }
    if (normalized === EVERY_DAY) {
        return "每天"
    }
    if (normalized === MON_TO_FRI) {
        return "工作日"
    }
    if (normalized === WEEKEND) {
        return "周末"
    }

    var on = []
    var off = []
    for (var i = 0; i < DAYS.length; ++i) {
        if ((normalized & DAYS[i].bit) !== 0) {
            on.push(DAYS[i].shortLabel)
        } else {
            off.push(DAYS[i].fullLabel)
        }
    }
    if (on.length === 0) {
        return "未设置"
    }
    if (off.length === 1) {
        return "除" + off[0]
    }
    return "周" + on.join("")
}

// 点一次切换某一天。这里不拦「至少留一天」：拦在这里会变成点了没反应，
// 用户不知道为什么；放到保存时报错才能说清原因。
function toggle(mask, bit) {
    return (mask & bit) !== 0 ? (mask & ~bit) : (mask | bit)
}

// 坏数据（0、负数、非数字）一律回落成「每天」，与数据库迁移给旧例行补的默认值一致。
function normalize(mask) {
    var value = Number(mask)
    return value > 0 && value <= EVERY_DAY ? value : EVERY_DAY
}
