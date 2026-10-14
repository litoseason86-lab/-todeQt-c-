#ifndef UIROUTER_H
#define UIROUTER_H

#include <QByteArray>
#include <QStringList>

// iOS / iPadOS 界面路由决策枚举。
enum class UiRoute
{
    Native,        // iPad 原生（SwiftUI）界面
    QmlFull,       // QML 完整平板界面
    QmlCompanion   // QML 随身伴侣页界面（iPhone 或强制伴侣页）
};

// iOS 启动界面分发路由纯函数。
// 不进行 I/O，不直接读写 QSettings 或 QScreen，由入口将环境参数读出后传入。
class UiRouter
{
public:
    static UiRoute route(bool isIPad,
                         int availableShortSide,
                         const QStringList& arguments,
                         const QByteArray& nativeUiEnv,
                         const QByteArray& layoutEnv,
                         bool nativeUiPreference = true);
};

#endif // UIROUTER_H
