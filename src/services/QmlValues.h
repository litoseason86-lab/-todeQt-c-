#pragma once

#include <QVariant>

#include <cmath>

// 界面（QML）传进服务的数字一律是浮点数：JavaScript 只有一种数字。
// 字段级更新收到的编号、分钟数、优先级都要是整数，1.5 不能被悄悄截成 1；
// 布尔值和字符串也不能借着 toDouble 的转换混进来。
namespace QmlValues {

inline bool integer(const QVariant& value, int minimum, int maximum, int* result)
{
    const int type = value.typeId();
    if (!value.isValid() || value.isNull() || type == QMetaType::Bool || type == QMetaType::QString) {
        return false;
    }
    bool ok = false;
    const double number = value.toDouble(&ok);
    if (!ok || !std::isfinite(number) || number != std::floor(number) || number < minimum || number > maximum) {
        return false;
    }
    *result = static_cast<int>(number);
    return true;
}

} // namespace QmlValues
