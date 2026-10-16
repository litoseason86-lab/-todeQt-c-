#include "BackupSqliteDriver.h"

#include <QSqlError>
#include <QSqlField>
#include <QSqlRecord>
#include <QSqlResult>
#include <QThread>
#include <QVariant>
#include <sqlite3.h>

#include <limits>
#include <utility>

namespace {
QSqlError sqlError(sqlite3* database, int code)
{
    return QSqlError(QStringLiteral("备份SQLite操作失败"),
                     QString::fromUtf8(sqlite3_errmsg(database)),
                     QSqlError::StatementError, QString::number(code));
}

class BackupSqliteResult final : public QSqlResult
{
public:
    explicit BackupSqliteResult(const BackupSqliteDriver* driver)
        : QSqlResult(driver), m_driver(driver) {}
    ~BackupSqliteResult() override { finalize(); }
protected:
    bool prepare(const QString& sql) override
    {
        finalize();
        setLastError(QSqlError());
        setAt(QSql::BeforeFirstRow);
        if (!m_driver->connection() || !m_driver->operation()->checkpoint("sql-prepare")) {
            setLastError(QSqlError(QStringLiteral("备份操作停止"), m_driver->operation()->message(), QSqlError::StatementError));
            return false;
        }
        const QByteArray utf8 = sql.toUtf8();
        if (utf8.size() >= std::numeric_limits<int>::max()) return false;
        const char* tail = nullptr;
        const int code = sqlite3_prepare_v2(m_driver->connection(), utf8.constData(),
                                           static_cast<int>(utf8.size()), &m_statement, &tail);
        if (code != SQLITE_OK) {
            setLastError(sqlError(m_driver->connection(), code));
            return false;
        }
        if (!m_statement || (tail && !QByteArray(tail).trimmed().isEmpty())) {
            setLastError(QSqlError(QStringLiteral("备份SQL只允许单条语句"), QString(), QSqlError::StatementError));
            finalize();
            return false;
        }
        setSelect(sqlite3_column_count(m_statement) > 0);
        setQuery(sql);
        return true;
    }
    bool exec() override
    {
        if (!m_statement) return false;
        setLastError(QSqlError());
        sqlite3_reset(m_statement);
        sqlite3_clear_bindings(m_statement);
        for (int i = 0; i < boundValueCount(); ++i) {
            const QString name = boundValueName(i);
            const int index = name.isEmpty() ? i + 1
                : sqlite3_bind_parameter_index(m_statement, name.toUtf8().constData());
            if (!index) {
                setLastError(QSqlError(QStringLiteral("备份SQL参数缺失"), name, QSqlError::StatementError));
                return false;
            }
            const QVariant value = boundValue(i);
            int code = SQLITE_OK;
            if (value.isNull()) code = sqlite3_bind_null(m_statement, index);
            else if (value.metaType().id() == QMetaType::QByteArray) {
                const QByteArray bytes = value.toByteArray();
                code = sqlite3_bind_blob64(m_statement, index, bytes.constData(),
                    static_cast<sqlite3_uint64>(bytes.size()), SQLITE_TRANSIENT);
            } else if (value.metaType().id() == QMetaType::QString) {
                const QByteArray bytes = value.toString().toUtf8();
                code = sqlite3_bind_text64(m_statement, index, bytes.constData(),
                    static_cast<sqlite3_uint64>(bytes.size()), SQLITE_TRANSIENT, SQLITE_UTF8);
            } else if (value.metaType().id() == QMetaType::Double) {
                code = sqlite3_bind_double(m_statement, index, value.toDouble());
            } else {
                code = sqlite3_bind_int64(m_statement, index, value.toLongLong());
            }
            if (code != SQLITE_OK) {
                setLastError(sqlError(sqlite3_db_handle(m_statement), code));
                return false;
            }
        }
        setAt(QSql::BeforeFirstRow);
        setActive(true);
        m_firstRow = false;
        m_done = false;
        const int code = step();
        if (code == SQLITE_ROW) m_firstRow = true;
        return code == SQLITE_ROW || code == SQLITE_DONE;
    }
    bool reset(const QString& sql) override { return prepare(sql) && exec(); }
    bool fetchNext() override
    {
        if (m_done) return false;
        if (m_firstRow) m_firstRow = false;
        else if (step() != SQLITE_ROW) return false;
        setAt(at() < 0 ? 0 : at() + 1);
        return true;
    }
    bool fetch(int index) override
    {
        if (index < 0 || index < at()) return false;
        while (at() < index) if (!fetchNext()) return false;
        return true;
    }
    bool fetchFirst() override { return fetch(0); }
    bool fetchLast() override { return false; }
    QVariant data(int column) override
    {
        if (!m_statement || at() < 0 || column < 0 || column >= sqlite3_column_count(m_statement)) return {};
        switch (sqlite3_column_type(m_statement, column)) {
        case SQLITE_INTEGER: return QVariant::fromValue<qlonglong>(sqlite3_column_int64(m_statement, column));
        case SQLITE_FLOAT: return sqlite3_column_double(m_statement, column);
        case SQLITE_TEXT: return QString::fromUtf8(
            reinterpret_cast<const char*>(sqlite3_column_text(m_statement, column)), sqlite3_column_bytes(m_statement, column));
        case SQLITE_BLOB: return QByteArray(
            static_cast<const char*>(sqlite3_column_blob(m_statement, column)), sqlite3_column_bytes(m_statement, column));
        default: return {};
        }
    }
    bool isNull(int column) override { return !m_statement || sqlite3_column_type(m_statement, column) == SQLITE_NULL; }
    int size() override { return -1; }
    int numRowsAffected() override { return m_statement ? sqlite3_changes(sqlite3_db_handle(m_statement)) : 0; }
    QSqlRecord record() const override
    {
        QSqlRecord result;
        if (m_statement) {
            for (int i = 0; i < sqlite3_column_count(m_statement); ++i)
                result.append(QSqlField(QString::fromUtf8(sqlite3_column_name(m_statement, i)), QMetaType(QMetaType::QString)));
        }
        return result;
    }
    void detachFromResultSet() override
    {
        if (m_statement) sqlite3_reset(m_statement);
        m_done = true;
        m_firstRow = false;
        setAt(QSql::BeforeFirstRow);
    }
private:
    int step()
    {
        if (!m_driver->operation()->checkpoint("sql-step")) {
            setLastError(QSqlError(QStringLiteral("备份操作停止"), m_driver->operation()->message(), QSqlError::StatementError));
            m_done = true;
            return SQLITE_INTERRUPT;
        }
        const int code = sqlite3_step(m_statement);
        if (code != SQLITE_ROW) {
            m_done = true;
            if (code != SQLITE_DONE) setLastError(sqlError(sqlite3_db_handle(m_statement), code));
        }
        return code;
    }
    void finalize()
    {
        if (m_statement) sqlite3_finalize(m_statement);
        m_statement = nullptr;
        m_done = true;
        m_firstRow = false;
        setActive(false);
    }
    const BackupSqliteDriver* m_driver;
    sqlite3_stmt* m_statement = nullptr;
    bool m_firstRow = false;
    bool m_done = true;
};
}

