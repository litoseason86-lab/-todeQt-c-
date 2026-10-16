#include "SyncController.h"

#include "AppSettings.h"
#include "DatabaseManager.h"
#include "SyncFiles.h"
#include "ScheduleService.h"
#include "SyncSchema.h"
#include "SyncStore.h"
#include "SyncWorker.h"
#include "SyncNotifier.h"
#include "SyncedSettings.h"

#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPointer>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSettings>
#include <QTimer>
#include <QUuid>
#include <QtConcurrent/QtConcurrentRun>

#include <utility>

namespace {

// 这一组不在备份范围内（见 AppSettings::ownedSettingGroups），恢复备份不会改掉同步开关和书签。
const auto kEnabledKey = QStringLiteral("sync/enabled");
const auto kBookmarkKey = QStringLiteral("sync/bookmark");
const auto kFolderPathKey = QStringLiteral("sync/folderPath");

bool isProblem(SyncEngine::Status status)
{
    switch (status) {
    case SyncEngine::Status::FolderUnavailable:
    case SyncEngine::Status::WrongFolder:
    case SyncEngine::Status::FolderMissing:
    case SyncEngine::Status::NoSpace:
    case SyncEngine::Status::UploadFailed:
    case SyncEngine::Status::NewerVersion:
    case SyncEngine::Status::BackupFailed:
    case SyncEngine::Status::Error:
        return true;
    default:
        return false;
    }
}

// 日志条目的种类，给人看的说法。
QString logKindLabel(const QString& kind)
{
    if (kind == QLatin1String("edit")) {
        return QStringLiteral("同时修改");
    }
    if (kind == QLatin1String("delete")) {
        return QStringLiteral("删除优先");
    }
    if (kind == QLatin1String("removed")) {
        return QStringLiteral("已删除");
    }
    if (kind == QLatin1String("merge")) {
        return QStringLiteral("科目合并");
    }
    if (kind == QLatin1String("skipped")) {
        return QStringLiteral("没能应用");
    }
    if (kind == QLatin1String("file")) {
        return QStringLiteral("文件问题");
    }
    return kind;
}

// 选择器给的是完整路径（…/Mobile Documents/com~apple~CloudDocs/番茄Todo同步），设置页一行放不下，
// 截断之后看不出是哪个文件夹。iCloud 云盘里的换成「iCloud 云盘/…」，别处的原样显示。
QString friendlyFolderPath(const QString& path)
{
    const QString iCloudDrive = QStringLiteral("com~apple~CloudDocs");
    const qsizetype at = path.indexOf(iCloudDrive);
    return at < 0 ? path : QStringLiteral("iCloud 云盘") + path.mid(at + iCloudDrive.size());
}

QString deviceLabel(bool here)
{
    return here ? QStringLiteral("这台设备") : QStringLiteral("另一台设备");
}

QString logValueSummary(const QString& value)
{
    // 摘要有界，原文另放在日志条目的 lostValue / keptValue，阶段 3 的复制按钮直接取原文。
    constexpr qsizetype limit = 40;
    qsizetype end = 0;
    qsizetype count = 0;
    // UTF-16 中一个表情可能占两个单元，不能把摘要截在代理对中间。
    while (end < value.size() && count < limit) {
        const bool pair = value.at(end).isHighSurrogate() && end + 1 < value.size()
            && value.at(end + 1).isLowSurrogate();
        end += pair ? 2 : 1;
        ++count;
    }
    return end == value.size() ? value
        : value.left(end) + QStringLiteral("…（共 %1 字）").arg(value.toUcs4().size());
}

// 「上次同步」的时刻：今天的只写几点几分，更早的带上日期。
QString syncedAtText(const QDateTime& time)
{
    if (!time.isValid()) {
        return QString();
    }
    return time.date() == QDate::currentDate() ? time.toString(QStringLiteral("HH:mm"))
                                                : time.toString(QStringLiteral("M月d日 HH:mm"));
}

// 恢复日志文件预算上限：16 KiB
constexpr qint64 kMaxJournalSize = 16 * 1024;

QString journalFilePath(const QString& dbPath)
{
    if (dbPath.isEmpty()) {
        return QString();
    }
    return dbPath + QStringLiteral(".sync-restore.json");
}

} // namespace

SyncController::JournalReadResult SyncController::readJournalFile(
    const QString& journalPath, const QString& expectedDbPath,
    JournalData* outData, QString* errorMessage)
{
    QFileInfo fi(journalPath);
    // 拒绝符号链接（必须在 exists 之前判断，避免悬空链接被当成不存在）
    if (fi.isSymLink()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志文件是符号链接：%1").arg(journalPath);
        }
        return JournalReadResult::Corrupt;
    }
    if (!fi.exists()) {
        return JournalReadResult::NotFound;
    }
    // 拒绝非普通文件（如目录、套接字等）
    if (!fi.isFile()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志文件不是普通文件：%1").arg(journalPath);
        }
        return JournalReadResult::Corrupt;
    }

    QFile file(journalPath);
    if (!file.open(QIODevice::ReadOnly)) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("无法读取恢复日志文件：%1").arg(file.errorString());
        }
        return JournalReadResult::Corrupt;
    }

    // 读取最多 16 KiB + 1 字节，超限必须拒绝
    const QByteArray content = file.read(kMaxJournalSize + 1);
    if (content.size() > kMaxJournalSize) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志文件大小超过 16 KiB 限制");
        }
        return JournalReadResult::Corrupt;
    }
    if (file.error() != QFile::NoError) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("读取恢复日志文件出错：%1").arg(file.errorString());
        }
        return JournalReadResult::Corrupt;
    }

    QJsonParseError parseError;
    const QJsonDocument doc = QJsonDocument::fromJson(content, &parseError);
    if (parseError.error != QJsonParseError::NoError || !doc.isObject()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志解析失败：%1").arg(parseError.errorString());
        }
        return JournalReadResult::Corrupt;
    }

    const QJsonObject obj = doc.object();

    // v 必须数值精确等于 1，拒绝小数截断或版本不匹配
    const QJsonValue vVal = obj.value(QStringLiteral("v"));
    if (!vVal.isDouble() || vVal.toDouble() != 1.0 || vVal.toInteger() != 1) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志版本不支持或非整数1");
        }
        return JournalReadResult::Corrupt;
    }

    static const QRegularExpression s_epochRegex(QStringLiteral(R"(\A[0-9]+\z)"));
    static const QRegularExpression s_hex32Regex(QStringLiteral(R"(\A[0-9a-fA-F]{32}\z)"));
    static const QRegularExpression s_uuidRegex(QStringLiteral(R"(\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z)"));

    // operationId 必须为有效 UUID
    const QJsonValue opVal = obj.value(QStringLiteral("operationId"));
    if (!opVal.isString()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志缺少 operationId");
        }
        return JournalReadResult::Corrupt;
    }
    const QString opId = opVal.toString();
    if (!s_uuidRegex.match(opId).hasMatch() || QUuid::fromString(opId).isNull()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志缺少有效 UUID 操作标识");
        }
        return JournalReadResult::Corrupt;
    }

    // phase 仅允许 prepared / installed
    const QJsonValue phaseVal = obj.value(QStringLiteral("phase"));
    if (!phaseVal.isString()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志缺少 phase 字符串");
        }
        return JournalReadResult::Corrupt;
    }
    const QString phase = phaseVal.toString();
    if (phase != QLatin1String("prepared") && phase != QLatin1String("installed")) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志状态未知：%1").arg(phase);
        }
        return JournalReadResult::Corrupt;
    }

    // epoch 只接受非负十进制字符串，拒绝 JSON double，用正则 \A[0-9]+\z 后 toLongLong 检范围
    const QJsonValue epochVal = obj.value(QStringLiteral("epoch"));
    if (!epochVal.isString()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志中 epoch 必须为十进制整数字符串");
        }
        return JournalReadResult::Corrupt;
    }
    const QString epochStr = epochVal.toString();
    if (!s_epochRegex.match(epochStr).hasMatch()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志中 epoch 格式无效，必须为纯数字字符串");
        }
        return JournalReadResult::Corrupt;
    }
    bool epochOk = false;
    const qint64 epoch = epochStr.toLongLong(&epochOk);
    if (!epochOk || epoch < 0) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志中 epoch 超出合法范围");
        }
        return JournalReadResult::Corrupt;
    }

    // deviceId 必须是正常 32 位十六进制非空字符串
    const QJsonValue devVal = obj.value(QStringLiteral("deviceId"));
    if (!devVal.isString()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志缺少有效的 deviceId");
        }
        return JournalReadResult::Corrupt;
    }
    const QString deviceId = devVal.toString();
    if (!s_hex32Regex.match(deviceId).hasMatch()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志中 deviceId 不是合法的 32 位十六进制字符串");
        }
        return JournalReadResult::Corrupt;
    }

    // folderId 必须是显式字符串（空字符串合法），缺失/null 不属于合法空值
    if (!obj.contains(QStringLiteral("folderId"))) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志缺少 folderId 字段");
        }
        return JournalReadResult::Corrupt;
    }
    const QJsonValue folderVal = obj.value(QStringLiteral("folderId"));
    if (!folderVal.isString()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志中 folderId 必须为字符串类型");
        }
        return JournalReadResult::Corrupt;
    }
    const QString folderId = folderVal.toString();
    const bool isFolderUuid = !folderId.isEmpty() && s_uuidRegex.match(folderId).hasMatch() && !QUuid::fromString(folderId).isNull();
    const bool isFolderHex32 = !folderId.isEmpty() && s_hex32Regex.match(folderId).hasMatch();
    if (!folderId.isEmpty() && !isFolderUuid && !isFolderHex32) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志中 folderId 格式无效，必须为空、合法 UUID 或 32 位十六进制");
        }
        return JournalReadResult::Corrupt;
    }

    // dbPath 必须存在、是字符串且为绝对路径，且绝对路径等于当前DB
    const QJsonValue dbPathVal = obj.value(QStringLiteral("dbPath"));
    if (!dbPathVal.isString()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志缺少有效的 dbPath 字符串");
        }
        return JournalReadResult::Corrupt;
    }
    const QString dbPath = dbPathVal.toString();
    if (dbPath.isEmpty() || !QDir::isAbsolutePath(dbPath) || expectedDbPath.isEmpty()
        || QFileInfo(expectedDbPath).absoluteFilePath() != QFileInfo(dbPath).absoluteFilePath()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志数据库路径不是绝对路径或与当前数据库不匹配");
        }
        return JournalReadResult::Corrupt;
    }

    if (outData) {
        outData->v = 1;
        outData->operationId = opId;
        outData->epoch = epoch;
        outData->deviceId = deviceId;
        outData->folderId = folderId;
        outData->phase = phase;
        outData->dbPath = dbPath;
    }
    return JournalReadResult::Success;
}

