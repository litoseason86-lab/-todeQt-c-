#include "SyncServerWatcher.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QJsonValue>
#include <QMetaObject>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>

namespace {

QString encodedSegment(const QString& value)
{
    return QString::fromLatin1(QUrl::toPercentEncoding(value));
}

bool parseRevision(const QByteArray& body, qint64* revision)
{
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(body, &parseError);
    if (parseError.error != QJsonParseError::NoError
        || !document.isObject()) {
        return false;
    }
    const QJsonValue value = document.object().value(QStringLiteral("rev"));
    if (!value.isDouble()) {
        return false;
    }
    const double number = value.toDouble();
    if (number < 0
        || number > static_cast<double>(std::numeric_limits<qint64>::max())
        || std::floor(number) != number) {
        return false;
    }
    *revision = static_cast<qint64>(number);
    return true;
}

} // namespace

SyncServerWatcher::SyncServerWatcher(
    Config config, std::shared_ptr<SyncHttpClient> http, QObject* parent)
    : QObject(parent)
    , m_config(std::move(config))
    , m_http(std::move(http))
{
}

SyncServerWatcher::~SyncServerWatcher()
{
    stop();
}

void SyncServerWatcher::start()
{
    std::lock_guard<std::mutex> lifecycleLock(m_stateMutex);
    if (m_thread.joinable()) {
        return;
    }
    m_stopRequested.store(false);
    m_threadFinished.store(false);
    const std::uint64_t generation = m_generation.fetch_add(1) + 1;
    m_running.store(true);
    m_thread = std::thread([this, generation] { run(generation); });
}

void SyncServerWatcher::stop()
{
    std::thread threadToJoin;
    {
        std::lock_guard<std::mutex> lifecycleLock(m_stateMutex);
        if (!m_thread.joinable()) {
            m_running.store(false);
            return;
        }
        m_stopRequested.store(true);
        m_running.store(false);
        m_wake.notify_all();
        threadToJoin = std::move(m_thread);
    }
    // 工作线程可能刚通过循环顶部的停止检查、还没把 data task 登记进 HTTP 客户端。
    // 单次 cancelAll 会漏掉这个窗口；反复取消并最多等待 20 毫秒，直到线程真正退出。
    while (!m_threadFinished.load()) {
        if (m_http) {
            m_http->cancelAll();
        }
        std::unique_lock<std::mutex> lock(m_stateMutex);
        m_wake.wait_for(lock, std::chrono::milliseconds(20),
                        [this] { return m_threadFinished.load(); });
    }
    if (threadToJoin.joinable()) {
        threadToJoin.join();
    }
}

bool SyncServerWatcher::isRunning() const
{
    return m_running.load();
}

QUrl SyncServerWatcher::watchUrl(bool haveRevision, qint64 revision) const
{
    QUrl url = m_config.baseUrl;
    QString path = url.path(QUrl::FullyEncoded);
    while (path.endsWith(QLatin1Char('/'))) {
        path.chop(1);
    }
    path += QStringLiteral("/v1/spaces/")
        + encodedSegment(m_config.spaceId) + QStringLiteral("/watch");
    url.setPath(path, QUrl::StrictMode);
    url.setQuery(
        QStringLiteral("rev=%1&timeout=%2")
            .arg(haveRevision ? revision : 0)
            .arg(haveRevision ? std::max(0, m_config.waitSeconds) : 0));
    url.setFragment(QString());
    return url;
}

SyncServerWatcher::WatchResult SyncServerWatcher::watchOnce(
    bool haveRevision, qint64 revision) const
{
    WatchResult result;
    if (!m_http) {
        result.error = QStringLiteral("同步通知未配置 HTTP 客户端");
        return result;
    }
    SyncHttpClient::Request request;
    request.method = QByteArrayLiteral("GET");
    request.url = watchUrl(haveRevision, revision);
    request.timeoutMs
        = (std::max(0, m_config.waitSeconds) + 15) * 1000;
    request.headers = {
        {QByteArrayLiteral("Authorization"),
         QByteArrayLiteral("Bearer ") + m_config.authToken.toUtf8()},
        {QByteArrayLiteral("User-Agent"),
         QByteArrayLiteral("PomodoroTodo-sync/1")},
    };
    const SyncHttpClient::Response response = m_http->send(request);
    if (response.failure == SyncHttpClient::Failure::Timeout) {
        result.error = QStringLiteral("同步服务器响应超时");
        return result;
    }
    if (response.failure == SyncHttpClient::Failure::Network) {
        result.error = response.message.isEmpty()
            ? QStringLiteral("连不上同步服务器")
            : QStringLiteral("连不上同步服务器：%1").arg(response.message);
        return result;
    }
    if (response.failure == SyncHttpClient::Failure::Cancelled) {
        result.error = QStringLiteral("同步通知已取消");
        return result;
    }
    if (response.status != 200) {
        result.error = QStringLiteral("同步服务器通知请求失败（HTTP %1）")
                           .arg(response.status);
        return result;
    }
    if (!parseRevision(response.body, &result.rev)) {
        result.error = QStringLiteral("同步服务器通知响应不合法");
        return result;
    }
    result.ok = true;
    return result;
}

bool SyncServerWatcher::waitForRetry(int delayMs)
{
    std::unique_lock<std::mutex> lock(m_stateMutex);
    return !m_wake.wait_for(
        lock, std::chrono::milliseconds(std::max(0, delayMs)),
        [this] { return m_stopRequested.load(); });
}

void SyncServerWatcher::queueChanged(std::uint64_t generation)
{
    QMetaObject::invokeMethod(
        this,
        [this, generation] {
            if (m_running.load() && m_generation.load() == generation
                && !m_stopRequested.load()) {
                emit changed();
            }
        },
        Qt::QueuedConnection);
}

void SyncServerWatcher::run(std::uint64_t generation)
{
    bool haveRevision = false;
    qint64 knownRevision = 0;
    int retryMs = std::max(0, m_config.retryMinMs);
    const int retryMaxMs
        = std::max(retryMs, m_config.retryMaxMs);
    QString lastError;
    bool recoveryPending = false;

    while (!m_stopRequested.load()) {
        const WatchResult result = watchOnce(haveRevision, knownRevision);
        if (m_stopRequested.load()) {
            break;
        }
        if (!result.ok) {
            if (result.error != lastError) {
                qInfo().noquote()
                    << QStringLiteral("同步服务器通知出错：%1").arg(result.error);
                lastError = result.error;
            }
            recoveryPending = true;
            if (!waitForRetry(retryMs)) {
                break;
            }
            retryMs = std::min(
                retryMs == 0 ? std::max(1, m_config.retryMinMs) : retryMs * 2,
                retryMaxMs);
            continue;
        }

        if (recoveryPending) {
            qInfo().noquote() << QStringLiteral("同步服务器通知已恢复");
        }
        lastError.clear();
        recoveryPending = false;
        retryMs = std::max(0, m_config.retryMinMs);

        if (!haveRevision) {
            haveRevision = true;
            knownRevision = result.rev;
            continue;
        }
        if (result.rev != knownRevision) {
            knownRevision = result.rev;
            queueChanged(generation);
        }
    }

    if (m_generation.load() == generation) {
        m_running.store(false);
    }
    m_threadFinished.store(true);
    m_wake.notify_all();
}
