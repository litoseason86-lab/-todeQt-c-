#ifndef EXPORTSERVICE_H
#define EXPORTSERVICE_H

#include <QDate>
#include <QFile>
#include <QObject>
#include <QString>
#include <QTextStream>
#include <QVariant>

class ExportService : public QObject
{
    Q_OBJECT

public:
    static ExportService* instance();

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
    void exportProgress(int current, int total);
    void exportCompleted(bool success, const QString& message);

private:
    explicit ExportService(QObject* parent = nullptr);

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
    bool finishCsvFile(QFile& file,
                       QTextStream& stream,
                       const QString& successMessage,
                       bool emitSuccess);
};

#endif // EXPORTSERVICE_H