BackupSqliteDriver::BackupSqliteDriver(BackupOperation operation)
    : m_operation(operation ? std::move(operation) : std::make_shared<BackupOperationControl>()) {}
BackupSqliteDriver::~BackupSqliteDriver() { close(); }

bool BackupSqliteDriver::hasFeature(DriverFeature feature) const
{
    return feature == Transactions || feature == BLOB || feature == Unicode
        || feature == PreparedQueries || feature == NamedPlaceholders
        || feature == PositionalPlaceholders || feature == FinishQuery;
}

bool BackupSqliteDriver::open(const QString& path, const QString&, const QString&, const QString&, int,
                              const QString& options)
{
    close();
    if (!m_operation->checkpoint("sql-open")) return false;
    const int flags = options.contains(QStringLiteral("QSQLITE_OPEN_READONLY"))
        ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE;
    // 只打开既有库；快照由VACUUM生成，不因拼错路径创建一个空数据库。
    const int code = sqlite3_open_v2(path.toUtf8().constData(), &m_database, flags | SQLITE_OPEN_NOMUTEX, nullptr);
    if (code != SQLITE_OK) {
        setLastError(sqlError(m_database, code));
        close();
        setOpenError(true);
        return false;
    }
    sqlite3_progress_handler(m_database, 1000, progress, this);
    sqlite3_busy_handler(m_database, busy, this);
    setOpen(true);
    setOpenError(false);
    return true;
}
void BackupSqliteDriver::close()
{
    if (m_database) {
        // 关闭前撤回持有this的回调；close_v2允许在当前作用域内稍后finalize仍存活的query。
        sqlite3_progress_handler(m_database, 0, nullptr, nullptr);
        sqlite3_busy_handler(m_database, nullptr, nullptr);
        sqlite3_close_v2(m_database);
        m_database = nullptr;
    }
    setOpen(false);
}
QSqlResult* BackupSqliteDriver::createResult() const { return new BackupSqliteResult(this); }
int BackupSqliteDriver::progress(void* context)
{
    return static_cast<BackupSqliteDriver*>(context)->m_operation->checkpoint("sql-progress") ? 0 : 1;
}
int BackupSqliteDriver::busy(void* context, int count)
{
    auto* driver = static_cast<BackupSqliteDriver*>(context);
    if (!driver->m_operation->checkpoint("sql-busy") || count >= 500) return 0;
    QThread::msleep(10);
    return 1;
}
bool BackupSqliteDriver::transactionStatement(const char* sql, bool cleanup)
{
    if (!m_database || (!cleanup && !m_operation->checkpoint("sql-transaction"))) return false;
    // 取消后仍须撤销未提交元数据；回滚期间关闭取消回调，不能把ROLLBACK自身取消掉。
    if (cleanup) sqlite3_progress_handler(m_database, 0, nullptr, nullptr);
    const int code = sqlite3_exec(m_database, sql, nullptr, nullptr, nullptr);
    if (cleanup) sqlite3_progress_handler(m_database, 1000, progress, this);
    if (code != SQLITE_OK) setLastError(sqlError(m_database, code));
    return code == SQLITE_OK;
}
bool BackupSqliteDriver::beginTransaction() { return transactionStatement("BEGIN"); }
bool BackupSqliteDriver::commitTransaction() { return transactionStatement("COMMIT"); }
bool BackupSqliteDriver::rollbackTransaction() { return transactionStatement("ROLLBACK", true); }
