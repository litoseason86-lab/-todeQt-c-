#include "BackupExecutorProtocol.h"

#include "AppSettings.h"
#include "DatabaseManager.h"

#include <QDir>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>

#include <cmath>

namespace BackupExecutorProtocol {
namespace {

bool integerInRange(const QJsonValue& value, qint64 minimum, qint64 maximum)
{
    if (!value.isDouble()) return false;
    const double number = value.toDouble();
    return std::isfinite(number) && std::floor(number) == number
        && number >= minimum && number <= maximum;
}

bool absolutePath(const QJsonValue& value)
{
    if (!value.isString()) return false;
    const QString path = value.toString();
    return !path.trimmed().isEmpty() && !path.contains(QChar::Null) && QDir::isAbsolutePath(path);
}

QByteArray jsonLine(const QJsonObject& object)
{
    return QJsonDocument(object).toJson(QJsonDocument::Compact) + '\n';
}

std::optional<QJsonObject> readObject(const QByteArray& line)
{
    if (line.size() > kMaxLineBytes) return std::nullopt;
    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(line, &error);
    if (error.error != QJsonParseError::NoError || !document.isObject()) return std::nullopt;
    return document.object();
}

} // namespace

QByteArray encodeRequest(const Request& request)
{
    QJsonObject object{{QStringLiteral("v"), 1}, {QStringLiteral("op"), request.op},
                       {QStringLiteral("budgetMs"), request.budgetMs}};
    if (request.op == QLatin1String("snapshot")) {
        const auto& snapshot = request.snapshot;
        object.insert(QStringLiteral("source"), snapshot.sourceDatabasePath);
        object.insert(QStringLiteral("destination"), snapshot.destinationPath);
        object.insert(QStringLiteral("stagingDirectory"), snapshot.stagingDirectory);
        object.insert(QStringLiteral("settingsPath"), snapshot.effectiveSettingsPath);
        object.insert(QStringLiteral("kind"), snapshot.kind);
        object.insert(QStringLiteral("schema"), snapshot.currentSchemaVersion);
        QJsonObject settings;
        for (auto it = snapshot.settings.constBegin(); it != snapshot.settings.constEnd(); ++it) {
            settings.insert(it.key(), QString::fromLatin1(it.value().toBase64()));
        }
        object.insert(QStringLiteral("settings"), settings);
    } else {
        object.insert(QStringLiteral("source"), request.sourcePath);
        if (request.op == QLatin1String("inspect")) {
            object.insert(QStringLiteral("schema"), request.schema);
        } else if (request.op == QLatin1String("stage")) {
            object.insert(QStringLiteral("destination"), request.destinationPath);
            object.insert(QStringLiteral("maxBytes"), request.maxBytes);
        }
    }
    return jsonLine(object);
}

std::optional<Request> decodeRequest(const QByteArray& line, QString* error)
{
    if (error) error->clear();
    const auto fail = [error](const QString& reason) -> std::optional<Request> {
        if (error) *error = QStringLiteral("备份执行器请求无效：") + reason;
        return std::nullopt;
    };
    const auto parsed = readObject(line);
    if (!parsed) return fail(QStringLiteral("需要限长 JSON 对象"));
    const auto& object = *parsed;
    if (!integerInRange(object.value(QStringLiteral("v")), 1, 1)) {
        return fail(QStringLiteral("协议版本不受支持"));
    }
    Request request;
    request.op = object.value(QStringLiteral("op")).toString();
    if (request.op != QLatin1String("snapshot") && request.op != QLatin1String("inspect")
        && request.op != QLatin1String("stage")) {
        return fail(QStringLiteral("操作不受支持"));
    }
    QSet<QString> fields{QStringLiteral("v"), QStringLiteral("op"), QStringLiteral("source"),
                         QStringLiteral("budgetMs")};
    if (!absolutePath(object.value(QStringLiteral("source")))) return fail(QStringLiteral("源路径无效"));
    if (!integerInRange(object.value(QStringLiteral("budgetMs")), 1,
                        BackupOperationControl::kDefaultBudgetMs)) {
        return fail(QStringLiteral("处理预算无效"));
    }
    request.budgetMs = object.value(QStringLiteral("budgetMs")).toInt();
    request.sourcePath = object.value(QStringLiteral("source")).toString();
    if (request.op != QLatin1String("stage")) {
        fields.insert(QStringLiteral("schema"));
        if (!integerInRange(object.value(QStringLiteral("schema")), 0,
                            DatabaseManager::kCurrentSchemaVersion)) {
            return fail(QStringLiteral("数据库版本无效"));
        }
        request.schema = object.value(QStringLiteral("schema")).toInt();
    }
    if (request.op != QLatin1String("inspect")) {
        fields.insert(QStringLiteral("destination"));
        if (!absolutePath(object.value(QStringLiteral("destination")))) {
            return fail(QStringLiteral("目标路径无效"));
        }
        request.destinationPath = object.value(QStringLiteral("destination")).toString();
    }
    if (request.op == QLatin1String("snapshot")) {
        fields.unite({QStringLiteral("stagingDirectory"), QStringLiteral("settingsPath"),
                      QStringLiteral("kind"), QStringLiteral("settings")});
        if (!absolutePath(object.value(QStringLiteral("stagingDirectory")))
            || !absolutePath(object.value(QStringLiteral("settingsPath")))) {
            return fail(QStringLiteral("暂存或偏好保护路径无效"));
        }
        const QString kind = object.value(QStringLiteral("kind")).toString();
        if (kind != QLatin1String("manual") && kind != QLatin1String("auto")
            && kind != QLatin1String("before-restore") && kind != QLatin1String("before-sync")) {
            return fail(QStringLiteral("快照类型不受支持"));
        }
        if (!object.value(QStringLiteral("settings")).isObject()) return fail(QStringLiteral("偏好表无效"));
        const auto settings = object.value(QStringLiteral("settings")).toObject();
        if (settings.size() > 500) return fail(QStringLiteral("偏好条数超限"));
        BackupOperations::OwnedSettings values;
        for (auto it = settings.constBegin(); it != settings.constEnd(); ++it) {
            if (!AppSettings::isOwnedSettingKey(it.key()) || it.key().contains(QChar::Null)
                || !it.value().isString()) {
                return fail(QStringLiteral("偏好键或编码无效"));
            }
            const QString encoded = it.value().toString();
            if (encoded.size() > ((64 * 1024 + 2) / 3) * 4) return fail(QStringLiteral("偏好值超限"));
            const auto decoded = QByteArray::fromBase64Encoding(encoded.toLatin1(), QByteArray::AbortOnBase64DecodingErrors);
            if (!decoded || decoded.decoded.size() > 64 * 1024
                || QString::fromLatin1(decoded.decoded.toBase64()) != encoded) {
                return fail(QStringLiteral("偏好值不是规范 base64"));
            }
            // 协议只转送原始字节，不解码 QVariant；备份格式的类型白名单仍由原有检查负责。
            values.insert(it.key(), decoded.decoded);
        }
        request.snapshot = {request.sourcePath, request.destinationPath,
                            object.value(QStringLiteral("stagingDirectory")).toString(),
                            object.value(QStringLiteral("settingsPath")).toString(), kind,
                            request.schema, values};
    } else if (request.op == QLatin1String("stage")) {
        fields.insert(QStringLiteral("maxBytes"));
        if (!integerInRange(object.value(QStringLiteral("maxBytes")), 0, BackupOperations::kMaxBackupFileBytes)) {
            return fail(QStringLiteral("复制预算无效"));
        }
        request.maxBytes = object.value(QStringLiteral("maxBytes")).toInteger();
    }
    for (auto it = object.constBegin(); it != object.constEnd(); ++it) {
        if (!fields.contains(it.key())) return fail(QStringLiteral("字段不受支持：") + it.key());
    }
    return request;
}

QByteArray encodeResult(const Result& result)
{
    QJsonObject object{{QStringLiteral("success"), result.operation.success},
                       {QStringLiteral("error"), result.operation.error},
                       {QStringLiteral("committed"), result.operation.committed}};
    if (!result.info.isEmpty()) object.insert(QStringLiteral("info"), QJsonObject::fromVariantMap(result.info));
    return jsonLine(object);
}

std::optional<Result> decodeResult(const QByteArray& line, QString* error)
{
    if (error) error->clear();
    const auto parsed = readObject(line);
    if (!parsed || !parsed->value(QStringLiteral("success")).isBool()
        || !parsed->value(QStringLiteral("error")).isString()
        || !parsed->value(QStringLiteral("committed")).isBool()
        || (parsed->contains(QStringLiteral("info")) && !parsed->value(QStringLiteral("info")).isObject())) {
        if (error) *error = QStringLiteral("备份执行器结果无效");
        return std::nullopt;
    }
    Result result;
    result.operation = {parsed->value(QStringLiteral("success")).toBool(),
                        parsed->value(QStringLiteral("error")).toString(),
                        parsed->value(QStringLiteral("committed")).toBool()};
    result.info = parsed->value(QStringLiteral("info")).toObject().toVariantMap();
    return result;
}

Result runRequest(const Request& request, const BackupOperation& operation)
{
    // 即使绕过解码直接调用，也先验证完整请求，任何拒绝都发生在文件访问之前。
    QString error;
    const auto validated = decodeRequest(encodeRequest(request), &error);
    if (!validated) return {{false, error}, {}};
    const auto control = operation ? operation : std::make_shared<BackupOperationControl>(request.budgetMs);
    if (control->stopped()) return {{false, control->message()}, {}};
    if (request.op == QLatin1String("snapshot")) {
        return {BackupOperations::createSnapshot(validated->snapshot, control), {}};
    }
    if (request.op == QLatin1String("stage")) {
        return {BackupOperations::atomicCopy(validated->sourcePath, validated->destinationPath,
                                             validated->maxBytes, control), {}};
    }
    const auto info = BackupOperations::inspectBackup(validated->sourcePath, validated->schema, control);
    return {{info.value(QStringLiteral("valid")).toBool(), info.value(QStringLiteral("reason")).toString()}, info};
}

QByteArray encodeStop(BackupOperationControl::StopReason reason)
{
    QString name = QStringLiteral("cancelled");
    if (reason == BackupOperationControl::StopReason::TimedOut) name = QStringLiteral("timedout");
    if (reason == BackupOperationControl::StopReason::Shutdown) name = QStringLiteral("shutdown");
    return jsonLine({{QStringLiteral("stop"), name}});
}

std::optional<BackupOperationControl::StopReason> decodeStop(const QByteArray& line)
{
    const auto object = readObject(line);
    if (!object || object->size() != 1) return std::nullopt;
    const QString name = object->value(QStringLiteral("stop")).toString();
    if (name == QLatin1String("cancelled")) return BackupOperationControl::StopReason::Cancelled;
    if (name == QLatin1String("timedout")) return BackupOperationControl::StopReason::TimedOut;
    if (name == QLatin1String("shutdown")) return BackupOperationControl::StopReason::Shutdown;
    return std::nullopt;
}

} // namespace BackupExecutorProtocol