bool SyncController::writeJournalFile(const QString& journalPath, const JournalData& data, QString* errorMessage)
{
    if (journalPath.isEmpty()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志路径为空");
        }
        return false;
    }

    QFileInfo fi(journalPath);
    if (fi.isSymLink() || (fi.exists() && !fi.isFile())) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志路径已存在符号链接或非普通文件：%1").arg(journalPath);
        }
        return false;
    }

    QJsonObject obj;
    obj.insert(QStringLiteral("v"), data.v);
    obj.insert(QStringLiteral("operationId"), data.operationId);
    obj.insert(QStringLiteral("epoch"), QString::number(data.epoch));
    obj.insert(QStringLiteral("deviceId"), data.deviceId);
    obj.insert(QStringLiteral("folderId"), data.folderId);
    obj.insert(QStringLiteral("phase"), data.phase);
    obj.insert(QStringLiteral("dbPath"), data.dbPath);

    const QByteArray json = QJsonDocument(obj).toJson(QJsonDocument::Compact);

    QSaveFile saveFile(journalPath);
    saveFile.setDirectWriteFallback(false);
    if (!saveFile.open(QIODevice::WriteOnly)) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("无法打开恢复日志文件进行写入：%1").arg(saveFile.errorString());
        }
        return false;
    }
    if (saveFile.write(json) != json.size()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("写入恢复日志内容不完整");
        }
        saveFile.cancelWriting();
        return false;
    }
    if (!saveFile.commit()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("提交恢复日志文件失败：%1").arg(saveFile.errorString());
        }
        return false;
    }
    return true;
}

bool SyncController::deleteJournalFileSafely(const QString& journalPath, const QString& expectedDbPath,
                                            const QString& expectedOperationId, QString* errorMessage)
{
    if (journalPath.isEmpty() || expectedDbPath.isEmpty()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("日志路径或数据库路径为空");
        }
        return false;
    }
    static const QRegularExpression s_uuidRegex(QStringLiteral(R"(\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z)"));
    if (expectedOperationId.isEmpty() || !s_uuidRegex.match(expectedOperationId).hasMatch() || QUuid::fromString(expectedOperationId).isNull()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("预期恢复操作标识为空或非有效 UUID");
        }
        return false;
    }
    const QString expectedJournal = journalFilePath(expectedDbPath);
    if (QFileInfo(journalPath).absoluteFilePath() != QFileInfo(expectedJournal).absoluteFilePath()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("删除路径与当前数据库绑定的日志路径不匹配");
        }
        return false;
    }
    QFileInfo fi(journalPath);
    if (fi.isSymLink()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("拒绝删除符号链接：%1").arg(journalPath);
        }
        return false;
    }
    if (!fi.exists()) {
        return true;
    }
    if (!fi.isFile()) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("拒绝删除非普通文件：%1").arg(journalPath);
        }
        return false;
    }

    // 清理前读取校验当前有效日志且 operationId 匹配本次操作，不能删除被替换的未知普通文件
    JournalData currentData;
    QString readErr;
    const JournalReadResult readRes = readJournalFile(journalPath, expectedDbPath, &currentData, &readErr);
    if (readRes != JournalReadResult::Success) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("删除前校验恢复日志失败，拒绝删除未知或损坏文件：%1").arg(readErr);
        }
        return false;
    }
    if (currentData.operationId != expectedOperationId) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("恢复日志 operationId (%1) 与期望 (%2) 不匹配，拒绝删除")
                .arg(currentData.operationId, expectedOperationId);
        }
        return false;
    }

    if (!QFile::remove(journalPath)) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("删除恢复日志失败：%1").arg(journalPath);
        }
        return false;
    }
    return true;
}

SyncController::SyncController(Platform platform, QObject* parent)
    : QObject(parent)
    , m_platform(std::move(platform))
{
    m_enabled = QSettings().value(kEnabledKey, false).toBool();
    // 本机改了跟着同步的设置（SyncSchema::syncedSettingKeys 与每一天的今日目标），记进库等着发出。
    // 同步写回对方的改动时这些信号也会发出，那时值与库里记下的相同，不会再记一次。
    AppSettings* settings = AppSettings::instance();
    for (const auto signal : {&AppSettings::dayStartHourChanged, &AppSettings::workMinutesChanged,
                              &AppSettings::breakMinutesChanged, &AppSettings::longBreakEnabledChanged,
                              &AppSettings::longBreakMinutesChanged, &AppSettings::longBreakIntervalChanged,
                              &AppSettings::freeTimerWarningHoursChanged, &AppSettings::nicknameChanged,
                              &AppSettings::semesterStartDateChanged, &AppSettings::semesterWeeksChanged,
                              &AppSettings::dailyFocusGoalChanged}) {
        connect(settings, signal, this, &SyncController::recordSettings);
    }
    connect(ScheduleService::instance(), &ScheduleService::periodsChanged, this, &SyncController::recordSettings);
}

SyncController::~SyncController()
{
    // 引擎的析构会等工作线程把手头的文件操作做完（最多几秒）；先于其它成员析构，
    // 免得工作线程回调时控制器已经只剩一半。
    m_engine.reset();
}

void SyncController::setSafetyBackup(std::function<bool(QString* error)> backup)
{
    m_safetyBackup = std::move(backup);
}

void SyncController::initialize()
{
    m_initialized = true;
    m_journalCorrupted = false;

    // 检查恢复日志（必须先于 reconcileSettings 和 startEngine 检查）
    const QString dbPath = currentDatabasePath();
    const QString journalPath = journalFilePath(dbPath);
    if (!journalPath.isEmpty()) {
        JournalData journal;
        QString err;
        const JournalReadResult res = readJournalFile(journalPath, dbPath, &journal, &err);
        if (res == JournalReadResult::Corrupt) {
            m_journalCorrupted = true;
            m_restoreError = err.isEmpty()
                ? QStringLiteral("恢复日志文件损坏或存在未知文件，同步已暂停以保护数据。")
                : err;
            refreshLog();
            emit statusChanged();
            return;
        }
        if (res == JournalReadResult::Success) {
            if (journal.phase == QLatin1String("prepared")) {
                m_restoreRetry.phase = QStringLiteral("prepared");
                m_restoreRetry.epoch = journal.epoch;
                m_restoreRetry.deviceId = journal.deviceId;
                m_restoreRetry.folderId = journal.folderId;
                m_restoreRetry.operationId = journal.operationId;
                m_restoreError = QStringLiteral("检测到未完成的备份恢复意图，同步已暂停以保护数据。请重新执行备份恢复。");
                refreshLog();
                emit statusChanged();
                return;
            } else if (journal.phase == QLatin1String("installed")) {
                SyncStore store;
                m_restoreRetry.phase = QStringLiteral("installed");
                m_restoreRetry.needsEpoch = true;
                m_restoreRetry.needsFolder = (store.folderId() != journal.folderId);
                m_restoreRetry.needsSettings = true;
                m_restoreRetry.needsJournalDelete = true;
                m_restoreRetry.epoch = journal.epoch;
                m_restoreRetry.deviceId = journal.deviceId;
                m_restoreRetry.folderId = journal.folderId;
                m_restoreRetry.operationId = journal.operationId;
                m_restoreError = QStringLiteral("备份已恢复但同步收尾未完成，同步已暂停以保护数据。点击立即同步继续。");
                refreshLog();
                emit statusChanged();
                return;
            }
        }
    }

    if (!reconcileSettings()) {
        qWarning() << "Initial settings reconciliation failed:" << m_restoreError;
    }
    refreshLog();
    SyncStore store;
    m_knownEpoch = store.epoch();
    m_knownFolderId = store.folderId();
    // 上次退出时开着同步：接着同步。iPad 还没选过文件夹时建不出引擎，等你去选。
    if (m_enabled) {
        startEngine();
    }
    emit statusChanged();
}

void SyncController::setForeground(bool foreground)
{
    if (m_engine) {
        m_engine->setForeground(foreground);
    }
}

