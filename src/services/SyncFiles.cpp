#include "SyncFiles.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QJsonValue>
#include <QRegularExpression>

#include <cmath>

namespace SyncFiles {

namespace {

// JSON 的数字是双精度浮点，2^53 以内的整数能原样表示。毫秒时间戳、纪元、序号都远小于它。
constexpr double kMaxExactInteger = 9007199254740992.0;

bool isNonNegativeInteger(const QJsonValue& value)
{
    if (!value.isDouble()) {
        return false;
    }
    const double number = value.toDouble();
    return number >= 0 && number <= kMaxExactInteger && std::floor(number) == number;
}

// 文件名里的位置：纪元补到 4 位、序号补到 8 位，只为在「访达」和「文件」里按名字排序时顺眼。
// 程序一律按数字比较，位数超出也照样能读。
QString positionText(const SyncPosition& position)
{
    return QStringLiteral("%1-%2")
        .arg(position.epoch, 4, 10, QLatin1Char('0'))
        .arg(position.seq, 8, 10, QLatin1Char('0'));
}

bool matchPosition(const QRegularExpression& pattern, const QString& name, SyncPosition* position)
{
    const QRegularExpressionMatch match = pattern.match(name);
    if (!match.hasMatch()) {
        return false;
    }
    bool epochOk = false;
    bool seqOk = false;
    const qint64 epoch = match.captured(1).toLongLong(&epochOk);
    const qint64 seq = match.captured(2).toLongLong(&seqOk);
    if (!epochOk || !seqOk) {
        return false;
    }
    if (position) {
        *position = {epoch, seq};
    }
    return true;
}

ParseStatus fail(QString* error, ParseStatus status, const QString& message)
{
    if (error) {
        *error = message;
    }
    return status;
}

// 外层：是 JSON 对象、格式版本认识、文件类型对得上。
ParseStatus parseEnvelope(const QByteArray& bytes, const QString& type, QJsonObject* root, QString* error)
{
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(bytes, &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        return fail(error, ParseStatus::Corrupt,
                    QStringLiteral("文件内容不是完整的 JSON（%1）").arg(parseError.errorString()));
    }
    *root = document.object();
    const QJsonValue format = root->value(QStringLiteral("format"));
    if (!isNonNegativeInteger(format)) {
        return fail(error, ParseStatus::Corrupt, QStringLiteral("文件缺少格式版本"));
    }
    if (format.toInteger() > kFormatVersion) {
        return fail(error, ParseStatus::NewerFormat,
                    QStringLiteral("文件由更新版本的番茄Todo 写出（格式 %1），请更新本机的应用")
                        .arg(format.toInteger()));
    }
    if (format.toInteger() != kFormatVersion) {
        return fail(error, ParseStatus::Corrupt, QStringLiteral("文件的格式版本不认识"));
    }
    if (root->value(QStringLiteral("type")).toString() != type) {
        return fail(error, ParseStatus::Corrupt, QStringLiteral("文件类型不对"));
    }
    return ParseStatus::Ok;
}

// 里层的改动批次：批次自己的格式版本更新时同样按「读不懂」处理，而不是当成坏文件跳过。
ParseStatus parseBatch(const QJsonValue& value, const QString& expectedDevice, qint64 expectedEpoch,
                       SyncBatch* batch, QString* error)
{
    if (!value.isObject()) {
        return fail(error, ParseStatus::Corrupt, QStringLiteral("文件里缺少改动内容"));
    }
    const QJsonObject object = value.toObject();
    const QJsonValue format = object.value(QStringLiteral("format"));
    if (isNonNegativeInteger(format) && format.toInteger() > SyncJson::kFormatVersion) {
        return fail(error, ParseStatus::NewerFormat,
                    QStringLiteral("改动由更新版本的番茄Todo 写出（格式 %1），请更新本机的应用")
                        .arg(format.toInteger()));
    }
    QString batchError;
    if (!SyncJson::fromJson(object, batch, &batchError)) {
        return fail(error, ParseStatus::Corrupt, batchError);
    }
    if (batch->device != expectedDevice) {
        return fail(error, ParseStatus::Corrupt, QStringLiteral("写文件的设备和所在目录对不上"));
    }
    if (batch->epoch != expectedEpoch) {
        return fail(error, ParseStatus::Corrupt, QStringLiteral("文件里的纪元和文件名对不上"));
    }
    return ParseStatus::Ok;
}

QJsonObject positionsToJson(const QHash<QString, SyncPosition>& positions)
{
    QJsonObject object;
    for (auto it = positions.cbegin(); it != positions.cend(); ++it) {
        object.insert(it.key(), QJsonObject{{QStringLiteral("epoch"), QJsonValue(it.value().epoch)},
                                            {QStringLiteral("seq"), QJsonValue(it.value().seq)}});
    }
    return object;
}

// 缺这一项按空处理；有但格式不对（键不是设备标识、位置不是非负整数）算坏文件。
bool positionsFromJson(const QJsonValue& value, QHash<QString, SyncPosition>* positions)
{
    positions->clear();
    if (value.isUndefined()) {
        return true;
    }
    if (!value.isObject()) {
        return false;
    }
    const QJsonObject object = value.toObject();
    for (auto it = object.constBegin(); it != object.constEnd(); ++it) {
        const QJsonObject item = it.value().toObject();
        const QJsonValue epoch = item.value(QStringLiteral("epoch"));
        const QJsonValue seq = item.value(QStringLiteral("seq"));
        if (!isDeviceId(it.key()) || !isNonNegativeInteger(epoch) || !isNonNegativeInteger(seq)) {
            return false;
        }
        positions->insert(it.key(), {epoch.toInteger(), seq.toInteger()});
    }
    return true;
}

QByteArray compact(const QJsonObject& object)
{
    return QJsonDocument(object).toJson(QJsonDocument::Compact);
}

} // namespace

QString defaultFolderName()
{
    return QStringLiteral("番茄Todo同步");
}

QString markerFileName()
{
    return QStringLiteral("番茄Todo同步.json");
}

QString devicesDirectory()
{
    return QStringLiteral("devices");
}

QString deviceDirectory(const QString& device)
{
    return devicesDirectory() + QLatin1Char('/') + device;
}

QString changesDirectory(const QString& device)
{
    return deviceDirectory(device) + QStringLiteral("/changes");
}

QString cursorFileName()
{
    return QStringLiteral("cursor.json");
}

QString changeFileName(const SyncPosition& position)
{
    return positionText(position) + QStringLiteral(".json");
}

QString snapshotFileName(const SyncPosition& position)
{
    return QStringLiteral("snapshot-") + positionText(position) + QStringLiteral(".json");
}

bool parseChangeFileName(const QString& name, SyncPosition* position)
{
    // 位数上限 18：qint64 能装下，超出的数字不可能是本应用写的。
    static const QRegularExpression pattern(QStringLiteral("^(\\d{1,18})-(\\d{1,18})\\.json$"));
    SyncPosition parsed;
    // 改动从第 1 批数起，序号 0 不可能出现。
    if (!matchPosition(pattern, name, &parsed) || parsed.seq < 1) {
        return false;
    }
    if (position) {
        *position = parsed;
    }
    return true;
}

bool parseSnapshotFileName(const QString& name, SyncPosition* position)
{
    // 快照可以覆盖到第 0 批：刚建好文件夹、或刚换了纪元时，一批改动都还没写就先写快照。
    static const QRegularExpression pattern(QStringLiteral("^snapshot-(\\d{1,18})-(\\d{1,18})\\.json$"));
    return matchPosition(pattern, name, position);
}

bool isDeviceId(const QString& name)
{
    static const QRegularExpression pattern(QStringLiteral("^[0-9a-f]{32}$"));
    return pattern.match(name).hasMatch();
}

bool isTemporaryFileName(const QString& name)
{
    static const QRegularExpression pattern(QStringLiteral("^.+\\.json\\.[A-Za-z0-9]{6}$"));
    return pattern.match(name).hasMatch();
}

bool isEffectivelyEmpty(const QStringList& entries)
{
    for (const QString& entry : entries) {
        if (!entry.startsWith(QLatin1Char('.'))) {
            return false;
        }
    }
    return true;
}

QString wrongFolderHint(const QString& folderName, const QStringList& entries)
{
    const auto contains = [&entries](const QString& name) { return entries.contains(name); };
    bool looksLikeDeviceFolder = contains(QStringLiteral("changes")) || contains(cursorFileName());
    for (const QString& entry : entries) {
        looksLikeDeviceFolder = looksLikeDeviceFolder || parseSnapshotFileName(entry, nullptr)
            || parseChangeFileName(entry, nullptr) || isDeviceId(entry);
    }
    if (folderName == devicesDirectory() || isDeviceId(folderName) || folderName == QLatin1String("changes")
        || looksLikeDeviceFolder) {
        return QStringLiteral("选中的是同步文件夹里面的子文件夹。请回到上一层，选「%1」这个文件夹。")
            .arg(defaultFolderName());
    }
    if (contains(defaultFolderName())) {
        return QStringLiteral("选中的是「%1」外面的一层。请先点进「%1」，再选它。").arg(defaultFolderName());
    }
    if (contains(devicesDirectory())) {
        return QStringLiteral("这个文件夹里有同步数据，但找不到标记文件「%1」。可能还没从 iCloud 下载完，"
                              "请稍等再试；一直这样的话，请在 Mac 上重新开启同步。")
            .arg(markerFileName());
    }
    return QStringLiteral("这不是番茄Todo 的同步文件夹。请先在 Mac 上开启同步，"
                          "再选 iCloud 云盘里的「%1」文件夹。")
        .arg(defaultFolderName());
}

QByteArray encodeMarker(const Marker& marker)
{
    // 标记文件可能被人打开看，排版成多行；别的文件都是紧凑格式。
    const QJsonObject object{
        {QStringLiteral("format"), kFormatVersion},
        {QStringLiteral("type"), QStringLiteral("marker")},
        {QStringLiteral("app"), QStringLiteral("番茄Todo")},
        {QStringLiteral("folderId"), marker.folderId},
        {QStringLiteral("createdBy"), marker.createdBy},
        {QStringLiteral("createdAt"), marker.createdAt},
    };
    return QJsonDocument(object).toJson(QJsonDocument::Indented);
}

ParseStatus decodeMarker(const QByteArray& bytes, Marker* marker, QString* error)
{
    QJsonObject root;
    const ParseStatus status = parseEnvelope(bytes, QStringLiteral("marker"), &root, error);
    if (status != ParseStatus::Ok) {
        return status;
    }
    Marker parsed;
    parsed.folderId = root.value(QStringLiteral("folderId")).toString();
    parsed.createdBy = root.value(QStringLiteral("createdBy")).toString();
    parsed.createdAt = root.value(QStringLiteral("createdAt")).toString();
    // 文件夹身份会拿去和库里记的比较，太长或带路径分隔符的不可能是本应用写的。
    if (parsed.folderId.isEmpty() || parsed.folderId.size() > 64 || parsed.folderId.contains(QLatin1Char('/'))
        || !isDeviceId(parsed.createdBy)) {
        return fail(error, ParseStatus::Corrupt, QStringLiteral("标记文件缺少文件夹身份或建立它的设备"));
    }
    *marker = parsed;
    return ParseStatus::Ok;
}

QByteArray encodeChanges(const ChangeFile& file)
{
    return compact({
        {QStringLiteral("format"), kFormatVersion},
        {QStringLiteral("type"), QStringLiteral("changes")},
        {QStringLiteral("seq"), QJsonValue(file.seq)},
        {QStringLiteral("writtenAt"), QJsonValue(file.writtenAtMs)},
        {QStringLiteral("batch"), SyncJson::toJson(file.batch)},
    });
}

ParseStatus decodeChanges(const QByteArray& bytes, const QString& expectedDevice, const SyncPosition& expected,
                          ChangeFile* file, QString* error)
{
    QJsonObject root;
    ParseStatus status = parseEnvelope(bytes, QStringLiteral("changes"), &root, error);
    if (status != ParseStatus::Ok) {
        return status;
    }
    const QJsonValue seq = root.value(QStringLiteral("seq"));
    const QJsonValue writtenAt = root.value(QStringLiteral("writtenAt"));
    if (!isNonNegativeInteger(seq) || seq.toInteger() != expected.seq || !isNonNegativeInteger(writtenAt)) {
        return fail(error, ParseStatus::Corrupt, QStringLiteral("文件里的序号和文件名对不上"));
    }
    ChangeFile parsed;
    parsed.seq = seq.toInteger();
    parsed.writtenAtMs = writtenAt.toInteger();
    status = parseBatch(root.value(QStringLiteral("batch")), expectedDevice, expected.epoch, &parsed.batch, error);
    if (status != ParseStatus::Ok) {
        return status;
    }
    *file = parsed;
    return ParseStatus::Ok;
}

QByteArray encodeSnapshot(const SnapshotFile& file)
{
    return compact({
        {QStringLiteral("format"), kFormatVersion},
        {QStringLiteral("type"), QStringLiteral("snapshot")},
        {QStringLiteral("coveredSeq"), QJsonValue(file.coveredSeq)},
        {QStringLiteral("writtenAt"), QJsonValue(file.writtenAtMs)},
        {QStringLiteral("applied"), positionsToJson(file.applied)},
        {QStringLiteral("batch"), SyncJson::toJson(file.batch)},
    });
}

ParseStatus decodeSnapshot(const QByteArray& bytes, const QString& expectedDevice, const SyncPosition& expected,
                           SnapshotFile* file, QString* error)
{
    QJsonObject root;
    ParseStatus status = parseEnvelope(bytes, QStringLiteral("snapshot"), &root, error);
    if (status != ParseStatus::Ok) {
        return status;
    }
    const QJsonValue covered = root.value(QStringLiteral("coveredSeq"));
    const QJsonValue writtenAt = root.value(QStringLiteral("writtenAt"));
    if (!isNonNegativeInteger(covered) || covered.toInteger() != expected.seq
        || !isNonNegativeInteger(writtenAt)) {
        return fail(error, ParseStatus::Corrupt, QStringLiteral("快照覆盖到的序号和文件名对不上"));
    }
    SnapshotFile parsed;
    parsed.coveredSeq = covered.toInteger();
    parsed.writtenAtMs = writtenAt.toInteger();
    if (!positionsFromJson(root.value(QStringLiteral("applied")), &parsed.applied)) {
        return fail(error, ParseStatus::Corrupt, QStringLiteral("快照里记的读取进度格式不对"));
    }
    status = parseBatch(root.value(QStringLiteral("batch")), expectedDevice, expected.epoch, &parsed.batch, error);
    if (status != ParseStatus::Ok) {
        return status;
    }
    *file = parsed;
    return ParseStatus::Ok;
}

QByteArray encodeCursor(const CursorFile& file)
{
    return compact({
        {QStringLiteral("format"), kFormatVersion},
        {QStringLiteral("type"), QStringLiteral("cursor")},
        {QStringLiteral("device"), file.device},
        {QStringLiteral("epoch"), QJsonValue(file.epoch)},
        {QStringLiteral("writtenAt"), QJsonValue(file.writtenAtMs)},
        {QStringLiteral("applied"), positionsToJson(file.applied)},
        {QStringLiteral("requests"), positionsToJson(file.snapshotRequests)},
    });
}

ParseStatus decodeCursor(const QByteArray& bytes, const QString& expectedDevice, CursorFile* file, QString* error)
{
    QJsonObject root;
    const ParseStatus status = parseEnvelope(bytes, QStringLiteral("cursor"), &root, error);
    if (status != ParseStatus::Ok) {
        return status;
    }
    CursorFile parsed;
    parsed.device = root.value(QStringLiteral("device")).toString();
    const QJsonValue epoch = root.value(QStringLiteral("epoch"));
    const QJsonValue writtenAt = root.value(QStringLiteral("writtenAt"));
    if (parsed.device != expectedDevice || !isNonNegativeInteger(epoch) || !isNonNegativeInteger(writtenAt)) {
        return fail(error, ParseStatus::Corrupt, QStringLiteral("游标文件的设备或纪元不对"));
    }
    parsed.epoch = epoch.toInteger();
    parsed.writtenAtMs = writtenAt.toInteger();
    if (!positionsFromJson(root.value(QStringLiteral("applied")), &parsed.applied)
        || !positionsFromJson(root.value(QStringLiteral("requests")), &parsed.snapshotRequests)) {
        return fail(error, ParseStatus::Corrupt, QStringLiteral("游标文件里记的读取进度格式不对"));
    }
    *file = parsed;
    return ParseStatus::Ok;
}

} // namespace SyncFiles
