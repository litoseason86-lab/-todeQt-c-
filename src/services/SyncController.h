#ifndef SYNCCONTROLLER_H
#define SYNCCONTROLLER_H

#include "SyncEngine.h"

#include <QByteArray>
#include <QDateTime>
#include <QObject>
#include <QString>
#include <QVariantList>

#include <functional>
#include <memory>

// 设备间同步在应用里的总开关（050 阶段 4）。
// 界面通过它开关同步、看状态、确认第一次加入、查同步日志；装配层（main.cpp）通过它把同步接到
// 恢复备份、逻辑日起点、前后台切换和退出上。真正读写同步文件夹的是 SyncEngine，这里只管什么时候开、停、换文件夹。
//
// 这里不做平台判断。Mac 与 iPad 的差别由装配层通过 Platform 注入：
// - Mac：文件夹固定在 iCloud 云盘的「番茄Todo同步」，可以新建；后台照常同步。
// - iPad：要在「文件」里选文件夹（选中后先校验标记文件），靠书签重新取得访问权；只在前台定时同步，
//   切到后台时向系统要一点时间把改动写完。
//
// 开关和 iPad 的书签存在 QSettings 的 sync/ 组。这一组不在备份范围内，恢复备份不会把它们改掉。
class SyncController : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool enabled READ isEnabled NOTIFY enabledChanged)
    // 同步现在处在哪个状态，给界面分支用：stopped、starting、upToDate、needsConfirmation、waitingForSnapshot、
    // folderUnavailable、wrongFolder、folderMissing、noSpace、uploadFailed、newerVersion、backupFailed、error。
    Q_PROPERTY(QString statusKey READ statusKey NOTIFY statusChanged)
    // 同步没走通、要你知道或处理（界面据此换提醒色）。等你确认加入不算：那是正常的一步。
    Q_PROPERTY(bool hasProblem READ hasProblem NOTIFY statusChanged)
    // 一句话的状态，放在设置行的说明里。
    Q_PROPERTY(QString summaryText READ summaryText NOTIFY statusChanged)
    // 完整的说明：发生了什么、下一步怎么做。
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusChanged)
    // 具体原因（系统给的错误说明、选错了哪一层）。没有时为空。
    Q_PROPERTY(QString statusDetail READ statusDetail NOTIFY statusChanged)
    Q_PROPERTY(int pendingCount READ pendingCount NOTIFY statusChanged)
    Q_PROPERTY(QDateTime lastSyncedAt READ lastSyncedAt NOTIFY statusChanged)
    Q_PROPERTY(bool busy READ isBusy NOTIFY statusChanged)
    // 这台设备要自己选同步文件夹（iPad）。Mac 的位置固定，不用选。
    Q_PROPERTY(bool choosesFolder READ choosesFolder CONSTANT)
    Q_PROPERTY(bool hasFolder READ hasFolder NOTIFY folderChanged)
    Q_PROPERTY(QString folderDisplayPath READ folderDisplayPath NOTIFY folderChanged)
    // 正在弹选择器，或者正在校验选中的文件夹。
    Q_PROPERTY(bool choosingFolder READ isChoosingFolder NOTIFY choosingFolderChanged)
    // 上次选的文件夹为什么没用上（选错了哪一层、读不了……）。选好了、或者又去选的时候清空。
    // 就地显示在设置页里：提示条在主窗口上，会被设置弹窗盖住。
    Q_PROPERTY(QString folderProblem READ folderProblem NOTIFY choosingFolderChanged)
    // 同步日志变了就加一，界面据此重新读。
    Q_PROPERTY(int logRevision READ logRevision NOTIFY logChanged)
    Q_PROPERTY(int logCount READ logCount NOTIFY logChanged)

