#ifndef SYNCENGINE_H
#define SYNCENGINE_H

#include "SyncFolder.h"
#include "SyncStore.h"
#include "SyncWorker.h"

#include <QDateTime>
#include <QElapsedTimer>
#include <QHash>
#include <QObject>
#include <QSet>
#include <QString>
#include <QTimer>

#include <functional>
#include <memory>

class QThreadPool;

// 设备间同步的云盘传输（050 阶段 3）：什么时候写出本机的改动、什么时候读对方的，以及同步现在是什么状态。
//
// 一轮同步的步骤（全部在主线程里调度，文件操作交给工作线程排队执行）：
//   1. 打开文件夹、读标记文件，确认本机是这个同步文件夹的成员（Mac 可以新建；第一次加入要你确认）；
//   2. 写出本机攒下的改动（前台时最多约 30 秒写一批，切到后台、退出时立即写）；
//   3. 按序读对方的改动，逐批应用到库里，并记下读到了第几批；
//   4. 把「读到了第几批」写进本机的游标文件，对方据此清理双方都用过的旧文件。
// 库只在主线程里读写（SQLite 的连接不跨线程）；读文件、等 iCloud 下载可能要一两秒，放在工作线程，界面不卡。
//
// 这里不做平台判断：文件夹在哪、怎么访问由调用方给的 SyncFolder 决定；Mac 与 iPad 的差别
// （能不能新建文件夹、后台时还跑不跑）通过 Options 传进来。
class SyncEngine : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool running READ isRunning NOTIFY statusChanged)
    Q_PROPERTY(bool busy READ isBusy NOTIFY statusChanged)
    Q_PROPERTY(Status status READ status NOTIFY statusChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusChanged)
    Q_PROPERTY(int pendingCount READ pendingCount NOTIFY statusChanged)
    Q_PROPERTY(QDateTime lastSyncedAt READ lastSyncedAt NOTIFY statusChanged)

