#include "HeatmapBands.h"

#include <array>

namespace HeatmapBands {
int bandForMinutes(double minutes)
{
    // !(>0) 同时挡住 NaN 和非正值，小数保留，30 秒不能被画成零投入。
    if (!(minutes > 0)) return kNone;
    constexpr std::array<double, kBandCount - 1> thresholds = {60, 150, 300};
    for (int i = 0; i < static_cast<int>(thresholds.size()); ++i) {
        if (minutes < thresholds[static_cast<std::size_t>(i)]) return i;
    }
    return kBandCount - 1;
}
}
