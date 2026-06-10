#ifndef DATABASEMANAGER_H
#define DATABASEMANAGER_H

#include <QObject>
#include <QDir>
#include <QSqlDatabase>
#include <QString>

class DatabaseManager : public QObject
{
    Q_OBJECT

public:
    static DatabaseManager* instance();

    Q_INVOKABLE bool initialize(const QString& dbPath = QString());
    QSqlDatabase database() const;
    bool createTables();
    bool isOpen() const;
    void close();

private:
    explicit DatabaseManager(QObject* parent = nullptr);
    ~DatabaseManager() override;

    int getDatabaseVersion() const;
    bool setDatabaseVersion(int version);
    bool migrateToVersion2();
    bool createCategoriesTable();
    bool insertPresetCategories();
    bool migrateTaskCategories();
    QString generateColorForCategory(int index) const;
    bool backupDatabaseBeforeMigration() const;
    void pruneOldBackups(const QDir& databaseDir) const;
    bool tableExists(const QString& tableName) const;
    bool columnExists(const QString& tableName, const QString& columnName) const;

    QString m_connectionName;
    QSqlDatabase m_db;
};

#endif // DATABASEMANAGER_H