void SyncController::setApplicationState(Qt::ApplicationState state)
{
    // 进了后台之后，系统随时可能把应用挂起：这时才立即写出攒下的改动、向系统要一点后台时间。
    // 从应用切换器里直接划掉也不会丢改动：它们留在本机的待发送里，下次启动照常写出。
    setForeground(state != Qt::ApplicationSuspended && state != Qt::ApplicationHidden);
}

QString SyncController::currentDatabasePath() const
{
    if (!DatabaseManager::instance()->isOpen()) {
        return QString();
    }
    const QString name = DatabaseManager::instance()->database().databaseName();
    return QFileInfo(name).absoluteFilePath();
}

bool SyncController::prepareForRestore(QString* error)
{
    // 同一次恢复只记一次：记下的必须是恢复之前的样子。
    if (m_restore.pending || !DatabaseManager::instance()->isOpen()) {
        if (error) {
            *error = m_restore.pending
                ? QStringLiteral("另一项恢复正在进行中")
                : QStringLiteral("数据库未打开");
        }
        return false;
    }

    const QString dbPath = currentDatabasePath();
    const QString journalPath = journalFilePath(dbPath);

    JournalData existingJournal;
    QString readErr;
    const JournalReadResult readRes = readJournalFile(journalPath, dbPath, &existingJournal, &readErr);
    if (readRes == JournalReadResult::Corrupt) {
        if (error) {
            *error = readErr;
        }
        m_journalCorrupted = true;
        m_restoreError = readErr;
        if (m_engine) {
            m_engine->stop();
        }
        emit statusChanged();
        return false;
    }

    if (readRes == JournalReadResult::Success) {
        m_previousJournal = existingJournal;
    } else {
        m_previousJournal = std::nullopt;
    }

    SyncStore store;
    QString targetDevice;
    QString targetFolder;
    qint64 targetEpoch = 0;

    if (m_previousJournal.has_value()) {
        targetDevice = m_previousJournal->deviceId;
        targetFolder = m_previousJournal->folderId;
        targetEpoch = std::max(store.epoch(), m_previousJournal->epoch);
    } else if (m_restoreRetry.hasPending()) {
        targetDevice = m_restoreRetry.deviceId;
        targetFolder = m_restoreRetry.folderId;
        targetEpoch = std::max(store.epoch(), m_restoreRetry.epoch);
    } else {
        targetEpoch = store.epoch();
        targetDevice = store.deviceId();
        targetFolder = store.folderId();
    }

    const QString operationId = QUuid::createUuid().toString(QUuid::WithoutBraces);

    JournalData newJournal;
    newJournal.v = 1;
    newJournal.operationId = operationId;
    newJournal.epoch = targetEpoch;
    newJournal.deviceId = targetDevice;
    newJournal.folderId = targetFolder;
    newJournal.phase = QStringLiteral("prepared");
    newJournal.dbPath = dbPath;

    QString writeErr;
    if (!writeJournalFile(journalPath, newJournal, &writeErr)) {
        if (error) {
            *error = writeErr;
        }
        m_restoreError = writeErr;
        if (m_engine) {
            m_engine->stop();
        }
        emit statusChanged();
        return false;
    }

    m_journalCorrupted = false;
    m_restore.pending = true;
    m_restore.epoch = targetEpoch;
    m_restore.deviceId = targetDevice;
    m_restore.folderId = targetFolder;
    m_restore.operationId = operationId;

    if (m_engine) {
        m_engine->stop();
    }
    emit statusChanged();
    return true;
}

bool SyncController::isRestoreStateUncertain() const
{
    return m_restore.pending || m_journalCorrupted || m_restoreRetry.phase == QLatin1String("prepared");
}

void SyncController::finishRestore(bool success, bool safeToResume)
{
    // 没经过 prepareForRestore 的结束（例如另一项备份正在进行、恢复根本没开始）：库没换，什么都不用做。
    if (!m_restore.pending) {
        return;
    }
    const RestoreState before = m_restore;
    m_restore = {};

    const QString dbPath = currentDatabasePath();
    const QString journalPath = journalFilePath(dbPath);

    if (!success) {
        if (!safeToResume) {
            // 回滚失败（不安全）：必须保留当前 prepared 日志及当前操作身份，阻断同步，
            // 不能恢复旧 installed 日志，不能允许 syncNow 自行收尾，要求重新恢复。
            m_restoreRetry.clear();
            m_restoreRetry.phase = QStringLiteral("prepared");
            m_restoreRetry.epoch = before.epoch;
            m_restoreRetry.deviceId = before.deviceId;
            m_restoreRetry.folderId = before.folderId;
            m_restoreRetry.operationId = before.operationId;
            m_restoreRetry.needsJournalDelete = false;
            m_restoreRetry.needsJournalWrite = false;
            m_restoreRetry.needsEpoch = false;
            m_restoreRetry.needsFolder = false;
            m_previousJournal = std::nullopt;
            m_restoreError = QStringLiteral("恢复备份失败且未能安全回滚原数据，同步已暂停以保护数据。请重新执行备份恢复。");
            if (m_engine) {
                m_engine->stop();
            }
            refreshLog();
            emit notice(m_restoreError);
            emit statusChanged();
            return;
        }

        // 第二次恢复失败，恢复先前日志和上下文；没有先前日志才删除新意图。保存/删除失败继续阻断。
        if (m_previousJournal.has_value()) {
            m_restoreRetry.clear();
            m_restoreRetry.phase = m_previousJournal->phase;
            m_restoreRetry.epoch = m_previousJournal->epoch;
            m_restoreRetry.deviceId = m_previousJournal->deviceId;
            m_restoreRetry.folderId = m_previousJournal->folderId;
            m_restoreRetry.operationId = m_previousJournal->operationId;

            QString writeBackErr;
            if (!writeJournalFile(journalPath, *m_previousJournal, &writeBackErr)) {
                qWarning() << "Failed to restore previous journal after second restore failure:" << writeBackErr;
                m_restoreError = writeBackErr;
                if (m_previousJournal->phase == QLatin1String("installed")) {
                    m_restoreRetry.needsJournalWrite = true;
                    m_restoreRetry.needsEpoch = true;
                    m_restoreRetry.needsFolder = true;
                } else {
                    // previous 为 prepared 时继续阻断并要求重新恢复，不允许 syncNow 认作 installed
                    m_restoreRetry.phase = QStringLiteral("prepared");
                    m_restoreRetry.needsJournalWrite = false;
                    m_restoreRetry.needsEpoch = false;
                    m_restoreRetry.needsFolder = false;
                }
                // 只有写回成功或最终收尾成功才丢弃需要恢复的旧上下文，此处写回失败不清空 m_previousJournal
            } else {
                if (m_previousJournal->phase == QLatin1String("installed")) {
                    m_restoreRetry.needsJournalWrite = false;
                    m_restoreRetry.needsEpoch = true;
                    m_restoreRetry.needsFolder = true;
                    m_restoreError = QStringLiteral("恢复备份后新纪元或文件夹尚未完成同步，同步已暂停以保护数据。");
                } else {
                    m_restoreRetry.phase = QStringLiteral("prepared");
                    m_restoreError = QStringLiteral("前次备份恢复尚未完成确认，同步已暂停以保护数据。");
                }
                m_previousJournal = std::nullopt;
            }
        } else {
            QString delErr;
            if (!deleteJournalFileSafely(journalPath, dbPath, before.operationId, &delErr)) {
                qWarning() << "Failed to delete prepared journal after restore failure:" << delErr;
                m_restoreRetry.clear();
                m_restoreRetry.phase.clear();
                m_restoreRetry.needsJournalDelete = true;
                m_restoreRetry.epoch = before.epoch;
                m_restoreRetry.deviceId = before.deviceId;
                m_restoreRetry.folderId = before.folderId;
                m_restoreRetry.operationId = before.operationId;
                m_restoreError = delErr;
            } else {
                m_restoreRetry.clear();
                m_restoreError.clear();
            }
        }
        refreshLog();
        startEngine();
        emit statusChanged();
        return;
    }

    if (!DatabaseManager::instance()->isOpen()) {
        m_restoreRetry.phase = QStringLiteral("installed");
        m_restoreRetry.needsEpoch = true;
        m_restoreRetry.needsFolder = true;
        m_restoreRetry.needsJournalWrite = true;
        m_restoreRetry.epoch = before.epoch;
        m_restoreRetry.deviceId = before.deviceId;
        m_restoreRetry.folderId = before.folderId;
        m_restoreRetry.operationId = before.operationId;
        m_restoreError = QStringLiteral("恢复备份后数据库未处于打开状态，同步已暂停以保护数据。");
        if (m_engine) {
            m_engine->stop();
        }
        refreshLog();
        emit notice(m_restoreError);
        emit statusChanged();
        return;
    }

    // 先写 installed 日志，再调用收尾。写 installed 失败不得启动；内存保留该成功事实，允许重试写日志。
    JournalData installedJournal;
    installedJournal.v = 1;
    installedJournal.operationId = before.operationId;
    installedJournal.epoch = before.epoch;
    installedJournal.deviceId = before.deviceId;
    installedJournal.folderId = before.folderId;
    installedJournal.phase = QStringLiteral("installed");
    installedJournal.dbPath = dbPath;

    QString installErr;
    if (!writeJournalFile(journalPath, installedJournal, &installErr)) {
        qWarning() << "Failed to write installed journal after restore:" << installErr;
        m_restoreRetry.phase = QStringLiteral("installed");
        m_restoreRetry.needsJournalWrite = true;
        m_restoreRetry.needsEpoch = true;
        m_restoreRetry.needsFolder = true;
        m_restoreRetry.epoch = before.epoch;
        m_restoreRetry.deviceId = before.deviceId;
        m_restoreRetry.folderId = before.folderId;
        m_restoreRetry.operationId = before.operationId;
        m_restoreError = QStringLiteral("记录恢复完成状态失败，同步已暂停以保护数据：%1").arg(installErr);
        if (m_engine) {
            m_engine->stop();
        }
        refreshLog();
        emit notice(m_restoreError);
        emit statusChanged();
        return;
    }

    SyncStore store;
    const bool epochStarted = store.beginEpochAfterRestore(before.epoch, before.deviceId, before.operationId);
    if (!epochStarted) {
        qWarning() << "Failed to start a new sync epoch after restoring a backup";
        m_restoreRetry.phase = QStringLiteral("installed");
        m_restoreRetry.needsEpoch = true;
        m_restoreRetry.needsFolder = (store.folderId() != before.folderId);
        m_restoreRetry.epoch = before.epoch;
        m_restoreRetry.deviceId = before.deviceId;
        m_restoreRetry.folderId = before.folderId;
        m_restoreRetry.operationId = before.operationId;
        m_restoreError = QStringLiteral("恢复备份后建立同步新纪元失败，同步已暂停以保护数据。");
        if (m_engine) {
            m_engine->stop();
        }
        refreshLog();
        emit notice(m_restoreError);
        emit statusChanged();
        return;
    }

    const bool folderKept = (store.folderId() == before.folderId || store.setFolderId(before.folderId));
    if (!folderKept) {
        qWarning() << "Failed to keep the joined sync folder after restoring a backup";
        m_restoreRetry.phase = QStringLiteral("installed");
        m_restoreRetry.needsEpoch = false;
        m_restoreRetry.needsFolder = true;
        m_restoreRetry.epoch = before.epoch;
        m_restoreRetry.deviceId = before.deviceId;
        m_restoreRetry.folderId = before.folderId;
        m_restoreRetry.operationId = before.operationId;
        m_restoreError = QStringLiteral("恢复备份后保留同步文件夹失败，同步已暂停以保护数据。");
        if (m_engine) {
            m_engine->stop();
        }
        refreshLog();
        emit notice(m_restoreError);
        emit statusChanged();
        return;
    }

    if (!reconcileSettings()) {
        qWarning() << "Failed to reconcile settings after restoring a backup";
        m_restoreRetry.phase = QStringLiteral("installed");
        m_restoreRetry.needsEpoch = false;
        m_restoreRetry.needsFolder = false;
        m_restoreRetry.needsSettings = true;
        m_restoreRetry.epoch = before.epoch;
        m_restoreRetry.deviceId = before.deviceId;
        m_restoreRetry.folderId = before.folderId;
        m_restoreRetry.operationId = before.operationId;
        if (m_restoreError.isEmpty()) {
            m_restoreError = QStringLiteral("恢复备份后整理同步设置失败，同步已暂停以保护数据。");
        }
        if (m_engine) {
            m_engine->stop();
        }
        refreshLog();
        emit notice(m_restoreError);
        emit statusChanged();
        return;
    }

    QString deleteErr;
    if (!deleteJournalFileSafely(journalPath, dbPath, before.operationId, &deleteErr)) {
        qWarning() << "Failed to delete restore journal after completion:" << deleteErr;
        m_restoreRetry.phase = QStringLiteral("installed");
        m_restoreRetry.needsJournalDelete = true;
        m_restoreRetry.needsEpoch = false;
        m_restoreRetry.needsFolder = false;
        m_restoreRetry.needsSettings = false;
        m_restoreRetry.epoch = before.epoch;
        m_restoreRetry.deviceId = before.deviceId;
        m_restoreRetry.folderId = before.folderId;
        m_restoreRetry.operationId = before.operationId;
        m_restoreError = QStringLiteral("恢复备份后清除恢复日志失败，同步已暂停以保护数据：%1").arg(deleteErr);
        if (m_engine) {
            m_engine->stop();
        }
        refreshLog();
        emit notice(m_restoreError);
        emit statusChanged();
        return;
    }

    m_restoreRetry.clear();
    m_restoreError.clear();
    m_previousJournal = std::nullopt;
    m_knownEpoch = store.epoch();
    m_knownFolderId = store.folderId();

    // 同步日志跟着库回到了备份那一刻。恢复失败时（!success）不清除先前 m_restoreRetry，startEngine() 守卫会维持阻断。
    refreshLog();
    startEngine();
    emit statusChanged();
}

