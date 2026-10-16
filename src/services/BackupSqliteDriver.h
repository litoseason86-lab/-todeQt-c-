#ifndef BACKUPSQLITEDRIVER_H
#define BACKUPSQLITEDRIVER_H

#include "BackupOperationControl.h"
#include <QSqlDriver>

struct sqlite3;

// 只供备份操作使用的连接适配器：保留现有QSqlQuery校验契约，自行创建独立SQLite连接。
// 它不包装、借用或关闭Qt QSQLITE插件的任何native句柄，也不向业务主库注册为默认驱动。
class BackupSqliteDriver final : public QSqlDriver
{
public:
    explicit BackupSqliteDriver(BackupOperation operation);
    ~BackupSqliteDriver() override;
    bool hasFeature(DriverFeature feature) const override;
    bool open(const QString& path, const QString&, const QString&, const QString&, int,
              const QString& options) override;
    void close() override;
    QSqlResult* createResult() const override;
    bool beginTransaction() override;
    bool commitTransaction() override;
    bool rollbackTransaction() override;
    sqlite3* connection() const { return m_database; }
    const BackupOperation& operation() const { return m_operation; }
private:
    bool transactionStatement(const char* sql, bool cleanup = false);
    static int progress(void* context);
    static int busy(void* context, int count);
    sqlite3* m_database = nullptr;
    BackupOperation m_operation;
};

#endif