public:
    enum class Status {
        // 没有开启同步。
        Stopped,
        // 刚开启，第一轮还没做完。
        Starting,
        UpToDate,
        // 第一次加入这个同步文件夹：本机数据会先自动备份、再换成文件夹里的，等你确认。
        NeedsConfirmation,
        // 文件夹里还没有可以起步的快照（Mac 刚建好文件夹、快照还在上传）。
        WaitingForSnapshot,
        // 整个文件夹用不了：没登录 Apple ID、关了 iCloud 云盘、书签失效、没有权限。
        FolderUnavailable,
        // 选中的不是同步文件夹（状态文字里说明选错了哪一层）。
        WrongFolder,
        // 已经加入的同步文件夹不见了（标记文件被删掉或移走）。不会自动重建，免得另起一个文件夹。
        FolderMissing,
        // 本机空间不足，改动写不出去（还留在本机，空间够了再写）。
        NoSpace,
        // 改动写进了同步文件夹，但上传到 iCloud 出错（例如 iCloud 空间已满）。
        UploadFailed,
        // 对方用了更新版本的应用，它写的文件本机读不懂。
        NewerVersion,
        // 要整体换掉本机数据之前的自动备份失败了，暂不替换。
        BackupFailed,
        // 其它读写或数据库错误，稍后重试。
        Error,
    };
    Q_ENUM(Status)

    struct Options {
        // Mac 可以在空文件夹里新建同步文件夹；iPad 只能加入 Mac 建好的。
        bool mayCreateFolder = false;
        // Mac 常驻菜单栏，后台照常同步；iPad 进了后台很快会被系统挂起，只在前台时定时同步。
        bool runInBackground = true;
        // 检查「该不该同步一轮」的节拍。
        int tickMs = 5000;
        // 两次写出改动至少隔这么久（攒批）：049 实测刚同步来的文件每读一个约 1 秒，文件越少越好。
        int publishIntervalMs = 30000;
        // 前台时每隔这么久读一次对方的改动。
        int scanIntervalMs = 20000;
        // 出错后的重试间隔：从最短开始、每次翻倍，封顶到最长。回到前台、手动同步时立即重试。
        int retryMinMs = 30000;
        int retryMaxMs = 5 * 60 * 1000;
        // 一轮最多读多少个文件，读不完的紧接着下一轮继续。
        int maxFilesPerScan = 30;
        // 落后对方这么多批、而它的快照覆盖得到时，直接合并快照，不再一个个下载改动文件。
        int catchUpViaSnapshot = 30;
        // 自上一份快照以来本机又写了这么多批，就写一份新快照；旧改动文件要有快照兜底才能删。
        int compactAfterFiles = 50;
        // 维护（看各设备读到了哪里、写快照、删旧文件）的间隔。
        int maintenanceIntervalMs = 5 * 60 * 1000;
        // 对方某一批迟迟不到（它后面的已经到了）超过这么久，就请它补一份快照。
        int gapRequestAfterMs = 2 * 60 * 1000;
        // 对方的游标文件这么多天没更新，就当它不再使用，不再为它保留旧改动文件（它回来时从快照追上）。
        // iPad 的免费签名每 7 天到期，一两周不开很正常，所以取 14 天。
        int peerStaleDays = 14;
    };

    // folder：同步文件夹的访问对象。构造要轻，真正取访问权在工作线程里做。
    // connectionName 为空时用应用主连接；测试用它同时跑两台「设备」。
    SyncEngine(std::unique_ptr<SyncFolder> folder, const Options& options, const QString& connectionName = QString(),
               QObject* parent = nullptr);
    ~SyncEngine() override;

    // 整体换掉本机数据（首次加入、另一台恢复了备份）之前调用，返回 false 时不替换。
    // 生产环境接自动备份；没设置时直接替换（只给测试用）。
    void setSafetyBackup(std::function<bool(QString* error)> backup);
    // 改动提交之后怎么通知界面。默认是 SyncNotifier::publish；测试里两台设备不共用单例服务，换成记录。
    void setChangeNotifier(std::function<void(const SyncStore::ApplyResult&)> notifier);
    // 换一个同步文件夹（iPad 重新选了文件夹）。正在进行的一轮作废，下一轮用新的。
    void setFolder(std::unique_ptr<SyncFolder> folder);
    // 切到后台时向系统要一点时间把改动写完（iPad 用 UIApplication 的后台任务；Mac 不需要，不设置）。
    // provider 开始一个后台任务，返回结束它的函数：写完、引擎停下或回到前台时调用。
    void setBackgroundTaskProvider(std::function<std::function<void()>()> provider);

    void start();
    void stop();
    // 第一次加入：你确认可以用文件夹里的数据换掉本机数据（本机的先自动备份）。
    Q_INVOKABLE void confirmJoin();
    // 立即同步一轮：出错后的等待也一并取消。
    Q_INVOKABLE void syncNow();
    // 前后台切换。回到前台立即同步一轮（049：后台期间对方写的文件几秒内就能看到）；
    // 离开前台立即写出攒下的改动。
    void setForeground(bool foreground);
    // 退出前把攒下的改动同步写出去，最多等 timeoutMs。返回是否写成（或者本来就没有要写的）。
    bool flushBeforeExit(int timeoutMs);

    bool isRunning() const { return m_running; }
    bool isBusy() const { return m_inCycle; }
    // 这一轮做完了，也没有排着要紧接着做的下一轮。
    bool isIdle() const { return !m_inCycle && !m_cycleRequested; }
    Status status() const { return m_status; }
    QString statusText() const;
    QString statusDetail() const { return m_detail; }
    int pendingCount() const { return m_pendingCount; }
    QDateTime lastSyncedAt() const { return m_lastSyncedAt; }

signals:
    void statusChanged();
    // 一轮同步做完（不论成败）。测试据此等待。
    void cycleFinished();

