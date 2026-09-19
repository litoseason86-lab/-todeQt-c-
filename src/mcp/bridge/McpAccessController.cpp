#include "McpAccessController.h"
#include "../common/McpEndpointFiles.h"
#include <QDir>
#include <QJsonArray>
#include <QFileInfo>
#include <QLockFile>
#include <QRandomGenerator>
#include <QSettings>
#include <QUuid>
#include <QCoreApplication>
#include <QDateTime>
#include <QJsonDocument>

using namespace McpContracts;

McpAccessController::McpAccessController(const McpPaths::Resolution& endpoint, QSettings& settings,
                                       StatusProvider statusProvider, QObject* parent)
    : QObject(parent), m_endpoint(endpoint), m_settings(settings), m_statusProvider(std::move(statusProvider))
{
    // 授权只认当前应用本机域，不能从系统全局偏好回退出一个启用值。
    m_settings.setFallbacksEnabled(false);
    m_enabled = m_settings.value(QStringLiteral("mcp/enabled"), false).toBool();
    m_writeEnabled = m_settings.value(QStringLiteral("mcp/writeEnabled"), false).toBool();
    rotateSession();
}
McpAccessController::~McpAccessController() { stop(); }
bool McpAccessController::enabled() const { return m_enabled; }
bool McpAccessController::writeEnabled() const { return m_writeEnabled; }
bool McpAccessController::listening() const { return bool(m_server); }
void McpAccessController::rotateSession()
{
    m_session = QUuid::createUuid().toString(QUuid::WithoutBraces);
    emit sessionChanged();
}
bool McpAccessController::start()
{
    if (!enabled() || m_shuttingDown) return false;
    if (m_server) return true;
    m_error.clear();
    if (!m_endpoint.ok()) {
        m_error = QStringLiteral("接入路径无效：") + McpPaths::pathErrorReason(m_endpoint.error);
        emit stateChanged();
        return false;
    }
    const auto& paths = m_endpoint.paths;
    if (!McpEndpointFiles::prepareRoot(paths, &m_error)) { emit stateChanged(); return false; }
    const QString lockPath = QDir(paths.rootDirectory).filePath(QStringLiteral("lock"));
    if (QFileInfo(lockPath).isSymLink()) {
        m_error = QStringLiteral("接入锁不能是符号链接");
        emit stateChanged();
        return false;
    }
    m_lock = std::make_unique<QLockFile>(lockPath);
    m_lock->setStaleLockTime(0);
    if (!m_lock->tryLock(0)) {
        m_lock.reset();
        m_error = QStringLiteral("接入端点已被其他实例占用");
        emit stateChanged();
        return false;
    }
    // 只有持锁的主应用可以清理崩溃遗留文件；辅助程序绝不删除端点。
    if (!McpEndpointFiles::removeOwned(paths.socketPath, true)
        || !McpEndpointFiles::removeOwned(paths.credentialPath)
        || !McpEndpointFiles::removeOwned(paths.discoveryPath)) {
        m_lock.reset();
        m_error = QStringLiteral("接入端点包含不安全的遗留文件");
        emit stateChanged();
        return false;
    }
    QByteArray credential;
    for (int i = 0; i < 8; ++i) {
        const quint32 random = QRandomGenerator::system()->generate();
        credential.append(reinterpret_cast<const char*>(&random), sizeof(random));
    }
    credential = credential.toHex();
    auto server = std::make_unique<McpLocalServer>(paths, this);
    if (!server->listen(credential, [this](Tool tool, const QJsonObject& arguments) { return dispatch(tool, arguments); })
        || !McpEndpointFiles::publish(paths, credential)) {
        server->close();
        McpEndpointFiles::removeOwned(paths.credentialPath);
        McpEndpointFiles::removeOwned(paths.discoveryPath);
        m_lock.reset();
        m_error = QStringLiteral("无法监听或发布接入端点");
        emit stateChanged();
        return false;
    }
    connect(server.get(), &McpLocalServer::connectionsChanged, this, &McpAccessController::stateChanged);
    m_server = std::move(server);
    emit stateChanged();
    return true;
}
void McpAccessController::stop()
{
    if (m_server) {
        // 服务调用可能同步发信号而关闭接入。先断线，再延迟析构，避免销毁仍在执行的请求栈。
        auto* server = m_server.release();
        server->close();
        server->deleteLater();
    }
    if (m_lock && m_lock->isLocked()) {
        McpEndpointFiles::removeOwned(m_endpoint.paths.discoveryPath);
        McpEndpointFiles::removeOwned(m_endpoint.paths.credentialPath);
    }
    m_lock.reset();
}
bool McpAccessController::savePolicy(const QString& key, bool value, bool previousValue)
{
    // QSettings 会记住首次错误，sync 成功也不会清除；每次保存使用新实例判断本次结果。
    // 原生偏好必须继续使用组织名/应用名构造，不能把 macOS 偏好路径当普通文件打开。
    std::unique_ptr<QSettings> settings;
    if (m_settings.organizationName().isEmpty())
        settings = std::make_unique<QSettings>(m_settings.fileName(), m_settings.format());
    else
        settings = std::make_unique<QSettings>(m_settings.format(), m_settings.scope(),
                                               m_settings.organizationName(), m_settings.applicationName());
    settings->setFallbacksEnabled(false);
    settings->setAtomicSyncRequired(m_settings.isAtomicSyncRequired());
    settings->setValue(key, value);
    settings->sync();
    const bool saved = settings->status() == QSettings::NoError;
    // 失败的新授权不能留在共享缓存中，避免文件恢复可写后被延迟落盘。
    // 撤销则保留 false，让后续同步有机会持久化撤销结果。
    if (!saved && value) settings->setValue(key, previousValue);
    return saved;
}

