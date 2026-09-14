.pragma library

// 热力取档：分钟数 → 档位。
//
// 专注历史月历与目标详情热力图都调用这同一个函数，不要在哪一页另写一份阈值——两份必然漂移。
// 规则见 docs/业务规则.md「热力取档与专注历史月历的投入条」。
//
// 共用的是映射，不是输入：目标详情喂的是「该目标」当天的投入，专注历史喂的是
// 当天全部投入，同一天在两页落进不同档是正确结果。要守的只是「同一个分钟数
// 在哪一页都落进同一档」。
//
// 这里只认分钟数，不认颜色（颜色在 Theme.heatmapBandColors），也不认日期——
// 未来、今日、本月之外由页面按逻辑今日逐格判断，不属于投入量刻度。

var NONE = -1
var BAND_COUNT = 4
// 正投入按绝对分钟数分四档：< 60 / 60–149 / 150–299 / ≥ 300。
// 不按「占当月最大值的比例」分：那会让整月都学得少的月份照样染出最深的一天。
var THRESHOLDS = [60, 150, 300]

// 返回 NONE 表示零投入，否则 0..BAND_COUNT-1。
//
// minutes 允许是小数，调用方传 seconds / 60 即可，不要先取整：
// 30 秒是有投入（第 1 档），取整成 0 会被画成零投入，而同一格的时长文字却显示有记录；
// 3599 秒是 59.98 分钟，仍在第 1 档。
// NaN、null、undefined 与负数一律按零投入——写成 `minutes <= 0` 挡不住 NaN，
// NaN 与任何数比较都是假，会一路漏到最深那档。
function bandForMinutes(minutes) {
    var value = Number(minutes)
    if (!(value > 0))
        return NONE
    for (var i = 0; i < THRESHOLDS.length; ++i) {
        if (value < THRESHOLDS[i])
            return i
    }
    return THRESHOLDS.length
}