private:
    // 一轮同步里的各步。每一步把文件操作交给工作线程，结果回到主线程后接着走下一步。
    void requestCycle();
    void startCycle();
    void afterOpen(const SyncWorker::OpenResult& result);
    void createFolder();
    void joinFolder(const QString& folderId, const QString& creator);
    void publishStep();
    void publishFullSnapshot();
    void publishChanges();
    void scanStep();
    void afterScan(const SyncWorker::ScanResult& result);
    // 另一台设备恢复了备份：本机整体换成它的新纪元快照（先自动备份）。
    void adopt(const SyncWorker::Adoption& adoption);
    void writeCursorStep();
    void maintenanceStep();
    void afterSurvey(const SyncWorker::Survey& survey);
    void cleanupStep(const SyncWorker::Survey& survey);
    void finishCycle(Status failure = Status::UpToDate, const QString& detail = QString());

    // 用一份快照整体换掉本机数据：先自动备份，再替换，再按快照里记的进度重设游标。
    bool replaceFromSnapshot(const QString& source, const SyncFiles::SnapshotFile& snapshot, Status* failure,
                             QString* error);
    void notify(const SyncStore::ApplyResult& result);
    void warn(Status status, const QString& detail);
    void endBackgroundTask();
    void onTick();
    void updateTimer();
    void refreshPending();
    qint64 nowMs() const { return m_clock.elapsed(); }

    // 把一个文件操作交给工作线程；done 在主线程里执行。引擎停下或换了文件夹之后，旧操作的结果直接丢掉。
    template <typename Result, typename Job, typename Done>
    void runOnWorker(Job job, Done done);

    SyncStore store() const { return SyncStore(m_connection); }

    Options m_options;
    QString m_connection;
    std::shared_ptr<SyncWorker> m_worker;
    // 只有一个线程的线程池：文件操作排成一队，一个做完再做下一个。
    std::shared_ptr<QThreadPool> m_pool;
    std::function<bool(QString*)> m_safetyBackup;
    std::function<void(const SyncStore::ApplyResult&)> m_notifier;
    std::function<std::function<void()>()> m_backgroundTaskProvider;
    // 正在进行的后台任务的结束函数；没有时为空。
    std::function<void()> m_endBackgroundTask;

    QTimer m_tick;
    QElapsedTimer m_clock;
    bool m_running = false;
    bool m_foreground = true;
    bool m_inCycle = false;
    bool m_cycleRequested = false;
    // 每次停下、换文件夹都加一：还在路上的旧结果据此认出来丢掉。
    quint64 m_generation = 0;
    bool m_joinConfirmed = false;
    // 下一次写出不管攒批间隔，有改动就写（切到后台、手动同步）。
    bool m_flushRequested = false;
    // 切到后台了，要来一轮「只写不读」（后台时间有限）。一轮开始时据此定下这一轮的做法：
    // 切到后台时恰好有一轮在进行，要等它做完再来这一轮，不能让它顺手把标记清掉。
    bool m_backgroundFlushPending = false;
    // 这一轮只写不读。
    bool m_cycleFlushOnly = false;
    // 游标变了还没写进游标文件。
    bool m_cursorDirty = false;
    // 上次写游标文件的时刻（墙上时间）：没变化也每天写一次，对方据此知道本机还在用，不会把本机当成不再使用的设备。
    qint64 m_lastCursorWrittenMs = -1;
    // 刚整体替换过（加入、采用新纪元）或刚写了快照：本轮就做一次维护，把用不上的旧文件清掉。
    bool m_maintenanceDue = false;
    qint64 m_lastMaintenanceMs = -1;
    // 对方某一批从什么时候开始一直没到（设备 → 时刻）。
    QHash<QString, qint64> m_gapSinceMs;
    // 已经记过日志的坏快照：同一份每轮都会读到，只记一次。
    QSet<QString> m_loggedBadFiles;
    qint64 m_lastPublishMs = -1;
    qint64 m_lastScanMs = -1;
    qint64 m_retryAtMs = 0;
    int m_retryDelayMs = 0;
    QString m_lastWrittenPath;

    // 这一轮里遇到的、不必中断整轮的问题（上传失败、某个文件读不懂……），收尾时挑最要紧的一个显示。
    QList<QPair<Status, QString>> m_warnings;

    Status m_status = Status::Stopped;
    QString m_detail;
    int m_pendingCount = 0;
    QDateTime m_lastSyncedAt;
    // 上次把「上次同步时刻」存进库的时刻：每轮都存会让库文件每 20 秒改一次，隔一分钟以上才存。
    qint64 m_lastSyncedSavedMs = -1;
};

#endif // SYNCENGINE_H