bool McpAccessController::setEnabled(bool value)
{
    const bool saved = savePolicy(QStringLiteral("mcp/enabled"), value, m_enabled);
    // 保存失败不能新增授权；撤销则立即生效，即使磁盘暂时不可写也不能保留活动连接。
    if (saved || !value) m_enabled = value;
    if (!value) { stop(); rotateSession(); }
    const bool success = saved && (!value || start());
    if (!saved) m_error = value
        ? QStringLiteral("保存本机接入设置失败，未新增授权；请检查设置文件权限")
        : QStringLiteral("本次接入已关闭，但设置保存失败；重启前请检查设置文件权限");
    else if (!value) m_error.clear();
    emit stateChanged();
    return success;
}
bool McpAccessController::setWriteEnabled(bool value)
{
    const bool saved = savePolicy(QStringLiteral("mcp/writeEnabled"), value, m_writeEnabled);
    if (saved || !value) m_writeEnabled = value;
    if (!saved) {
        m_error = value
            ? QStringLiteral("保存任务写入权限失败，未新增授权；请检查设置文件权限")
            : QStringLiteral("本次任务写入权限已撤销，但设置保存失败；重启前请检查设置文件权限");
    } else {
        m_error.clear();
    }
    emit stateChanged();
    return saved;
}
void McpAccessController::beginRestore()
{
    rotateSession();
    setRestoreBlocked(true);
}
void McpAccessController::setRestoreBlocked(bool blocked)
{
    m_restoreBlocked = blocked;
    if (blocked && m_server) m_server->rejectQueued(busyError());
    emit stateChanged();
}
void McpAccessController::shutdown()
{
    m_shuttingDown = true;
    if (m_server) m_server->rejectQueued(busyError());
    stop();
    rotateSession();
    emit stateChanged();
}
QJsonObject McpAccessController::busyError() const
{
    QList<BusyBlock> blocks = m_blockProvider ? m_blockProvider() : QList<BusyBlock>{};
    if (m_shuttingDown) blocks.append({BusyReason::ShuttingDown, QStringLiteral("应用退出"), 0});
    else if (m_restoreBlocked) blocks.append({BusyReason::BackupRestore, QStringLiteral("备份恢复"), 0});
    return blocks.isEmpty() ? QJsonObject{} : makeBusyError(blocks);
}
QJsonObject McpAccessController::appStatus() const
{
    QJsonObject status = m_statusProvider();
    status.insert("access_enabled", enabled());
    status.insert("write_enabled", writeEnabled());
    status.insert("app_session_id", m_session);
    const auto blocked = busyError();
    status.insert("blocks", blocked.isEmpty() ? QJsonValue(QJsonArray{}) : blocked.value("details").toObject().value("blocks"));
    return status;
}
void McpAccessController::setDataHandler(McpLocalServer::Handler handler) { m_dataHandler = std::move(handler); }
QJsonObject McpAccessController::dispatchImpl(Tool tool, const QJsonObject& arguments)
{
    const auto validation = validateToolArguments(tool, arguments);
    if (!validation.ok()) return makeToolErrorResult(makeValidationError(validation));
    if (!enabled()) return makeToolErrorResult(makeError(ErrorCode::McpDisabled, QStringLiteral("外部 AI 接入已关闭")));
    if (tool == Tool::GetStatus) return makeToolSuccessResult(appStatus());
    if (m_shuttingDown || m_restoreBlocked) return makeToolErrorResult(busyError());
    if (contract(tool).access == ToolAccess::Write) {
        if (!writeEnabled()) return makeToolErrorResult(makeError(ErrorCode::PermissionDenied, QStringLiteral("未允许 AI 修改任务")));
        if (arguments.value("app_session_id").toString() != m_session)
            return makeToolErrorResult(makeError(ErrorCode::SessionExpired, QStringLiteral("应用会话已改变，请重新查询状态")));
    }
    if (m_dataHandler) return m_dataHandler(tool, arguments);
    return makeToolErrorResult(makeError(ErrorCode::AppUnavailable, QStringLiteral("当前阶段尚未开放业务数据工具"), {{"reason", "stage_not_ready"}}));
}

