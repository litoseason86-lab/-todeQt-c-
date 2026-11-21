#include "SyncRecord.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonValue>

#include <cmath>

bool operator<(const SyncVersion& a, const SyncVersion& b)
{
    // 先比逻辑时间，相同再比设备标识：两台设备恰好给出同一逻辑时间时，所有设备仍得出同一个大小关系。
    return a.time != b.time ? a.time < b.time : a.device < b.device;
}

bool operator==(const SyncVersion& a, const SyncVersion& b)
{
    return a.time == b.time && a.device == b.device;
}

SyncVersion SyncRecord::latestVersion() const
{
    if (deleted) {
        return deleteVersion;
    }
    SyncVersion latest;
    for (const SyncFieldValue& field : fields) {
        if (latest < field.version) {
            latest = field.version;
        }
    }
    return latest;
}

namespace SyncJson {

namespace {

// JSON 双精度浮点可精确无损表示的整数上限（2^53），同时远在 qint64 正负范围之内，避免有符号浮点转整型溢出 UB。
constexpr double kMaxExactInteger = 9007199254740992.0;

bool parseExactInt64(const QJsonValue& value, qint64* out, bool nonNegativeOnly = false)
{
    if (!value.isDouble()) {
        return false;
    }
    const double number = value.toDouble();
    if (!std::isfinite(number) || std::trunc(number) != number
        || number < (nonNegativeOnly ? 0.0 : -kMaxExactInteger)
        || number > kMaxExactInteger) {
        return false;
    }
    *out = static_cast<qint64>(number);
    return true;
}

QJsonValue valueToJson(const QVariant& value)
{
    if (!value.isValid() || value.isNull()) {
        return QJsonValue(QJsonValue::Null);
    }
    switch (value.typeId()) {
    case QMetaType::Int:
    case QMetaType::UInt:
    case QMetaType::LongLong:
    case QMetaType::ULongLong:
    case QMetaType::Bool:
        return QJsonValue(value.toLongLong());
    case QMetaType::Double:
        return QJsonValue(value.toDouble());
    default:
        return QJsonValue(value.toString());
    }
}

bool valueFromJson(const QJsonValue& value, QVariant* out)
{
    if (value.isNull() || value.isUndefined()) {
        *out = QVariant();
        return true;
    }
    if (value.isDouble()) {
        // 同步的数字列都是整数（时长、排序号、标记位）。JSON 的数字是双精度，落在 2^53 安全精确范围内的整数按 qint64 取回；
        // 小数或超界有限浮点原样保留为 double 交由上层按单条域校验跳过，绝不强转 qint64 触发溢出 UB。
        const double number = value.toDouble();
        if (!std::isfinite(number)) {
            return false;
        }
        qint64 integer = 0;
        if (parseExactInt64(value, &integer, false)) {
            *out = QVariant(integer);
        } else {
            *out = QVariant(number);
        }
        return true;
    }
    if (value.isBool()) {
        *out = QVariant(qint64(value.toBool() ? 1 : 0));
        return true;
    }
    if (value.isString()) {
        *out = QVariant(value.toString());
        return true;
    }
    // 数组或对象等非标量类型不得静默调用 toString() 退化为空串抹掉文本列。
    return false;
}

QJsonObject versionToJson(const SyncVersion& version, const QString& timeKey, const QString& deviceKey,
                          QJsonObject object)
{
    object.insert(timeKey, QJsonValue(version.time));
    object.insert(deviceKey, version.device);
    return object;
}

bool readVersion(const QJsonObject& object, const QString& timeKey, const QString& deviceKey,
                 SyncVersion* version)
{
    const QJsonValue time = object.value(timeKey);
    const QJsonValue device = object.value(deviceKey);
    qint64 parsedTime = 0;
    if (!parseExactInt64(time, &parsedTime, true) || !device.isString()) {
        return false;
    }
    version->time = parsedTime;
    version->device = device.toString();
    return true;
}

} // namespace

QJsonObject recordToJson(const SyncRecord& record)
{
    QJsonObject object{{QStringLiteral("t"), record.table}, {QStringLiteral("id"), record.syncId}};
    if (record.deleted) {
        object.insert(QStringLiteral("del"), true);
        object = versionToJson(record.deleteVersion, QStringLiteral("vt"), QStringLiteral("vd"), object);
        object.insert(QStringLiteral("kind"), record.deleteKind);
        if (!record.mergedInto.isEmpty()) {
            object.insert(QStringLiteral("into"), record.mergedInto);
        }
    } else {
        QJsonObject fields;
        for (auto it = record.fields.cbegin(); it != record.fields.cend(); ++it) {
            QJsonObject field{{QStringLiteral("v"), valueToJson(it.value().value)}};
            field = versionToJson(it.value().version, QStringLiteral("t"), QStringLiteral("d"), field);
            field = versionToJson(it.value().base, QStringLiteral("bt"), QStringLiteral("bd"), field);
            fields.insert(it.key(), field);
        }
        object.insert(QStringLiteral("f"), fields);
    }
    return object;
}

QJsonObject settingToJson(const SyncSettingRecord& setting)
{
    QJsonObject object{{QStringLiteral("k"), setting.key}, {QStringLiteral("v"), setting.value}};
    object = versionToJson(setting.version, QStringLiteral("t"), QStringLiteral("d"), object);
    object = versionToJson(setting.base, QStringLiteral("bt"), QStringLiteral("bd"), object);
    return object;
}

qint64 compactJsonBytes(const SyncRecord& record)
{
    return QJsonDocument(recordToJson(record)).toJson(QJsonDocument::Compact).size();
}

qint64 compactJsonBytes(const SyncSettingRecord& setting)
{
    return QJsonDocument(settingToJson(setting)).toJson(QJsonDocument::Compact).size();
}

QJsonObject toJson(const SyncBatch& batch)
{
    QJsonArray records;
    for (const SyncRecord& record : batch.records) {
        records.append(recordToJson(record));
    }

    QJsonArray settings;
    for (const SyncSettingRecord& setting : batch.settings) {
        settings.append(settingToJson(setting));
    }

    return {
        {QStringLiteral("format"), kFormatVersion},
        {QStringLiteral("device"), batch.device},
        {QStringLiteral("epoch"), QJsonValue(batch.epoch)},
        {QStringLiteral("records"), records},
        {QStringLiteral("settings"), settings},
    };
}

bool fromJson(const QJsonObject& object, SyncBatch* batch, QString* error)
{
    const auto fail = [error](const QString& message) {
        if (error) {
            *error = message;
        }
        return false;
    };

    qint64 format = -1;
    if (!parseExactInt64(object.value(QStringLiteral("format")), &format, true)
        || format < kOldestReadableFormat || format > kFormatVersion) {
        return fail(format > kFormatVersion ? QStringLiteral("同步文件由更新的版本写出，当前版本读不懂")
                                            : QStringLiteral("同步文件格式不认识"));
    }
    if (!object.value(QStringLiteral("device")).isString()
        || object.value(QStringLiteral("device")).toString().isEmpty()) {
        return fail(QStringLiteral("同步文件缺少设备标识"));
    }

    // 从首版写出代码（f2bedea）起，两个集合就始终以数组写出，合法旧文件也必须具备它们。
    // 缺失或类型错误不能按空集合处理，否则整体替换会把本机数据误当成快照中已删除的内容。
    if (!object.value(QStringLiteral("records")).isArray()) {
        return fail(QStringLiteral("同步文件缺少记录集合或记录集合不是数组"));
    }
    if (!object.value(QStringLiteral("settings")).isArray()) {
        return fail(QStringLiteral("同步文件缺少设置集合或设置集合不是数组"));
    }

    SyncBatch result;
    result.device = object.value(QStringLiteral("device")).toString();
    const QJsonValue epochValue = object.value(QStringLiteral("epoch"));
    if (!epochValue.isUndefined() && !parseExactInt64(epochValue, &result.epoch, true)) {
        return fail(QStringLiteral("同步文件里的纪元不合法"));
    }

    for (const QJsonValue& value : object.value(QStringLiteral("records")).toArray()) {
        if (!value.isObject()) {
            return fail(QStringLiteral("同步文件里的记录项不是对象"));
        }
        const QJsonObject item = value.toObject();
        SyncRecord record;
        if (!item.value(QStringLiteral("t")).isString() || !item.value(QStringLiteral("id")).isString()) {
            return fail(QStringLiteral("同步文件里有缺少表名或身份的记录"));
        }
        record.table = item.value(QStringLiteral("t")).toString();
        record.syncId = item.value(QStringLiteral("id")).toString();
        if (record.table.isEmpty() || record.syncId.isEmpty()) {
            return fail(QStringLiteral("同步文件里有缺少表名或身份的记录"));
        }
        const QJsonValue delValue = item.value(QStringLiteral("del"));
        if (!delValue.isUndefined() && !delValue.isBool()) {
            return fail(QStringLiteral("同步文件里的删除标记不合法"));
        }
        record.deleted = delValue.toBool(false);
        if (record.deleted) {
            if (!readVersion(item, QStringLiteral("vt"), QStringLiteral("vd"), &record.deleteVersion)) {
                return fail(QStringLiteral("同步文件里的删除记录缺少版本"));
            }
            record.deleteKind = item.value(QStringLiteral("kind")).toString(QStringLiteral("delete"));
            record.mergedInto = item.value(QStringLiteral("into")).toString();
        } else {
            const QJsonValue fieldsValue = item.value(QStringLiteral("f"));
            if (!fieldsValue.isUndefined() && !fieldsValue.isObject()) {
                return fail(QStringLiteral("同步文件里的字段集合不是对象"));
            }
            const QJsonObject fields = fieldsValue.toObject();
            for (auto it = fields.constBegin(); it != fields.constEnd(); ++it) {
                if (!it.value().isObject()) {
                    return fail(QStringLiteral("同步文件里的字段项不是对象"));
                }
                const QJsonObject field = it.value().toObject();
                SyncFieldValue fieldValue;
                if (!valueFromJson(field.value(QStringLiteral("v")), &fieldValue.value)) {
                    return fail(QStringLiteral("同步文件里的字段值类型不合法"));
                }
                if (!readVersion(field, QStringLiteral("t"), QStringLiteral("d"), &fieldValue.version)) {
                    return fail(QStringLiteral("同步文件里的字段缺少版本"));
                }
                if ((!field.value(QStringLiteral("bt")).isUndefined() || !field.value(QStringLiteral("bd")).isUndefined())
                    && !readVersion(field, QStringLiteral("bt"), QStringLiteral("bd"), &fieldValue.base)) {
                    return fail(QStringLiteral("同步文件里的字段基准版本不合法"));
                }
                record.fields.insert(it.key(), fieldValue);
            }
        }
        result.records.append(record);
    }

    for (const QJsonValue& value : object.value(QStringLiteral("settings")).toArray()) {
        if (!value.isObject()) {
            return fail(QStringLiteral("同步文件里的设置项不是对象"));
        }
        const QJsonObject item = value.toObject();
        if (!item.value(QStringLiteral("k")).isString() || !item.value(QStringLiteral("v")).isString()) {
            return fail(QStringLiteral("同步文件里的设置项不完整"));
        }
        SyncSettingRecord setting;
        setting.key = item.value(QStringLiteral("k")).toString();
        setting.value = item.value(QStringLiteral("v")).toString();
        if (setting.key.isEmpty()
            || !readVersion(item, QStringLiteral("t"), QStringLiteral("d"), &setting.version)) {
            return fail(QStringLiteral("同步文件里的设置项不完整"));
        }
        if ((!item.value(QStringLiteral("bt")).isUndefined() || !item.value(QStringLiteral("bd")).isUndefined())
            && !readVersion(item, QStringLiteral("bt"), QStringLiteral("bd"), &setting.base)) {
            return fail(QStringLiteral("同步文件里的设置项基准版本不合法"));
        }
        result.settings.append(setting);
    }

    *batch = result;
    return true;
}

QString canonicalValue(const QVariant& value)
{
    if (!value.isValid() || value.isNull()) {
        return QStringLiteral("n");
    }
    switch (value.typeId()) {
    case QMetaType::Int:
    case QMetaType::UInt:
    case QMetaType::LongLong:
    case QMetaType::ULongLong:
    case QMetaType::Bool:
        return QStringLiteral("i:") + QString::number(value.toLongLong());
    case QMetaType::Double: {
        // 精确安全整数范围内的浮点按整数写，超界或带小数的原样格式化，避免超界 double 强转 qint64 触发 UB。
        const double number = value.toDouble();
        if (std::isfinite(number) && std::trunc(number) == number
            && number >= -kMaxExactInteger && number <= kMaxExactInteger) {
            return QStringLiteral("i:") + QString::number(static_cast<qint64>(number));
        }
        return QStringLiteral("r:") + QString::number(number, 'g', 17);
    }
    default:
        return QStringLiteral("s:") + value.toString();
    }
}

} // namespace SyncJson
