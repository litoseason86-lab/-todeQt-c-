#pragma once
#include <QDate>
#include <QDateTime>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QList>

// 非单例只登记弱引用；服务销毁后读取为空，避免 Swift 持有已经释放的 C++ 对象。
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

namespace PTBridgeSupport {
void registerService(const QString &name, QObject *service);
QObject *registeredService(const QString &name);
template<class T> T *service(const QString &name) {
    return qobject_cast<T *>(registeredService(name));
}

// 调用期同步失败归入当前作用域，背景失败由调用方转发；嵌套调用各自收集，不吞外层错误。
class FailureCollector {
public:
    class Call {
    public:
        explicit Call(FailureCollector &collector);
        ~Call();
        Call(const Call &) = delete;
        Call &operator=(const Call &) = delete;
        QString error() const { return m_error; }
    private:
        FailureCollector &m_collector;
        QString m_error;
    };
    bool collect(const QString &message);
private:
    QList<QString *> m_calls;
};
#ifdef __OBJC__
QString string(NSString *value);
NSString *string(const QString &value);
QDate date(NSString *iso);
NSString *date(const QDate &value);
// 全桥时刻统一为 ISO 8601 字符串，带毫秒与时区偏移；不转成整秒，保留记录的原始精度。
QDateTime timestamp(NSString *iso);
NSString *timestamp(const QDateTime &value);
bool integer(NSInteger value, int *result);
bool fail(NSError **error, const QString &message);
#endif
}