void SyncController::shutdown(int timeoutMs)
{
    // flushBeforeExit 先停下引擎，再同步写出最后一批；写不完的改动还留在本机，下次启动再写。
    if (m_engine && !m_engine->flushBeforeExit(timeoutMs)) {
        qWarning() << "Sync changes were not all written before exit; they stay queued for next launch";
    }
}

QString SyncController::statusKey() const
{
    if (m_journalCorrupted || m_restoreRetry.hasPending() || !m_restoreError.isEmpty()) {
        return QStringLiteral("error");
    }
    if (!m_settingsError.isEmpty()) {
        return QStringLiteral("error");
    }
    if (!m_engine) {
        return QStringLiteral("stopped");
    }
    switch (m_engine->status()) {
    case SyncEngine::Status::Stopped:
        return QStringLiteral("stopped");
    case SyncEngine::Status::Starting:
        return QStringLiteral("starting");
    case SyncEngine::Status::UpToDate:
        return QStringLiteral("upToDate");
    case SyncEngine::Status::NeedsConfirmation:
        return QStringLiteral("needsConfirmation");
    case SyncEngine::Status::WaitingForSnapshot:
        return QStringLiteral("waitingForSnapshot");
    case SyncEngine::Status::FolderUnavailable:
        return QStringLiteral("folderUnavailable");
    case SyncEngine::Status::WrongFolder:
        return QStringLiteral("wrongFolder");
    case SyncEngine::Status::FolderMissing:
        return QStringLiteral("folderMissing");
    case SyncEngine::Status::NoSpace:
        return QStringLiteral("noSpace");
    case SyncEngine::Status::UploadFailed:
        return QStringLiteral("uploadFailed");
    case SyncEngine::Status::NewerVersion:
        return QStringLiteral("newerVersion");
    case SyncEngine::Status::BackupFailed:
        return QStringLiteral("backupFailed");
    case SyncEngine::Status::Error:
        return QStringLiteral("error");
    }
    return QStringLiteral("error");
}

bool SyncController::hasProblem() const
{
    return m_journalCorrupted || m_restoreRetry.hasPending() || !m_restoreError.isEmpty()
        || !m_settingsError.isEmpty()
        || (m_engine && isProblem(m_engine->status()));
}

QString SyncController::summaryText() const
{
    if (m_journalCorrupted) {
        return QStringLiteral("恢复日志损坏");
    }
    if (m_restoreRetry.phase == QLatin1String("prepared")) {
        return QStringLiteral("备份恢复未完成");
    }
    if (m_restoreRetry.needsJournalWrite) {
        return QStringLiteral("恢复状态记录失败");
    }
    if (m_restoreRetry.needsEpoch) {
        return QStringLiteral("恢复后开启新纪元失败");
    }
    if (m_restoreRetry.needsFolder) {
        return QStringLiteral("恢复后保留同步文件夹失败");
    }
    if (m_restoreRetry.needsJournalDelete) {
        return QStringLiteral("恢复日志清理失败");
    }
    if (!m_restoreError.isEmpty()) {
        return QStringLiteral("恢复备份后同步受阻");
    }
    if (!m_settingsError.isEmpty()) {
        return QStringLiteral("偏好设置保存失败");
    }
    if (!m_enabled) {
        return QStringLiteral("已关闭");
    }
    if (!m_engine) {
        return choosesFolder() ? QStringLiteral("还没有选择同步文件夹") : QStringLiteral("已暂停");
    }
    switch (m_engine->status()) {
    case SyncEngine::Status::Stopped:
        return QStringLiteral("已暂停");
    case SyncEngine::Status::Starting:
        return QStringLiteral("正在连接同步文件夹…");
    case SyncEngine::Status::UpToDate: {
        const QString at = syncedAtText(m_engine->lastSyncedAt());
        return at.isEmpty() ? QStringLiteral("已同步") : QStringLiteral("已同步 · %1").arg(at);
    }
    case SyncEngine::Status::NeedsConfirmation:
        return QStringLiteral("等你确认加入");
    case SyncEngine::Status::WaitingForSnapshot:
        return QStringLiteral("正在等同步文件夹里的数据");
    case SyncEngine::Status::FolderUnavailable:
        return QStringLiteral("暂时无法访问同步文件夹");
    case SyncEngine::Status::WrongFolder:
        return QStringLiteral("选中的不是同步文件夹");
    case SyncEngine::Status::FolderMissing:
        return QStringLiteral("同步文件夹不见了，同步已暂停");
    case SyncEngine::Status::NoSpace:
        return QStringLiteral("存储空间不足");
    case SyncEngine::Status::UploadFailed:
        return QStringLiteral("上传到 iCloud 失败");
    case SyncEngine::Status::NewerVersion:
        return QStringLiteral("需要更新这台设备上的应用");
    case SyncEngine::Status::BackupFailed:
        return QStringLiteral("自动备份没有成功，暂不替换");
    case SyncEngine::Status::Error:
        return QStringLiteral("同步出错");
    }
    return QString();
}

