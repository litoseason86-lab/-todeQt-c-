#pragma once

namespace HeatmapBands {
inline constexpr int kNone = -1;
inline constexpr int kBandCount = 4;
// 只按投入分钟取档；日期状态与颜色不属于该口径。
int bandForMinutes(double minutes);
}