public:
    // 装配层按平台给的几样东西。
    struct Platform {
        // 按书签建同步文件夹的访问对象。Mac 忽略书签，用固定位置。
        // bookmarkRefreshed 在同步的工作线程里调用（系统把书签标为过期、重新生成了一份）。
        std::function<std::unique_ptr<SyncFolder>(const QByteArray& bookmark,
                                                  std::function<void(const QByteArray&)> bookmarkRefreshed)>
            makeFolder;
        // iPad：弹出「文件」选择器，done 在界面线程里调用；书签为空表示取消或失败，message 说明原因，
        // 成功时 message 是选中文件夹的路径。Mac 为空：位置固定，不用选。
        std::function<void(std::function<void(const QByteArray& bookmark, const QString& message)> done)>
            pickFolder;
        // iPad：切到后台时向系统要一点时间，返回结束它的函数。Mac 为空。
        std::function<std::function<void()>()> backgroundTask;
        // 位置固定时给人看的路径（Mac）。iPad 显示选中时记下的路径。
        QString fixedFolderDisplayPath;
        SyncEngine::Options engine;
    };

    explicit SyncController(Platform platform, QObject* parent = nullptr);
    ~SyncController() override;

    // 整体换掉本机数据之前的自动备份（接 BackupService），返回 false 时不替换。要在 initialize 之前设置。
    void setSafetyBackup(std::function<bool(QString* error)> backup);
    // 启动时调用一次，数据库已经打开：核对逻辑日起点；上次开着同步，就接着同步。
    void initialize();
    // 前后台切换。只有 iPad 接：Mac 常驻，后台照常同步。
    void setForeground(bool foreground);
    // 恢复备份开始前、结束后（接 BackupService 的 restoreStarted、restoreCompleted）。
    void prepareForRestore();
    void finishRestore(bool success);
    // 退出前（aboutToQuit，必须排在关库之前）：把攒下的改动写出去，最多等 timeoutMs。
    void shutdown(int timeoutMs);

    bool isEnabled() const { return m_enabled; }
    QString statusKey() const;
    bool hasProblem() const;
    QString summaryText() const;
    QString statusText() const;
    QString statusDetail() const;
    int pendingCount() const;
    QDateTime lastSyncedAt() const;
    bool isBusy() const;
    bool choosesFolder() const;
    bool hasFolder() const;
    QString folderDisplayPath() const;
    bool isChoosingFolder() const { return m_choosingFolder; }
    QString folderProblem() const { return m_folderProblem; }
    int logRevision() const { return m_logRevision; }
    int logCount() const;

    // 没开过同步时为空。测试读引擎状态用。
    SyncEngine* engine() const { return m_engine.get(); }

    // 开关同步。iPad 还没选过文件夹时，打开等于先去选文件夹，选好、校验通过才算开了。
    Q_INVOKABLE void setEnabled(bool enabled);
    // 第一次加入：确认用同步文件夹里的数据换掉本机数据（本机的先自动备份）。
    Q_INVOKABLE void confirmJoin();
    Q_INVOKABLE void syncNow();
    // iPad：选（或重新选）同步文件夹。
    Q_INVOKABLE void chooseFolder();
    // 同步文件夹不见了之后：Mac 在原处重新建一个（新的文件夹身份），iPad 重新选。
    Q_INVOKABLE void rebuildFolder();
    // 同步日志，新的在前。每一项是给界面直接显示的文字。
    Q_INVOKABLE QVariantList syncLog(int limit = 200) const;

signals:
    void enabledChanged();
    void statusChanged();
    void folderChanged();
    void choosingFolderChanged();
    void logChanged();
    // 要用提示条告诉你的事：已经加入、另一台设备恢复了备份、选错了文件夹……
    void notice(const QString& message);

private:
    void ensureEngine();
    void startEngine();
    void setEnabledState(bool enabled);
    void setChoosingFolder(bool choosing, const QString& problem = QString());
    void checkChosenFolder(const QByteArray& bookmark, const QString& displayPath);
    std::unique_ptr<SyncFolder> makeFolder(const QByteArray& bookmark);
    QByteArray storedBookmark() const;
    void acceptFolder(const QByteArray& bookmark, const QString& displayPath);
    void onBookmarkRefreshed(quint64 folderGeneration, const QByteArray& bookmark);
    void onCycleFinished();
    void refreshLog();
    void recordDayStartHour();
    void reconcileDayStartHour();

    Platform m_platform;
    std::function<bool(QString*)> m_safetyBackup;
    std::unique_ptr<SyncEngine> m_engine;
    bool m_enabled = false;
    bool m_initialized = false;
    bool m_choosingFolder = false;
    QString m_folderProblem;
    // 每换一次文件夹加一：旧文件夹在工作线程里刷新的书签，回来时已经不是现在用的了，不能存。
    quint64 m_folderGeneration = 0;
    // 你刚确认了加入：这一轮做完时告诉你本机数据已经换成同步文件夹里的。
    bool m_joinRequested = false;
    // 上一轮结束时本机的纪元与加入的文件夹：纪元变了、文件夹没换，说明另一台设备恢复了备份、本机跟着换了数据；
    // 文件夹从无到有，说明刚建好（Mac）或刚加入（iPad）。据此给你一句提示。
    qint64 m_knownEpoch = -1;
    QString m_knownFolderId;
    // 同步日志里最新一条的编号：变了才通知界面重新读。
    qint64 m_lastLogId = -1;
    int m_logRevision = 0;

    // 恢复备份开始前记下的：恢复之后据此开新纪元，并保留本机的设备标识和加入的文件夹。
    struct RestoreState {
        bool pending = false;
        qint64 epoch = 0;
        QString deviceId;
        QString folderId;
    };
    RestoreState m_restore;
};

#endif // SYNCCONTROLLER_H
