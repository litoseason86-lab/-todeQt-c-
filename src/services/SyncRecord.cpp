#include "SyncRecord.h"

#include <QJsonArray>
#include <QJsonValue>

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

QVariant valueFromJson(const QJsonValue& value)
{
    if (value.isNull() || value.isUndefined()) {
        return QVariant();
    }
    if (value.isDouble()) {
        // 同步的数字列都是整数（时长、排序号、标记位）。JSON 的数字是双精度，按整数取回；
        // 真有小数时保留小数，不悄悄截断。
        const double number = value.toDouble();
        const qint64 integer = qint64(number);
        return double(integer) == number ? QVariant(integer) : QVariant(number);
    }
    if (value.isBool()) {
        return QVariant(qint64(value.toBool() ? 1 : 0));
    }
    return QVariant(value.toString());
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
    if (!time.isDouble() || !device.isString()) {
        return false;
    }
    version->time = qint64(time.toDouble());
    version->device = device.toString();
    return true;
}

} // namespace

QJsonObject toJson(const SyncBatch& batch)
{
    QJsonArray records;
    for (const SyncRecord& record : batch.records) {
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
        records.append(object);
    }

    QJsonArray settings;
    for (const SyncSettingRecord& setting : batch.settings) {
        QJsonObject object{{QStringLiteral("k"), setting.key}, {QStringLiteral("v"), setting.value}};
        object = versionToJson(setting.version, QStringLiteral("t"), QStringLiteral("d"), object);
        object = versionToJson(setting.base, QStringLiteral("bt"), QStringLiteral("bd"), object);
        settings.append(object);
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

    const int format = object.value(QStringLiteral("format")).toInt(-1);
    if (format < kOldestReadableFormat || format > kFormatVersion) {
        return fail(format > kFormatVersion ? QStringLiteral("同步文件由更新的版本写出，当前版本读不懂")
                                            : QStringLiteral("同步文件格式不认识"));
    }
    if (!object.value(QStringLiteral("device")).isString()
        || object.value(QStringLiteral("device")).toString().isEmpty()) {
        return fail(QStringLiteral("同步文件缺少设备标识"));
    }

    SyncBatch result;
    result.device = object.value(QStringLiteral("device")).toString();
    result.epoch = qint64(object.value(QStringLiteral("epoch")).toDouble());

    for (const QJsonValue& value : object.value(QStringLiteral("records")).toArray()) {
        const QJsonObject item = value.toObject();
        SyncRecord record;
        record.table = item.value(QStringLiteral("t")).toString();
        record.syncId = item.value(QStringLiteral("id")).toString();
        if (record.table.isEmpty() || record.syncId.isEmpty()) {
            return fail(QStringLiteral("同步文件里有缺少表名或身份的记录"));
        }
        record.deleted = item.value(QStringLiteral("del")).toBool(false);
        if (record.deleted) {
            if (!readVersion(item, QStringLiteral("vt"), QStringLiteral("vd"), &record.deleteVersion)) {
                return fail(QStringLiteral("同步文件里的删除记录缺少版本"));
            }
            record.deleteKind = item.value(QStringLiteral("kind")).toString(QStringLiteral("delete"));
            record.mergedInto = item.value(QStringLiteral("into")).toString();
        } else {
            const QJsonObject fields = item.value(QStringLiteral("f")).toObject();
            for (auto it = fields.constBegin(); it != fields.constEnd(); ++it) {
                const QJsonObject field = it.value().toObject();
                SyncFieldValue fieldValue;
                fieldValue.value = valueFromJson(field.value(QStringLiteral("v")));
                if (!readVersion(field, QStringLiteral("t"), QStringLiteral("d"), &fieldValue.version)) {
                    return fail(QStringLiteral("同步文件里的字段缺少版本"));
                }
                readVersion(field, QStringLiteral("bt"), QStringLiteral("bd"), &fieldValue.base);
                record.fields.insert(it.key(), fieldValue);
            }
        }
        result.records.append(record);
    }

    for (const QJsonValue& value : object.value(QStringLiteral("settings")).toArray()) {
        const QJsonObject item = value.toObject();
        SyncSettingRecord setting;
        setting.key = item.value(QStringLiteral("k")).toString();
        setting.value = item.value(QStringLiteral("v")).toString();
        if (setting.key.isEmpty()
            || !readVersion(item, QStringLiteral("t"), QStringLiteral("d"), &setting.version)) {
            return fail(QStringLiteral("同步文件里的设置项不完整"));
        }
        readVersion(item, QStringLiteral("bt"), QStringLiteral("bd"), &setting.base);
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
        // 整数值的浮点数按整数写，与从 JSON 读回的整数一致。
        const double number = value.toDouble();
        const qint64 integer = qint64(number);
        return double(integer) == number ? QStringLiteral("i:") + QString::number(integer)
                                         : QStringLiteral("r:") + QString::number(number, 'g', 17);
    }
    default:
        return QStringLiteral("s:") + value.toString();
    }
}

} // namespace SyncJson
