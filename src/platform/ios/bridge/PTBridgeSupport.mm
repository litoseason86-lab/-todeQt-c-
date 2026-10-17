#include "PTBridgeSupport.h"
#include <QHash>
#include <QThread>
#include <limits>
#include <utility>

namespace PTBridgeSupport {
namespace {
QHash<QString, QPointer<QObject>> &registry() {
    static QHash<QString, QPointer<QObject>> objects;
    return objects;
}
}
namespace {
QList<FailureCollector::Call *> &activeCalls() {
    static QList<FailureCollector::Call *> calls;
    return calls;
}
struct FailureOutlet {
    QPointer<QObject> owner;
    UnclaimedFailureHandler handler;
};
QList<FailureOutlet> &failureOutlets() {
    static QList<FailureOutlet> outlets;
    return outlets;
}
}
void registerUnclaimedFailureHandler(QObject *owner, UnclaimedFailureHandler handler)
{
    NSCAssert(NSThread.isMainThread, @"失败出口只能在主线程登记");
    Q_ASSERT(owner && handler);
    unregisterUnclaimedFailureHandler(owner);
    failureOutlets().append({owner, std::move(handler)});
}
void unregisterUnclaimedFailureHandler(QObject *owner)
{
    NSCAssert(NSThread.isMainThread, @"失败出口只能在主线程注销");
    failureOutlets().removeIf([owner](const FailureOutlet &outlet) {
        return outlet.owner.isNull() || outlet.owner.data() == owner;
    });
}
void reportUnclaimedFailure(const QString &message, QObject *source)
{
    NSCAssert(NSThread.isMainThread, @"失败只能在主线程转发");
    auto &outlets = failureOutlets();
    while (!outlets.isEmpty() && outlets.last().owner.isNull()) outlets.removeLast();
    if (outlets.isEmpty()) return;
    // 先复制回调：Swift 收到失败后可能释放桥接，不能继续持有登记表元素的引用。
    const FailureOutlet outlet = outlets.last();
    if (source && source != outlet.owner.data()) return;
    outlet.handler(message);
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
FailureCollector::Call::Call(FailureCollector &collector)
{
    Q_UNUSED(collector);
    NSCAssert(NSThread.isMainThread, @"桥接调用只能在主线程收集失败");
    activeCalls().append(this);
}
FailureCollector::Call::~Call()
{
    NSCAssert(NSThread.isMainThread, @"桥接调用只能在主线程结束");
    Q_ASSERT(!activeCalls().isEmpty() && activeCalls().last() == this);
    activeCalls().removeLast();
    // 先弹栈，再交给外壳；未认领的内层失败不应被重新记到外层，也不能静默丢失。
    if (!m_claimed && !m_error.isEmpty()) reportUnclaimedFailure(m_error);
}
QString FailureCollector::Call::error() const
{
    NSCAssert(NSThread.isMainThread, @"桥接失败只能在主线程认领");
    m_claimed = true;
    return m_error;
}
bool FailureCollector::collect(const QString &message)
{
    NSCAssert(NSThread.isMainThread, @"桥接失败只能在主线程收集");
    if (activeCalls().isEmpty()) return false;
    Call *call = activeCalls().last();
    if (call->m_error.isEmpty()) call->m_error = message;
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
