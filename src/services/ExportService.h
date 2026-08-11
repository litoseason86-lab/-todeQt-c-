#ifndef EXPORTSERVICE_H
#define EXPORTSERVICE_H

#include <QDate>
#include <QObject>
#include <QSaveFile>
#include <QString>
#include <QTextStream>
#include <QSqlDatabase>
#include <QVariant>

#include <functional>

class ExportService : public QObject
{
    Q_OBJECT
    // 导出进行中：界面据此禁用重复触发并显示进度。
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)

public:
    static ExportService* instance();

    bool busy() const { return m_busy; }

    // —— 异步导出 ——
    // 同步版会把 GUI 线程一直占住：实测 2 万行专注记录约 190ms，掉十来帧，
    // 而且那段时间"进度"根本渲染不出来。这三个把工作放到线程池，
    // 用各自的只读连接查库（QSqlDatabase 连接不能跨线程共享）。
    // 同步版保留给测试和不需要进度的场景。
    Q_INVOKABLE void requestExportTasks(const QVariant& startDateValue,
                                        const QVariant& endDateValue,
                                        const QString& filePath);
    Q_INVOKABLE void requestExportFocusSessions(const QVariant& startDateValue,
                                                const QVariant& endDateValue,
                                                const QString& filePath);
    Q_INVOKABLE void requestExportAll(const QVariant& startDateValue,
                                      const QVariant& endDateValue,
                                      const QString& dirPath);

    // 导出接口接收 QVariant 日期，是为了兼容 QML Date 和测试里的字符串日期。
    Q_INVOKABLE bool exportTasks(const QVariant& startDateValue,
                                 const QVariant& endDateValue,
                                 const QString& filePath);
    Q_INVOKABLE bool exportFocusSessions(const QVariant& startDateValue,
                                         const QVariant& endDateValue,
                                         const QString& filePath);
    Q_INVOKABLE bool exportAll(const QVariant& startDateValue,
                               const QVariant& endDateValue,
                               const QString& dirPath);
    Q_INVOKABLE QString generateFileName(const QString& type,
                                         const QVariant& startDateValue,
                                         const QVariant& endDateValue) const;

signals:
    // 进度和完成信号让导出弹窗不用轮询文件写入状态。
    void exportProgress(int current, int total);
    void exportCompleted(bool success, const QString& message);
    void busyChanged();

private:
    explicit ExportService(QObject* parent = nullptr);

    // 工作线程要用自己的连接：QSqlDatabase 只能在创建它的线程上使用。
    // 主线程上直接复用 DatabaseManager 的连接，不额外开。
    QSqlDatabase acquireDatabase(QString* ownedConnectionName) const;
    static void releaseDatabase(const QString& ownedConnectionName);
    void setBusy(bool busy);
    // 三种导出共用的异步外壳：占住 busy、丢到线程池、回到 GUI 线程报结果。
    void runAsync(const std::function<bool()>& work);

    bool m_busy = false;

    // 私有函数把日期、CSV 转义和实际写文件拆开，避免导出任务和专注记录互相复制大段代码。
    QDate normalizeDate(const QVariant& value) const;
    QString escapeCsvField(const QString& field) const;
    QString formatDateTime(const QVariant& value) const;
    QString categoryExpression() const;
    QString sessionCategoryExpression() const;
    int countRows(const QString& fromAndWhereSql,
                  const QDate& startDate,
                  const QDate& endDate) const;
    bool exportTasksToFile(const QDate& startDate,
                           const QDate& endDate,
                           const QString& filePath,
                           bool emitSuccess);
    bool exportFocusSessionsToFile(const QDate& startDate,
                                   const QDate& endDate,
                                   const QString& filePath,
                                   bool emitSuccess);
    bool finishCsvFile(QSaveFile& file,
                       QTextStream& stream,
                       const QString& successMessage,
                       bool emitSuccess);
    bool commitExportPair(const QString& stagedTasksPath,
                          const QString& tasksPath,
                          const QString& stagedSessionsPath,
                          const QString& sessionsPath);
};

#endif // EXPORTSERVICE_H
