.pragma library

// 课表的日期 ↔ 周次换算。与 LogicalDay.js 同构：纯函数、不读全局状态，
// 所有输入显式传入，测试可以喂固定日期得到确定结果。
//
// 「周次」指学期里的第几周，从 1 开始。第 1 周是学期起始日所在的那一周，
// 每周固定以周一为起点——课表的一行就是一周，锚点若不落在周一，
// 同一周里的周一和周三会被算成相邻两个周次。

// 把任意日期回退到所在周的周一，并归零到本地午夜。
function mondayOf(value) {
    var date = new Date(value)
    var day = date.getDay()
    // JS 的 getDay() 是 0(周日)–6(周六)：周日要往回退 6 天才到本周周一，
    // 其余按 1 - day 回退。直接用 1 - day 会把周日算成下一周的周一。
    var diff = day === 0 ? -6 : 1 - day
    date.setDate(date.getDate() + diff)
    date.setHours(0, 0, 0, 0)
    return date
}

function isoDate(value) {
    var date = new Date(value)
    var month = date.getMonth() + 1
    var day = date.getDate()
    return date.getFullYear() + "-" + (month < 10 ? "0" : "") + month
            + "-" + (day < 10 ? "0" : "") + day
}

// 解析设置里存的学期起始日。无效或未设置时返回 null，
// 调用方据此决定是引导用户先设置，还是回退到「本周即第 1 周」。
function parseSemesterStart(isoText) {
    var text = String(isoText || "").trim()
    if (text.length === 0) {
        return null
    }
    // 只接受 yyyy-MM-dd。交给 Date 直接解析会把 "2026-9" 这类残缺串
    // 解释成某个真实日期，让一个坏配置静悄悄地算出错误周次。
    var match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text)
    if (!match) {
        return null
    }
    var year = Number(match[1])
    var month = Number(match[2])
    var day = Number(match[3])
    var date = new Date(year, month - 1, day)
    // 构造后回读一遍，挡住 2026-02-31 这种会被 Date 静默进位的日期。
    if (date.getFullYear() !== year || date.getMonth() !== month - 1
            || date.getDate() !== day) {
        return null
    }
    return mondayOf(date)
}

// 给定日期落在第几周。起始日无效时返回 0，表示「算不出周次」；
// 日期早于学期开始时返回 0 或负数由调用方自行处理（服务层对 <1 的周次返回空课表）。
function weekIndexForDate(semesterStartIso, value) {
    var start = parseSemesterStart(semesterStartIso)
    if (!start) {
        return 0
    }
    var target = mondayOf(value)
    // 按「周一到周一」的整周差计算，避免夏令时导致的小时数漂移影响取整。
    // 先算天数差再除以 7：两个周一之间的天数一定是 7 的整数倍。
    var dayMs = 24 * 60 * 60 * 1000
    var days = Math.round((target.getTime() - start.getTime()) / dayMs)
    return Math.floor(days / 7) + 1
}

// 第 weekIndex 周的周一。起始日无效时返回 null。
function mondayOfWeek(semesterStartIso, weekIndex) {
    var start = parseSemesterStart(semesterStartIso)
    if (!start) {
        return null
    }
    var date = new Date(start)
    date.setDate(date.getDate() + (Number(weekIndex) - 1) * 7)
    return date
}

// 第 weekIndex 周里第 weekday(1=周一…7=周日) 天的日期。
function dateOfWeekday(semesterStartIso, weekIndex, weekday) {
    var monday = mondayOfWeek(semesterStartIso, weekIndex)
    if (!monday) {
        return null
    }
    var date = new Date(monday)
    date.setDate(date.getDate() + (Number(weekday) - 1))
    return date
}

// 把「当天第几分钟」格式化成 HH:mm。课表的起止时间都以分钟数存储。
function formatMinutes(minutes) {
    var safe = Math.max(0, Math.min(24 * 60, Number(minutes) || 0))
    var hours = Math.floor(safe / 60)
    var mins = safe % 60
    return (hours < 10 ? "0" : "") + hours + ":" + (mins < 10 ? "0" : "") + mins
}

// HH:mm → 当天第几分钟。解析失败返回 -1，调用方据此拒绝保存。
function parseMinutes(text) {
    var match = /^(\d{1,2}):(\d{2})$/.exec(String(text || "").trim())
    if (!match) {
        return -1
    }
    var hours = Number(match[1])
    var mins = Number(match[2])
    if (hours < 0 || hours > 24 || mins < 0 || mins > 59) {
        return -1
    }
    var total = hours * 60 + mins
    // 允许 24:00 表示一天的末尾，但不允许 24:30 这种越界值。
    if (total > 24 * 60) {
        return -1
    }
    return total
}

