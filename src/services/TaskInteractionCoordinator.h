#pragma once
#include <QObject>
#include <QHash>
#include <QPointer>
#include <QVariantMap>
#include <QSet>

class TaskManager;

// 登记只存交互事实，不依赖 MCP。QObject 销毁兜底与显式结束共用幂等释放路径。
class TaskInteractionCoordinator : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool refreshBlocked READ refreshBlocked NOTIFY changed)
    Q_PROPERTY(QString lastError READ lastError NOTIFY changed)
public:
    enum Kind { Editing, Dragging, PendingDelete };
    Q_ENUM(Kind)
    struct Entry { QPointer<QObject> owner; Kind kind; int taskId; QString source; QMetaObject::Connection destroyed; };
    explicit TaskInteractionCoordinator(TaskManager* tasks, QObject* parent = nullptr);
    Q_INVOKABLE QVariantMap beginEdit(QObject* owner, int taskId, const QString& source);
    Q_INVOKABLE bool beginDrag(QObject* owner, int taskId, const QString& source);
    Q_INVOKABLE void setPendingDelete(QObject* owner, int taskId);
    Q_INVOKABLE void end(QObject* owner);
    bool refreshBlocked() const;
    QString lastError() const { return m_error; }
    QSet<int> pendingTaskIds() const;
    QList<Entry> entries() const { return m_entries.values(); }
signals:
    void changed();
private:
    bool begin(QObject* owner, Kind kind, int taskId, const QString& source);
    TaskManager* m_tasks;
    QHash<QObject*, Entry> m_entries;
    QString m_error;
};
