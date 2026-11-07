#ifndef SYNCSERVERWATCHER_H
#define SYNCSERVERWATCHER_H

#include "SyncHttpClient.h"

#include <QObject>
#include <QString>
#include <QUrl>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>

// 在独立线程里挂服务器的 watch 长轮询。首次请求只记录当前 rev，不发信号；
// 之后 rev 发生变化才排队通知对象所在线程。HTTP 实例必须只归 watcher 使用，
// 因为 stop() 会取消它上面所有在途请求。
class SyncServerWatcher : public QObject
{
    Q_OBJECT

public:
    struct Config {
        QUrl baseUrl;
        QString spaceId;
        QString authToken;
        int waitSeconds = 25;
        int retryMinMs = 5000;
        int retryMaxMs = 60000;
    };

    SyncServerWatcher(Config config, std::shared_ptr<SyncHttpClient> http,
                      QObject* parent = nullptr);
    ~SyncServerWatcher() override;

    void start();
    void stop();
    bool isRunning() const;

signals:
    void changed();

private:
    struct WatchResult {
        bool ok = false;
        qint64 rev = 0;
        QString error;
    };

    void run(std::uint64_t generation);
    WatchResult watchOnce(bool haveRevision, qint64 revision) const;
    bool waitForRetry(int delayMs);
    void queueChanged(std::uint64_t generation);
    QUrl watchUrl(bool haveRevision, qint64 revision) const;

    Config m_config;
    std::shared_ptr<SyncHttpClient> m_http;
    mutable std::mutex m_stateMutex;
    std::condition_variable m_wake;
    std::thread m_thread;
    std::atomic_bool m_running{false};
    std::atomic_bool m_stopRequested{false};
    std::atomic<std::uint64_t> m_generation{0};
};

#endif // SYNCSERVERWATCHER_H