// 同一天内互相重叠的课表项分配「泳道」，让它们并排显示而不是互相盖住。
// 冲突是被允许的排法（例如两门可选课占同一时段），因此不能靠禁止录入来回避这个问题；
// 一旦两块直接叠在一起，上面那块会把下面那块完全遮死，用户根本看不到自己排了两门。
//
// 返回 [{ entry, lane, laneCount }]，调用方按 lane / laneCount 切分列宽。
function layoutEntries(entries, startRole, endRole, visualGeometry) {
    var sorted = (entries || []).slice().sort(function (a, b) {
        if (Number(a[startRole]) !== Number(b[startRole])) {
            return Number(a[startRole]) - Number(b[startRole])
        }
        return Number(a[endRole]) - Number(b[endRole])
    })

    var result = []
    // 一个「簇」是一组互相牵连的重叠项。簇内共享泳道数，簇之间互不影响——
    // 若整天共用一个泳道数，上午的两门课会把下午那门无关的课也压成半宽。
    var cluster = []
    var laneEnds = []
    var clusterEnd = -1

    function flushCluster() {
        for (var i = 0; i < cluster.length; ++i) {
            cluster[i].laneCount = laneEnds.length
            result.push(cluster[i])
        }
        cluster = []
        laneEnds = []
        clusterEnd = -1
    }

    for (var i = 0; i < sorted.length; ++i) {
        var entry = sorted[i]
        var entryStart = Number(entry[startRole])
        var entryEnd = Number(entry[endRole])
        // 起点不早于当前簇的最晚结束时间，说明它与簇内任何一项都不重叠，另起一簇。
        if (clusterEnd >= 0 && entryStart >= clusterEnd) {
            flushCluster()
        }

        var lane = -1
        for (var j = 0; j < laneEnds.length; ++j) {
            if (laneEnds[j] <= entryStart) {
                lane = j
                break
            }
        }
        if (lane < 0) {
            laneEnds.push(entryEnd)
            lane = laneEnds.length - 1
        } else {
            laneEnds[lane] = entryEnd
        }

        cluster.push({
            entry: visualGeometry ? entry.entry : entry,
            top: visualGeometry ? entry.top : undefined,
            height: visualGeometry ? entry.height : undefined,
            lane: lane,
            laneCount: 1
        })
        clusterEnd = Math.max(clusterEnd, entryEnd)
    }
    flushCluster()
    return result
}

function layoutDayEntries(entries) {
    return layoutEntries(entries, "startMinutes", "endMinutes", false)
}

// 网格必须按最终绘制区间分泳道，不能再按原始分钟区间。
// 极短课程会被扩到最小可点高度，节次模式也会把时间量化成整行；
// 若泳道仍按原时间算，两个“逻辑上不重叠”的块会在屏幕上完全盖住。
function layoutVisualEntries(entries) {
    return layoutEntries(entries, "layoutStart", "layoutEnd", true)
}

// 单双周规则的可读文案。0=每周 1=单周 2=双周，与 ScheduleService::WeekParity 对应。
function parityLabel(parity) {
    if (Number(parity) === 1) {
        return "单周"
    }
    if (Number(parity) === 2) {
        return "双周"
    }
    return ""
}

// 课表项的生效范围文案，例如「第 1-8 周 · 单周」。
// 覆盖整个学期且每周都上的课不需要这句话，返回空串让界面省略。
function weekRangeLabel(weekStart, weekEnd, parity, semesterWeeks) {
    var start = Number(weekStart)
    var end = Number(weekEnd)
    var parityText = parityLabel(parity)
    var spansWholeSemester = start <= 1 && end >= Number(semesterWeeks)
    if (spansWholeSemester && parityText.length === 0) {
        return ""
    }
    var rangeText = start === end ? ("第 " + start + " 周")
                                  : ("第 " + start + "-" + end + " 周")
    if (spansWholeSemester) {
        return parityText
    }
    return parityText.length > 0 ? (rangeText + " · " + parityText) : rangeText
}

// 两个时间区间是否真的相交。半开区间：紧邻的 09:40 结束与 09:40 开始不算相交。
//
// 这个判据在课表里出现的地方不止一处（课程块落在哪几节、哪些条目一节都落不进、
// 服务端的冲突查询），每处各写一遍迟早会有一处把 < 写成 <=，
// 结果就是「相邻的两节课被判成冲突」这类只在边界上才现形、且很难复现的毛病。
function overlaps(aStart, aEnd, bStart, bEnd) {
    return Number(aStart) < Number(bEnd) && Number(aEnd) > Number(bStart)
}