QString SyncController::statusText() const
{
    if (m_journalCorrupted) {
        return m_restoreError.isEmpty()
            ? QStringLiteral("恢复日志文件损坏或存在未知文件，同步已暂停以保护数据。")
            : m_restoreError;
    }
    if (m_restoreRetry.phase == QLatin1String("prepared")) {
        return QStringLiteral("检测到未完成的备份恢复意图，同步已暂停以保护数据。请重新执行备份恢复。");
    }
    if (m_restoreRetry.needsEpoch) {
        return QStringLiteral("备份已恢复到本机，但未能为同步建立新纪元。为防止数据覆盖，同步已保持暂停。请检查数据库后重试。");
    }
    if (m_restoreRetry.needsFolder) {
        return QStringLiteral("备份已恢复到本机，但未能保留原同步文件夹。为防止错误同步，同步已保持暂停。请检查数据库后重试。");
    }
    if (!m_restoreError.isEmpty()) {
        return m_restoreError;
    }
    if (!m_settingsError.isEmpty()) {
        return m_settingsError;
    }
    // 设置行里已经有一句「发生了什么」（summaryText），这里只写为什么、下一步怎么办，不把同一句话再说一遍。
    if (!m_engine) {
        return QString();
    }
    switch (m_engine->status()) {
    case SyncEngine::Status::Stopped:
        return QStringLiteral("同步暂停中，改动先留在这台设备上。");
    case SyncEngine::Status::Starting:
        return QStringLiteral("正在连接同步文件夹…");
    case SyncEngine::Status::UpToDate:
        return QStringLiteral("两台设备的数据已经一致。");
    case SyncEngine::Status::NeedsConfirmation:
        return m_engine->statusText();
    case SyncEngine::Status::WaitingForSnapshot:
        return QStringLiteral("另一台设备写的数据还在从 iCloud 传过来，到了之后会自动接着同步。");
    case SyncEngine::Status::FolderUnavailable:
        return QStringLiteral("请确认这台设备已登录 Apple ID，并打开了 iCloud 云盘。恢复之后会自动接着同步，"
                              "这期间的改动先留在本机。");
    case SyncEngine::Status::WrongFolder:
        // Mac 不选文件夹，位置是固定的：引擎给的「选错了哪一层」是写给 iPad 选择器的，在 Mac 上会让人摸不着头脑。
        // Mac 出现这个状态只有一种可能：iCloud 云盘里已经有一个同名文件夹，却不是能接上的同步文件夹。
        if (!choosesFolder()) {
            return QStringLiteral("iCloud 云盘里已经有一个「%1」文件夹，但它不是这台 Mac 能接上的同步文件夹"
                                  "（可能是以前留下的）。请在访达里把它移到别处或删除，再点「立即同步」。")
                .arg(SyncFiles::defaultFolderName());
        }
        return m_engine->statusText();
    case SyncEngine::Status::FolderMissing:
        return choosesFolder()
            ? QStringLiteral("原来选的同步文件夹被删除或移走了。Mac 重新建了同步文件夹的话，请在这里重新选择它。")
            : QStringLiteral("iCloud 云盘里的「%1」被删除或移走了。已经加入过的文件夹不会自动重建："
                             "另一台设备还认着原来那个。")
                  .arg(SyncFiles::defaultFolderName());
    case SyncEngine::Status::NoSpace:
        return QStringLiteral("改动暂时写不出去，先留在这台设备上；空出空间之后会自动写出。");
    case SyncEngine::Status::UploadFailed:
        return QStringLiteral("改动已经写进同步文件夹，但没能上传到 iCloud，可能是 iCloud 空间已满。"
                              "上传成功之前，另一台设备看不到这些改动。");
    case SyncEngine::Status::NewerVersion:
        return QStringLiteral("另一台设备用的是更新版本的番茄Todo，它写的数据这台设备读不懂。"
                              "更新这台设备上的应用之后会自动接着同步，数据不会丢。");
    case SyncEngine::Status::BackupFailed:
        return QStringLiteral("换掉本机数据之前要先自动备份，这次备份没有成功，所以没有替换。稍后会自动重试。");
    case SyncEngine::Status::Error:
        return QStringLiteral("这一轮没有做完，稍后会自动重试。");
    }
    return QString();
}

QString SyncController::statusDetail() const
{
    if (!m_restoreError.isEmpty()) {
        return m_restoreError;
    }
    if (m_journalCorrupted) {
        return QStringLiteral("恢复日志文件损坏或存在未知文件，同步已暂停");
    }
    if (m_restoreRetry.phase == QLatin1String("prepared")) {
        return QStringLiteral("恢复意图未完成确认，同步已暂停");
    }
    if (!m_settingsError.isEmpty()) {
        return m_settingsError;
    }
    // 选错文件夹时，引擎把「选错了哪一层」直接写进了状态说明，这里不再重复。
    if (!m_engine || m_engine->status() == SyncEngine::Status::WrongFolder) {
        return QString();
    }
    return m_engine->statusDetail();
}

int SyncController::pendingCount() const
{
    return m_engine ? m_engine->pendingCount() : 0;
}

QDateTime SyncController::lastSyncedAt() const
{
    if (m_engine) {
        return m_engine->lastSyncedAt();
    }
    return DatabaseManager::instance()->isOpen() ? SyncStore().lastSyncedAt() : QDateTime();
}

bool SyncController::isBusy() const
{
    return m_engine && m_engine->isBusy();
}

bool SyncController::choosesFolder() const
{
    return bool(m_platform.pickFolder);
}

bool SyncController::hasFolder() const
{
    return !choosesFolder() || !storedBookmark().isEmpty();
}

QString SyncController::folderDisplayPath() const
{
    return choosesFolder() ? friendlyFolderPath(QSettings().value(kFolderPathKey).toString())
                           : m_platform.fixedFolderDisplayPath;
}

int SyncController::logCount() const
{
    return readLogCount().value;
}

ServiceReadResult<int> SyncController::readLogCount() const
{
    if (!DatabaseManager::instance()->isOpen()) {
        return {0, ServiceReadError::Database};
    }
    return SyncStore().readSyncLogCount();
}

void SyncController::setEnabled(bool enabled)
{
    if (!enabled) {
        setEnabledState(false);
        m_joinRequested = false;
        emit statusChanged();
        return;
    }
    // iPad 还没选过文件夹：先去选，选好、校验通过才算打开（见 acceptFolder）。
    if (choosesFolder() && storedBookmark().isEmpty()) {
        chooseFolder();
        return;
    }
    if (setEnabledState(true)) {
        startEngine();
    }
    emit statusChanged();
}

void SyncController::confirmJoin()
{
    if (!m_engine) {
        return;
    }
    m_joinRequested = true;
    m_engine->confirmJoin();
}

void SyncController::syncNow()
{
    if (m_journalCorrupted || m_restoreRetry.phase == QLatin1String("prepared")) {
        return;
    }
    if (!m_restoreError.isEmpty() && !m_restoreRetry.hasPending()) {
        return;
    }
    // 若此前恢复备份后建立新纪元或保留文件夹失败，点击立即同步尝试重试未完成的步骤
    if (m_restoreRetry.hasPending() && DatabaseManager::instance()->isOpen()) {
        const QString dbPath = currentDatabasePath();
        const QString journalPath = journalFilePath(dbPath);

        // 如果是 finishRestore(false) 安全失败清理（phase 为空，仅需删除日志）：
        // 只安全删除日志，不推进 epoch/folder，不做设置整理。
        if (m_restoreRetry.phase.isEmpty() && m_restoreRetry.needsJournalDelete) {
            QString delErr;
            if (!deleteJournalFileSafely(journalPath, dbPath, m_restoreRetry.operationId, &delErr)) {
                qWarning() << "Retry to delete restore journal failed:" << delErr;
                m_restoreRetry.needsJournalDelete = true;
                m_restoreError = QStringLiteral("恢复备份后清除恢复日志失败，同步已暂停以保护数据：%1").arg(delErr);
                emit statusChanged();
                return;
            }
            m_restoreRetry.clear();
            m_restoreError.clear();
            m_previousJournal = std::nullopt;
            refreshLog();
            startEngine();
            emit statusChanged();
            if (m_engine) {
                m_engine->syncNow();
            }
            return;
        }

        if (m_restoreRetry.needsJournalWrite) {
            JournalData j;
            j.v = 1;
            j.operationId = m_restoreRetry.operationId;
            j.epoch = m_restoreRetry.epoch;
            j.deviceId = m_restoreRetry.deviceId;
            j.folderId = m_restoreRetry.folderId;
            j.phase = QStringLiteral("installed");
            j.dbPath = dbPath;
            QString err;
            if (!writeJournalFile(journalPath, j, &err)) {
                m_restoreError = QStringLiteral("记录恢复完成状态失败，同步已暂停以保护数据：%1").arg(err);
                emit statusChanged();
                return;
            }
            m_restoreRetry.needsJournalWrite = false;
            m_previousJournal = std::nullopt;
        }

        SyncStore store;
        if (m_restoreRetry.needsEpoch) {
            if (store.beginEpochAfterRestore(m_restoreRetry.epoch, m_restoreRetry.deviceId, m_restoreRetry.operationId)) {
                m_restoreRetry.needsEpoch = false;
            } else {
                qWarning() << "Retry to start sync epoch after restore failed";
                m_restoreError = QStringLiteral("恢复备份后建立同步新纪元失败，同步已暂停以保护数据。");
                emit statusChanged();
                return;
            }
        }
        // needsEpoch 成功后本次再执行 needsFolder；若 epoch 此前已成功则绝不再次调用 beginEpochAfterRestore
        if (m_restoreRetry.needsFolder) {
            if (store.folderId() == m_restoreRetry.folderId || store.setFolderId(m_restoreRetry.folderId)) {
                m_restoreRetry.needsFolder = false;
            } else {
                qWarning() << "Retry to keep sync folder after restore failed";
                m_restoreError = QStringLiteral("恢复备份后保留同步文件夹失败，同步已暂停以保护数据。");
                emit statusChanged();
                return;
            }
        }

        if (m_restoreRetry.needsSettings || (!m_restoreRetry.needsEpoch && !m_restoreRetry.needsFolder)) {
            if (!reconcileSettings()) {
                qWarning() << "Retry to reconcile settings after restore failed";
                m_restoreRetry.needsSettings = true;
                if (m_restoreError.isEmpty()) {
                    m_restoreError = QStringLiteral("恢复备份后整理同步设置失败，同步已暂停以保护数据。");
                }
                emit statusChanged();
                return;
            }
            m_restoreRetry.needsSettings = false;
        }

        if (m_restoreRetry.needsJournalDelete || QFileInfo::exists(journalPath)) {
            QString delErr;
            if (!deleteJournalFileSafely(journalPath, dbPath, m_restoreRetry.operationId, &delErr)) {
                qWarning() << "Retry to delete restore journal failed:" << delErr;
                m_restoreRetry.needsJournalDelete = true;
                m_restoreError = QStringLiteral("恢复备份后清除恢复日志失败，同步已暂停以保护数据：%1").arg(delErr);
                emit statusChanged();
                return;
            }
            m_restoreRetry.needsJournalDelete = false;
        }

        m_restoreRetry.clear();
        m_restoreError.clear();
        m_previousJournal = std::nullopt;
        m_knownEpoch = store.epoch();
        m_knownFolderId = store.folderId();
        refreshLog();
        startEngine();
        emit statusChanged();
    }
    if (m_engine) {
        m_engine->syncNow();
    }
}

