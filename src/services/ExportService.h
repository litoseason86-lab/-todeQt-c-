#ifndef EXPORTSERVICE_H
#define EXPORTSERVICE_H

#include <QDate>
#include <QObject>
#include <QSaveFile>
#include <QString>
#include <QTextStream>
#include <QVariant>

class ExportService : public QObject
{
    Q_OBJECT

public:
    static ExportService* instance();

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

private:
    explicit ExportService(QObject* parent = nullptr);

    // 私有函数把日期、CSV 转义和实际写文件拆开，避免导出任务和专注记录互相复制大段代码。
    QDate normalizeDate(const QVariant& value) const;
    QString escapeCsvField(const QString& field) const;
    QString formatDateTime(const QVariant& value) const;
    QString categoryExpression() const;
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
