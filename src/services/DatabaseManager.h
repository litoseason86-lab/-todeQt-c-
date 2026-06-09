#ifndef DATABASEMANAGER_H
#define DATABASEMANAGER_H

#include <QObject>
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

    QString m_connectionName;
    QSqlDatabase m_db;
};

#endif // DATABASEMANAGER_H
