#ifndef QMLFACADE_H
#define QMLFACADE_H

#include <QStringList>

class QGuiApplication;
class QQmlApplicationEngine;
class QObject;
class AppServices;

// PTQml 层的 QML 装配门面。
// 负责控件风格设定、打包字体注册、启动失败窗口及上下文属性装配，不包含平台分支宏。
class QmlFacade
{
public:
    // 平台特有的上下文属性补充对象。
    struct Extras
    {
        Extras()
            : mcpAccessController(nullptr)
            , ipadUiPreferences(nullptr)
            , phaseAlarmCoordinator(nullptr)
        {
        }

        QObject* mcpAccessController;
        QObject* ipadUiPreferences;
        QObject* phaseAlarmCoordinator;
    };

    // 设置基础控件风格（QQuickStyle Basic）。必须在创建 QGuiApplication 之前调用。
    static void setupQuickStyle();

    // 注册打包的 Space Grotesk 与 Bricolage 数字字体。
    static void registerBundledFonts();

    // 数据库打开失败时展示的独立错误窗口。返回启动退出代码（通常为 -1）。
    static int showStartupErrorWindow(QGuiApplication& app, const QString& defaultDbPath);

    // 将平台无关及平台附加的上下文属性安装到 QML 引擎根上下文。
    // 返回成功安装的属性名称清单，供测试与诊断核对。
    static QStringList install(QQmlApplicationEngine& engine,
                               const AppServices& services);
    static QStringList install(QQmlApplicationEngine& engine,
                               const AppServices& services,
                               const Extras& extras);
};

#endif // QMLFACADE_H