void SyncController::chooseFolder()
{
    if (!m_platform.pickFolder || m_choosingFolder) {
        return;
    }
    setChoosingFolder(true);
    const QPointer<SyncController> self(this);
    m_platform.pickFolder([self](const QByteArray& bookmark, const QString& message) {
        if (!self) {
            return;
        }
        // 取消（书签与说明都为空）不提示；选择器自己出错时说明原因。
        if (bookmark.isEmpty()) {
            self->setChoosingFolder(false, message);
            return;
        }
        self->checkChosenFolder(bookmark, message);
    });
}

void SyncController::rebuildFolder()
{
    // iPad 不能建同步文件夹，只能重新选 Mac 建好的那个。
    if (choosesFolder()) {
        chooseFolder();
        return;
    }
    // 只在「已加入的文件夹不见了」时有意义：别的状态下忘掉文件夹，会让本机再走一遍加入。
    if (!m_engine || m_engine->status() != SyncEngine::Status::FolderMissing
        || !DatabaseManager::instance()->isOpen()) {
        return;
    }
    // Mac：忘掉原来加入的文件夹，下一轮按「第一次开启」处理：原处是空的（整个被删了）就新建一个，
    // 文件夹身份是新的，iPad 要重新选它并确认加入；原处还留着东西，会提示你先把它移走。
    if (!SyncStore().setFolderId(QString())) {
        qWarning() << "Failed to forget the missing sync folder";
        return;
    }
    m_knownFolderId.clear();
    m_engine->syncNow();
}

QVariantList SyncController::syncLog(int limit) const
{
    return readSyncLog(limit).value;
}

ServiceReadResult<QVariantList> SyncController::readSyncLog(int limit) const
{
    ServiceReadResult<QVariantList> read;
    QVariantList& result = read.value;
    if (!DatabaseManager::instance()->isOpen()) {
        read.error = ServiceReadError::Database;
        return read;
    }
    const ServiceReadResult<QList<SyncStore::LogEntry>> entries = SyncStore().readSyncLog(limit);
    if (!entries.ok()) {
        read.error = entries.error;
        return read;
    }
    const QDate today = QDate::currentDate();
    for (const SyncStore::LogEntry& entry : entries.value) {
        QVariantMap item;
        item.insert(QStringLiteral("id"), entry.id);
        item.insert(QStringLiteral("kind"), entry.kind);
        item.insert(QStringLiteral("kindLabel"), logKindLabel(entry.kind));
        item.insert(QStringLiteral("time"), !entry.loggedAt.isValid() ? QString()
                                            : entry.loggedAt.date() == today
                                                ? entry.loggedAt.toString(QStringLiteral("今天 HH:mm"))
                                                : entry.loggedAt.toString(QStringLiteral("M月d日 HH:mm")));
        // 标题：哪一条数据（文件问题是哪个文件）。
        QString title;
        if (entry.kind == QLatin1String("file")) {
            title = QStringLiteral("文件「%1」").arg(entry.recordLabel);
        } else if (!entry.recordLabel.isEmpty()) {
            title = QStringLiteral("%1「%2」").arg(entry.tableLabel, entry.recordLabel);
        } else {
            title = entry.tableLabel;
        }
        item.insert(QStringLiteral("title"), title);
        // 一句话说清楚结果：留下了谁的、谁的没有生效。
        QString summary = entry.detail;
        if (entry.kind == QLatin1String("edit") && !entry.fieldLabel.isEmpty()) {
            summary = QStringLiteral("「%1」保留了%2的「%3」，%4的「%5」没有生效。")
                          .arg(entry.fieldLabel, deviceLabel(entry.keptHere), logValueSummary(entry.keptValue),
                               deviceLabel(entry.lostHere), logValueSummary(entry.lostValue));
        } else if (entry.kind == QLatin1String("delete") && !entry.fieldLabel.isEmpty()) {
            // 删除赢了本机还没发出去的修改：把被丢掉的那一项写出来，需要的话可以手动补回。
            summary = QStringLiteral("%1。%2对「%3」的修改「%4」没有生效。")
                          .arg(entry.detail, deviceLabel(entry.lostHere), entry.fieldLabel, logValueSummary(entry.lostValue));
        } else if (entry.kind == QLatin1String("removed") && !entry.fieldLabel.isEmpty()) {
            // 另一台删掉了备忘录，这里留的是删除前的内容：只陈述内容，不说谁的修改没有生效，
            // 因为无从知道对方删之前看没看到。
            summary = QStringLiteral("%1。删除前的「%2」：「%3」")
                          .arg(entry.detail, entry.fieldLabel, logValueSummary(entry.lostValue));
        }
        item.insert(QStringLiteral("summary"), summary);
        item.insert(QStringLiteral("detail"), entry.detail);
        item.insert(QStringLiteral("fieldLabel"), entry.fieldLabel);
        item.insert(QStringLiteral("lostValue"), entry.lostValue);
        item.insert(QStringLiteral("keptValue"), entry.keptValue);
        // 只有备忘录的标题、正文提供「复制被覆盖的内容」。用原始表名、列名判断，不用显示名。
        item.insert(QStringLiteral("canCopyLostValue"), entry.table == QLatin1String("memos")
                    && (entry.kind == QLatin1String("edit") || entry.kind == QLatin1String("delete")
                        || entry.kind == QLatin1String("removed"))
                    && (entry.field == QLatin1String("title") || entry.field == QLatin1String("body"))
                    && !entry.lostValue.isEmpty());
        result.append(item);
    }
    return read;
}

QString SyncController::restoreWarning() const
{
    // 判据是「加入过同步文件夹」而不是开关：恢复之后开新纪元、写全量快照，是在下次同步时发生的，
    // 开关只决定这件事是马上发生、还是等你下次打开同步。
    if (!DatabaseManager::instance()->isOpen() || SyncStore().folderId().isEmpty()) {
        return QString();
    }
    return m_enabled
        ? QStringLiteral("已开启设备间同步：恢复之后，另一台设备也会回到这份备份的状态。"
                         "它会先自动备份自己的数据，这之后才换掉。")
        : QStringLiteral("这台设备加入过设备间同步（现在关着）：恢复之后，下次打开同步时，"
                         "另一台设备也会回到这份备份的状态。它会先自动备份自己的数据，这之后才换掉。");
}

void SyncController::ensureEngine()
{
    if (m_engine) {
        return;
    }
    std::unique_ptr<SyncFolder> folder = makeFolder(storedBookmark());
    if (!folder) {
        return;
    }
    m_engine = std::make_unique<SyncEngine>(std::move(folder), m_platform.engine);
    m_engine->setChangeNotifier(SyncNotifier::publish);
    if (m_safetyBackup) {
        m_engine->setSafetyBackup(m_safetyBackup);
    }
    if (m_platform.backgroundTask) {
        m_engine->setBackgroundTaskProvider(m_platform.backgroundTask);
    }
    connect(m_engine.get(), &SyncEngine::statusChanged, this, &SyncController::statusChanged);
    connect(m_engine.get(), &SyncEngine::cycleFinished, this, &SyncController::onCycleFinished);
}