void McpAccessController::setBlockProvider(std::function<QList<BusyBlock>()> provider)
{
    m_blockProvider = std::move(provider);
}

int McpAccessController::connectionCount() const { return m_server ? m_server->connectionCount() : 0; }
QString McpAccessController::helperPath() const
{
    return QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("PomodoroTodoMcp"));
}
void McpAccessController::copyHelperPath() { emit copyRequested(helperPath()); }
QString McpAccessController::blockSummary() const
{
    const auto error = busyError();
    if (error.isEmpty()) return QStringLiteral("当前无交互阻断");
    QStringList descriptions;
    for (const auto& entry : error.value("details").toObject().value("blocks").toArray()) {
        const auto block = entry.toObject();
        const QString reason = block.value("reason").toString();
        const QString caption = reason == "editing" ? QStringLiteral("编辑中") : reason == "dragging" ? QStringLiteral("拖动中")
            : reason == "pending_delete" ? QStringLiteral("等待删除") : reason == "backup_restore" ? QStringLiteral("备份恢复中") : QStringLiteral("正在退出");
        descriptions.append(caption + QStringLiteral("：") + block.value("source").toString());
    }
    return descriptions.join(QStringLiteral("；")) + QStringLiteral("。") + error.value("next_action").toString();
}
QJsonObject McpAccessController::dispatch(Tool tool, const QJsonObject& arguments)
{
    const auto result = dispatchImpl(tool, arguments);
    if (tool != Tool::GetStatus) {
        QString outcome = QStringLiteral("成功");
        if (result.value("isError").toBool()) {
            const auto content = result.value("content").toArray();
            if (!content.isEmpty()) outcome = QJsonDocument::fromJson(content.first().toObject().value("text").toString().toUtf8()).object().value("code").toString();
        }
        // 只显示操作类型与结果，不记录标题、备注、凭据或完整参数，也不触发全局 Toast。
        m_lastOperation = QDateTime::currentDateTime().toString(QStringLiteral("HH:mm:ss ")) + contract(tool).title + QStringLiteral(" · ") + outcome;
        emit stateChanged();
    }
    return result;
}
