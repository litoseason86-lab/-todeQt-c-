#include "PTBridgeSupport.h"
#include <QHash>
#include <QThread>
#include <limits>

namespace PTBridgeSupport {
namespace {
QHash<QString, QPointer<QObject>> &registry() {
    static QHash<QString, QPointer<QObject>> objects;
    return objects;
}
}
void registerService(const QString &name, QObject *service)
{
    NSCAssert(NSThread.isMainThread, @"服务只能在主线程登记");
    Q_ASSERT(!service || service->thread() == QThread::currentThread());
    if (service) registry().insert(name, service);
    else registry().remove(name);
}
QObject *registeredService(const QString &name)
{
    NSCAssert(NSThread.isMainThread, @"服务只能在主线程读取");
    return registry().value(name).data();
}
FailureCollector::Call::Call(FailureCollector &collector) : m_collector(collector)
{
    m_collector.m_calls.append(&m_error);
}
FailureCollector::Call::~Call()
{
    Q_ASSERT(!m_collector.m_calls.isEmpty() && m_collector.m_calls.last() == &m_error);
    m_collector.m_calls.removeLast();
}
bool FailureCollector::collect(const QString &message)
{
    if (m_calls.isEmpty()) return false;
    if (m_calls.last()->isEmpty()) *m_calls.last() = message;
    return true;
}
QString string(NSString *value) { return QString::fromNSString(value ?: @""); }
NSString *string(const QString &value) { return value.toNSString(); }
QDate date(NSString *iso)
{
    const QString text = string(iso);
    const QDate result = QDate::fromString(text, Qt::ISODate);
    // QDate 的宽松解析可能接受缺少补零的输入；只接受规范格式，避免日期被悄悄规范化。
    return result.isValid() && result.toString(Qt::ISODate) == text ? result : QDate();
}
NSString *date(const QDate &value) { return string(value.toString(Qt::ISODate)); }
QDateTime timestamp(NSString *iso) { return QDateTime::fromString(string(iso), Qt::ISODateWithMs); }
NSString *timestamp(const QDateTime &value) { return string(value.toString(Qt::ISODateWithMs)); }
bool integer(NSInteger value, int *result)
{
    if (value < std::numeric_limits<int>::min() || value > std::numeric_limits<int>::max()) return false;
    *result = static_cast<int>(value);
    return true;
}
bool fail(NSError **error, const QString &message)
{
    if (error) *error = [NSError errorWithDomain:@"PTCoreBridge" code:1
        userInfo:@{NSLocalizedDescriptionKey: string(message.isEmpty() ? QStringLiteral("操作失败，请重试") : message)}];
    return false;
}
}
