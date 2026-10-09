.pragma library

// 日期与周次换算已迁到 C++ ScheduleWeeks；这里只保留显示格式与泳道排版。

// 服务返回已经校验的 ISO 日期，补本地午夜后只供列头显示，不再判断学期有效性。
function displayDate(iso) {
    return iso ? new Date(iso + "T00:00:00") : null
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

