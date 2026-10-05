#pragma once
#include "McpLocalServer.h"
#include <memory>

class QSettings;
class QLockFile;

// 接入策略只写 mcp/，不登记进设置快照的两份名单，备份恢复因此完全不触碰本机授权。
class McpAccessController : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled NOTIFY stateChanged)
    Q_PROPERTY(bool writeEnabled READ writeEnabled NOTIFY stateChanged)
    Q_PROPERTY(bool listening READ listening NOTIFY stateChanged)
    Q_PROPERTY(int connectionCount READ connectionCount NOTIFY stateChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY stateChanged)
    Q_PROPERTY(QString helperPath READ helperPath CONSTANT)
    Q_PROPERTY(QString blockSummary READ blockSummary NOTIFY stateChanged)
    Q_PROPERTY(QString lastOperation READ lastOperation NOTIFY stateChanged)
public:
    using StatusProvider = std::function<QJsonObject()>;
    McpAccessController(const McpPaths::Resolution& endpoint, QSettings& settings,
                        StatusProvider statusProvider, QObject* parent = nullptr);
    ~McpAccessController() override;
    const McpPaths::Resolution& endpoint() const { return m_endpoint; }
    bool start();
    Q_INVOKABLE bool setEnabled(bool enabled);
    Q_INVOKABLE bool setWriteEnabled(bool enabled);
    bool enabled() const;
    bool writeEnabled() const;
    bool listening() const;
    int connectionCount() const;
    QString helperPath() const;
    QString blockSummary() const;
    QString lastOperation() const { return m_lastOperation; }
    Q_INVOKABLE void copyHelperPath();
    QString sessionId() const { return m_session; }
    QString lastError() const { return m_error; }
    void beginRestore();
    void setRestoreBlocked(bool blocked);
    void shutdown();
    QJsonObject dispatch(McpContracts::Tool tool, const QJsonObject& arguments);
    // 显式注入业务处理器；测试宿主不安装时明确返回未开放。
    void setDataHandler(McpLocalServer::Handler handler);
    QJsonObject appStatus() const;
    void setBlockProvider(std::function<QList<McpContracts::BusyBlock>()> provider);
    // 只供测试缩短握手期限的等待，见 McpLocalServer::setHandshakeTimeoutMs；之后开启的服务端也沿用。
    void setHandshakeTimeoutMs(int milliseconds);
signals:
    void stateChanged();
    void sessionChanged();
    void copyRequested(const QString& text);
private:
    QJsonObject dispatchImpl(McpContracts::Tool tool, const QJsonObject& arguments);
    bool savePolicy(const QString& key, bool value, bool previousValue);
    void stop();
    void rotateSession();
    QJsonObject busyError() const;
    McpPaths::Resolution m_endpoint;
    QSettings& m_settings;
    StatusProvider m_statusProvider;
    std::function<QList<McpContracts::BusyBlock>()> m_blockProvider;
    McpLocalServer::Handler m_dataHandler;
    std::unique_ptr<QLockFile> m_lock;
    std::unique_ptr<McpLocalServer> m_server;
    QString m_session, m_error, m_lastOperation;
    bool m_enabled = false;
    bool m_writeEnabled = false;
    bool m_restoreBlocked = false;
    bool m_shuttingDown = false;
    int m_handshakeTimeoutMs = McpContracts::kHandshakeTimeoutMs;
};