void SyncController::startEngine()
{
    // 数据库还没打开（initialize 之前）不能开始：引擎一开始就要读库里的同步进度。
    // 恢复备份进行中或恢复后新纪元建立/文件夹保留失败/日志损坏/存在恢复错误时也不开始：防止 fail-open 路径继续同步。
    // 偏好设置持久化错误存在时也禁止开始同步。
    if (!DatabaseManager::instance()->isOpen() || !m_initialized || m_restore.pending
        || m_restoreRetry.hasPending() || m_journalCorrupted || !m_restoreError.isEmpty()
        || !m_settingsError.isEmpty() || !m_enabled) {
        return;
    }
    ensureEngine();
    if (m_engine) {
        m_engine->start();
    }
}

bool SyncController::setEnabledState(bool enabled)
{
    if (!enabled) {
        // 关闭请求：无论 QSettings 写入是否成功，都先停止当前引擎并把本次运行态设为关闭
        if (m_engine) {
            m_engine->stop();
        }
        const bool wasEnabled = m_enabled;
        m_enabled = false;
        if (wasEnabled) {
            emit enabledChanged();
        }

        // 调用 sync 后检查 status；再次 setEnabled(false) 即使 m_enabled 已是 false 也必须重试持久化
        QSettings settings;
        settings.setValue(kEnabledKey, false);
        settings.sync();
        if (settings.status() != QSettings::NoError) {
            m_settingsError = QStringLiteral("同步开关状态保存失败，同步已暂停以保护数据。");
            m_settingsRetryNeeded = true;
            return false;
        }
        m_settingsError.clear();
        m_settingsRetryNeeded = false;
        return true;
    } else {
        // 开启请求：只有 QSettings sync 成功才把 m_enabled 设为 true 并允许 startEngine；失败保持关闭、错误可见、可重试。
        QSettings settings;
        settings.setValue(kEnabledKey, true);
        settings.sync();
        if (settings.status() != QSettings::NoError) {
            m_enabled = false;
            m_settingsError = QStringLiteral("同步开关状态保存失败，无法开启同步。");
            m_settingsRetryNeeded = true;
            return false;
        }
        m_settingsError.clear();
        m_settingsRetryNeeded = false;
        const bool wasDisabled = !m_enabled;
        m_enabled = true;
        if (wasDisabled) {
            emit enabledChanged();
        }
        return true;
    }
}

void SyncController::setChoosingFolder(bool choosing, const QString& problem)
{
    if (m_choosingFolder != choosing || m_folderProblem != problem) {
        m_choosingFolder = choosing;
        m_folderProblem = problem;
        emit choosingFolderChanged();
    }
}

void SyncController::checkChosenFolder(const QByteArray& bookmark, const QString& displayPath)
{
    // 先校验标记文件，通过了才换掉原来的书签：选错一次不会把正在用的文件夹弄丢（049 里第一次就选成了子文件夹）。
    // 校验在线程池里做：iPad 读一个刚从云端同步来的文件要先下载，约 1 秒，不能卡住界面。
    // 用一个临时的访问对象，不碰引擎正在用的那个；它刷新出来的书签也不存（校验通过后存的是选择器给的这一份）。
    // 访问对象在主线程建好再交给线程池（构造很轻，只记下书签），和引擎的用法一样；建它的工厂只在主线程里调用。
    if (!m_platform.makeFolder) {
        setChoosingFolder(false, QStringLiteral("这台设备不支持选择同步文件夹"));
        return;
    }
    const auto worker = std::make_shared<SyncWorker>(m_platform.makeFolder(bookmark, [](const QByteArray&) {}));
    auto* watcher = new QFutureWatcher<SyncWorker::OpenResult>(this);
    const quint64 attempt = ++m_folderCheckAttempt;
    connect(watcher, &QFutureWatcherBase::finished, this, [this, watcher, bookmark, displayPath, attempt] {
        watcher->deleteLater();
        // 超时作废之后才回来的结果：那一次已经告诉你没响应了，你可能已经重新选了别的，不再用它。
        if (attempt != m_folderCheckAttempt || !m_choosingFolder) {
            return;
        }
        const SyncWorker::OpenResult result = watcher->result();
        if (!result.error.ok()) {
            setChoosingFolder(false, QStringLiteral("打不开选中的文件夹：%1").arg(result.error.message));
            return;
        }
        switch (result.markerState) {
        case SyncWorker::MarkerState::Present:
            setChoosingFolder(false);
            acceptFolder(bookmark, displayPath);
            return;
        case SyncWorker::MarkerState::Missing:
            // 按里面有什么推测选错了哪一层，告诉你该选哪个。
            setChoosingFolder(false, result.hint);
            return;
        case SyncWorker::MarkerState::Corrupt:
            setChoosingFolder(false, QStringLiteral("选中文件夹里的标记文件「%1」坏了：%2")
                                         .arg(SyncFiles::markerFileName(), result.markerError));
            return;
        case SyncWorker::MarkerState::Newer:
            setChoosingFolder(false, QStringLiteral("这个同步文件夹是更新版本的番茄Todo 建的，请先更新这台设备上的应用。"));
            return;
        }
    });
    // 选中的文件夹迟迟读不出来（例如断网时在等 iCloud 下载标记文件）：不能让设置页一直停在「正在检查」、
    // 按钮也一直点不了。时限与同步引擎的看门狗相同；到点就取消正在等的读、作废这一次，请你稍后再选。
    const int timeoutMs = m_platform.engine.stallTimeoutMs;
    QTimer::singleShot(timeoutMs, this, [this, worker, attempt, timeoutMs] {
        if (attempt != m_folderCheckAttempt || !m_choosingFolder) {
            return;
        }
        ++m_folderCheckAttempt;
        worker->cancelPendingIo();
        setChoosingFolder(false, QStringLiteral("读选中的文件夹超过 %1 秒没有响应（可能在等 iCloud 下载，或者网络不通），"
                                                "请稍后再选一次。原来的文件夹照常使用。")
                                     .arg(qMax(1, timeoutMs / 1000)));
    });
    watcher->setFuture(QtConcurrent::run([worker] { return worker->open(QString()); }));
}

std::unique_ptr<SyncFolder> SyncController::makeFolder(const QByteArray& bookmark)
{
    if (!m_platform.makeFolder || (choosesFolder() && bookmark.isEmpty())) {
        return nullptr;
    }
    // 书签刷新的回调在同步的工作线程里执行。带上这个文件夹是第几代，回到主线程再判断它还是不是现在用的：
    // 换了文件夹之后，排在队里的旧操作照样会跑完，它刷新出来的旧书签不能把新选的盖掉。
    const quint64 generation = ++m_folderGeneration;
    const QPointer<SyncController> self(this);
    return m_platform.makeFolder(bookmark, [self, generation](const QByteArray& refreshed) {
        QCoreApplication* app = QCoreApplication::instance();
        if (!app) {
            return;
        }
        // 投递到主线程执行；控制器那时已经销毁的话，QPointer 为空，什么都不做。
        QMetaObject::invokeMethod(
            app,
            [self, generation, refreshed] {
                if (self) {
                    self->onBookmarkRefreshed(generation, refreshed);
                }
            },
            Qt::QueuedConnection);
    });
}

QByteArray SyncController::storedBookmark() const
{
    return QSettings().value(kBookmarkKey).toByteArray();
}

void SyncController::acceptFolder(const QByteArray& bookmark, const QString& displayPath)
{
    const QByteArray oldBookmark = storedBookmark();
    const QString oldFolderPath = QSettings().value(kFolderPathKey).toString();

    QSettings settings;
    settings.setValue(kBookmarkKey, bookmark);
    settings.setValue(kFolderPathKey, displayPath);
    settings.sync();

    if (settings.status() != QSettings::NoError) {
        // 尽最大努力恢复旧两项偏好
        settings.setValue(kBookmarkKey, oldBookmark);
        settings.setValue(kFolderPathKey, oldFolderPath);
        settings.sync();

        m_settingsError = QStringLiteral("同步文件夹信息保存失败，无法切换文件夹。");
        m_settingsRetryNeeded = true;
        emit statusChanged();
        return;
    }

    m_settingsError.clear();
    m_settingsRetryNeeded = false;

    // 只有两项持久化成功，才切换 m_engine->setFolder、发 folderChanged、setEnabledState(true)、startEngine
    if (m_engine) {
        m_engine->setFolder(makeFolder(bookmark));
    }
    emit folderChanged();
    if (setEnabledState(true)) {
        startEngine();
    }
    emit statusChanged();
}

void SyncController::onBookmarkRefreshed(quint64 folderGeneration, const QByteArray& bookmark)
{
    // 只存现在用的这个文件夹刷新出来的书签。换过文件夹以后，排在队里的旧操作刷新的是旧文件夹的书签。
    if (folderGeneration != m_folderGeneration || bookmark.isEmpty()) {
        return;
    }
    QSettings settings;
    settings.setValue(kBookmarkKey, bookmark);
    settings.sync();
    if (settings.status() != QSettings::NoError) {
        m_settingsError = QStringLiteral("同步文件夹书签更新保存失败。");
        emit statusChanged();
    } else if (!m_settingsError.isEmpty()) {
        m_settingsError.clear();
        emit statusChanged();
    }
}

