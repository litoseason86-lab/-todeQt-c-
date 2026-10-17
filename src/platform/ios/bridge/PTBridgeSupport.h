#pragma once
#include <QDate>
#include <QDateTime>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QList>
#include <functional>

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

// 所有桥接共享主线程调用栈：同步失败只进入最内层调用，error() 表示调用方已认领。
// 调用结束仍未认领的失败交给外壳兜底，嵌套调用互不覆盖；不要跨线程或跨异步阶段持有 Call。
class FailureCollector {
public:
    class Call {
    public:
        explicit Call(FailureCollector &collector);
        ~Call();
        Call(const Call &) = delete;
        Call &operator=(const Call &) = delete;
        QString error() const;
    private:
        friend class FailureCollector;
        QString m_error;
        mutable bool m_claimed = false;
    };
    bool collect(const QString &message);
};

// 出口按外壳接收上下文登记；只向最近登记且存活的出口送达，析构时撤销自己的登记。
// source 非空表示某个外壳的服务订阅，只允许当前出口转发，避免多实例重复接收同一后台信号。
using UnclaimedFailureHandler = std::function<void(const QString &)>;
void registerUnclaimedFailureHandler(QObject *owner, UnclaimedFailureHandler handler);
void unregisterUnclaimedFailureHandler(QObject *owner);
void reportUnclaimedFailure(const QString &message, QObject *source = nullptr);
#ifdef __OBJC__
QString string(NSString *value);
NSString *string(const QString &value);
QDate date(NSString *iso);
NSString *date(const QDate &value);
// 专注/休息记录两侧使用不带时区的本地墙钟串 yyyy-MM-ddTHH:mm:ss.zzz（毫秒可无）。
// 与 FocusTimer 落库一致，保留精度；解析仍兼容带偏移或 Z 的串，写入由服务统一本地化。
QDateTime timestamp(NSString *iso);
NSString *timestamp(const QDateTime &value);
bool integer(NSInteger value, int *result);
bool fail(NSError **error, const QString &message);
#endif
}