void SyncController::onCycleFinished()
{
    SyncStore store;
    const qint64 epoch = store.epoch();
    const QString folderId = store.folderId();
    if (m_joinRequested && !folderId.isEmpty() && folderId != m_knownFolderId) {
        m_joinRequested = false;
        emit notice(QStringLiteral("已加入同步：本机数据已换成同步文件夹里的，原来的数据已自动备份。"));
    } else if (m_knownFolderId.isEmpty() && !folderId.isEmpty() && !choosesFolder()) {
        emit notice(QStringLiteral("已在 iCloud 云盘建好「%1」文件夹。到 iPad 上选这个文件夹，就能加入同步。")
                        .arg(SyncFiles::defaultFolderName()));
    } else if (m_knownEpoch >= 0 && epoch != m_knownEpoch && folderId == m_knownFolderId) {
        // 纪元变了、文件夹没换：另一台设备恢复了备份，本机跟着整体换成了它的数据（换之前已自动备份）。
        emit notice(QStringLiteral("另一台设备恢复了备份，这台设备已跟着回到那份备份的状态（换之前已自动备份）。"));
    }
    m_knownEpoch = epoch;
    m_knownFolderId = folderId;
    refreshLog();
}

void SyncController::refreshLog()
{
    if (!DatabaseManager::instance()->isOpen()) {
        return;
    }
    // 只在有新记录（或者库被整个换掉、日志回到了别的样子）时通知界面重新读，不是每轮同步都刷。
    const qint64 latest = SyncStore().latestSyncLogId();
    if (latest != m_lastLogId) {
        m_lastLogId = latest;
        ++m_logRevision;
        emit logChanged();
    }
}

void SyncController::recordSettings()
{
    // 启动核对之前不记：initialize 会按库里记下的和本机设置一起核对一遍。
    // 同步正在把对方的值写回本机时也不记：那时的变更信号不是本机改动（见 SyncedSettings::WriteBackScope）。
    if (!m_initialized || SyncedSettings::isWritingBack() || !DatabaseManager::instance()->isOpen()) {
        return;
    }
    SyncStore store;
    const QHash<QString, QString> synced = store.syncedSettings();
    const QHash<QString, QString> local = SyncedSettings::currentValues();
    for (auto it = local.cbegin(); it != local.cend(); ++it) {
        // 先和库里的比：今日目标一天一项，每次都逐项开事务去比太浪费。值没变的不是本机改动。
        const auto known = synced.constFind(it.key());
        if (known != synced.constEnd() && known.value() == it.value()) {
            continue;
        }
        if (!store.recordLocalSetting(it.key(), it.value(), SyncedSettings::isFactoryDefault(it.key(), it.value()))) {
            qWarning() << "Failed to record a synced setting:" << it.key();
        }
    }
}

bool SyncController::reconcileSettings()
{
    if (!DatabaseManager::instance()->isOpen()) {
        m_restoreError = QStringLiteral("数据库未打开，无法整理同步设置。");
        return false;
    }
    SyncStore store;
    bool syncedOk = false;
    const QHash<QString, QString> synced = store.syncedSettings(&syncedOk);
    if (!syncedOk) {
        m_restoreError = QStringLiteral("读取已同步设置失败，同步已暂停以保护数据。");
        return false;
    }

    bool pendingOk = false;
    const QHash<QString, QString> pending = store.pendingSettingWriteBacks(&pendingOk);
    if (!pendingOk) {
        m_restoreError = QStringLiteral("读取待写回设置标记失败，同步已暂停以保护数据。");
        return false;
    }

    bool localOk = false;
    QHash<QString, QString> local = SyncedSettings::currentValues(&localOk);
    if (!localOk) {
        m_restoreError = QStringLiteral("读取本地设置失败，同步已暂停以保护数据。");
        return false;
    }

    const auto isRemoval = [](const QString& kind) { return kind == QLatin1String("remove"); };
    // 库里记的和本机设置不一致，有两种来由，靠「待写回」标记分辨（标记和对方的值在同一个事务里进库）：
    // - 有标记：对方的改动进了库、还没写回本机就被结束了。以库为准写回（「今天」是哪天、番茄多长才和另一台一致）。
    // - 没有标记：本机改了设置，却没记进库（记录失败：库被别的连接长时间占着而等待超时、磁盘满……）。
    //   这时以本机为准，下面补记一个新版本；以前一律以库为准，会把你的改动在下次启动时悄悄改回去。
    // 库里有、本机却没有的项（例如某一天的今日目标）没有本机的值可留，同样以库为准。
    bool writeBackFailed = false;
    QString writeBackErrMsg;
    QSet<QString> failedKeys;

    struct ScopedConnection {
        QMetaObject::Connection conn;
        ~ScopedConnection() {
            if (conn) {
                QObject::disconnect(conn);
            }
        }
    };

    {
        ScopedConnection connGuard;
        auto* appSettings = AppSettings::instance();
        if (appSettings) {
            connGuard.conn = QObject::connect(appSettings, &AppSettings::settingsWriteFailed,
                                             [&writeBackFailed, &failedKeys, &writeBackErrMsg](const QString& key, const QString& msg) {
                                                 writeBackFailed = true;
                                                 if (key == QLatin1String("schedule")) {
                                                     failedKeys.insert(QStringLiteral("schedule/periods"));
                                                     failedKeys.insert(QStringLiteral("schedule/semesterStartDate"));
                                                     failedKeys.insert(QStringLiteral("schedule/semesterWeeks"));
                                                 } else if (!key.isEmpty()) {
                                                     failedKeys.insert(key);
                                                 }
                                                 if (writeBackErrMsg.isEmpty()) {
                                                     writeBackErrMsg = msg;
                                                 }
                                             });
        }
        const SyncedSettings::WriteBackScope writingBack;
        for (auto it = pending.cbegin(); it != pending.cend(); ++it) {
            const QString& key = it.key();
            const QString& kind = it.value();
            bool stepOk = true;
            if (isRemoval(kind)) {
                stepOk = SyncedSettings::remove(key);
            } else if (synced.contains(key) && local.value(key) != synced.value(key)) {
                stepOk = SyncedSettings::apply(key, synced.value(key));
            }
            if (!stepOk || failedKeys.contains(key)) {
                writeBackFailed = true;
                failedKeys.insert(key);
                qWarning() << "Failed to write back a synced setting:" << key;
            }
        }
        for (auto it = synced.cbegin(); it != synced.cend(); ++it) {
            const QString& key = it.key();
            if (!pending.contains(key) && SyncSchema::isSyncedSettingKey(key) && !local.contains(key)) {
                if (!SyncedSettings::apply(key, it.value()) || failedKeys.contains(key)) {
                    writeBackFailed = true;
                    failedKeys.insert(key);
                    qWarning() << "Failed to write back a synced setting:" << key;
                }
            }
        }
    }

    bool recheckOk = false;
    local = SyncedSettings::currentValues(&recheckOk);
    if (!recheckOk) {
        m_restoreError = QStringLiteral("写回设置后重新读取本地设置失败，同步已暂停以保护数据。");
        return false;
    }

    // 写回真的成了的，清掉标记；没成的（取值写不回本机、偏好文件写不进去）留着，下次启动再试，
    // 也不拿本机的值去盖它——那多半是对方的取值本机认不得（例如更新版本的写法），不能反过来把它改掉。
    QSet<QString> unresolved;
    bool finishMarkFailed = false;
    for (auto it = pending.cbegin(); it != pending.cend(); ++it) {
        const QString& key = it.key();
        if (failedKeys.contains(key)) {
            unresolved.insert(key);
            continue;
        }

        const bool done = isRemoval(it.value())
            // 固定的几项不删（保留本机的值，下面按本机的记进库）；今日目标要确认真的删掉了。
            ? (SyncSchema::dailyGoalDateOf(it.key()).isEmpty() || !local.contains(it.key()))
            : (!synced.contains(it.key()) || local.value(it.key()) == synced.value(it.key()));
        if (done) {
            if (!store.finishSettingWriteBack(it.key())) {
                qWarning() << "Failed to finish setting writeback marker:" << it.key();
                unresolved.insert(key);
                finishMarkFailed = true;
            }
        } else {
            unresolved.insert(key);
        }
    }

    if (writeBackFailed) {
        m_restoreError = writeBackErrMsg.isEmpty()
            ? QStringLiteral("写回同步设置失败，同步已暂停以保护数据。")
            : QStringLiteral("写回同步设置失败：%1").arg(writeBackErrMsg);
        return false;
    }

    if (finishMarkFailed) {
        m_restoreError = QStringLiteral("更新设置写回标记失败，同步已暂停以保护数据。");
        return false;
    }

    if (!unresolved.isEmpty()) {
        if (m_restoreError.isEmpty()) {
            m_restoreError = QStringLiteral("存在未解决的同步设置待写回项，同步已暂停以保护数据。");
        }
        return false;
    }

    // 本机的值库里没记、或记的不一样（又不是在等写回的）：以本机为准记一个新版本、等着发出。
    // 库里还没有的（刚升级、新装、恢复了更早版本的备份）也走这里。还是出厂默认值的用最小版本，
    // 另一台设备改过的设置会盖过它，而不是反过来被这个默认值盖掉。
    for (auto it = local.cbegin(); it != local.cend(); ++it) {
        const auto known = synced.constFind(it.key());
        if (unresolved.contains(it.key()) || (known != synced.constEnd() && known.value() == it.value())) {
            continue;
        }
        if (!store.recordLocalSetting(it.key(), it.value(), SyncedSettings::isFactoryDefault(it.key(), it.value()))) {
            qWarning() << "Failed to record a synced setting:" << it.key();
            m_restoreError = QStringLiteral("记录本地设置失败，同步已暂停以保护数据。");
            return false;
        }
    }

    return true;
}

void SyncController::copyLostValue(const QString& text)
{
    emit copyRequested(text);
}
