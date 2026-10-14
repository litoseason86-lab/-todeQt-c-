#include <QTest>
#include "entry/ios/UiRouter.h"

class UiRouterTests : public QObject
{
    Q_OBJECT

private slots:
    void defaultIpadUsesNative();
    void ipadQmlUiArgOverridesNativeArg();
    void ipadNativeUiArgOverridesEnv();
    void ipadEnvOverridesPreference();
    void ipadPreferenceFalseUsesQmlFull();
    void iphoneNeverUsesNative();
    void layoutEnvOverridesScreenSize();
    void screenShortSideBoundary();
    void invalidScreenUsesQmlFull();
    void truthTableCombinations();
};

void UiRouterTests::defaultIpadUsesNative()
{
    // 保证在没有额外开关和参数时，iPad 默认采用原生 SwiftUI 界面。
    const UiRoute route = UiRouter::route(
        /*isIPad=*/true,
        /*availableShortSide=*/800,
        /*arguments=*/{},
        /*nativeUiEnv=*/{},
        /*layoutEnv=*/{},
        /*nativeUiPreference=*/true);
    QCOMPARE(route, UiRoute::Native);
}

void UiRouterTests::ipadQmlUiArgOverridesNativeArg()
{
    // 保证 --ipad-qml-ui 优先级高于 --ipad-native-ui，iPad 强制回退到 QML 界面。
    const QStringList args = {QStringLiteral("--ipad-qml-ui"), QStringLiteral("--ipad-native-ui")};
    const UiRoute route = UiRouter::route(
        /*isIPad=*/true,
        /*availableShortSide=*/800,
        args,
        /*nativeUiEnv=*/"1",
        /*layoutEnv=*/{},
        /*nativeUiPreference=*/true);
    QCOMPARE(route, UiRoute::QmlFull);
}

void UiRouterTests::ipadNativeUiArgOverridesEnv()
{
    // 保证命令行启动参数 --ipad-native-ui 优先于环境变量 POMODORO_TODO_NATIVE_UI=0。
    const QStringList args = {QStringLiteral("--ipad-native-ui")};
    const UiRoute route = UiRouter::route(
        /*isIPad=*/true,
        /*availableShortSide=*/800,
        args,
        /*nativeUiEnv=*/"0",
        /*layoutEnv=*/{},
        /*nativeUiPreference=*/false);
    QCOMPARE(route, UiRoute::Native);
}

void UiRouterTests::ipadEnvOverridesPreference()
{
    // 保证环境变量 POMODORO_TODO_NATIVE_UI 优先于本机持久化偏好设置。
    // 环境变量为 1 时强制原生，即使偏好为 false
    const UiRoute routeForced1 = UiRouter::route(
        /*isIPad=*/true,
        /*availableShortSide=*/800,
        /*arguments=*/{},
        /*nativeUiEnv=*/"1",
        /*layoutEnv=*/{},
        /*nativeUiPreference=*/false);
    QCOMPARE(routeForced1, UiRoute::Native);

    // 环境变量为 0 时强制 QML，即使偏好为 true
    const UiRoute routeForced0 = UiRouter::route(
        /*isIPad=*/true,
        /*availableShortSide=*/800,
        /*arguments=*/{},
        /*nativeUiEnv=*/"0",
        /*layoutEnv=*/{},
        /*nativeUiPreference=*/true);
    QCOMPARE(routeForced0, UiRoute::QmlFull);
}

void UiRouterTests::ipadPreferenceFalseUsesQmlFull()
{
    // 保证偏好设置为 false 时 iPad 关闭原生界面并进入 QML 完整界面。
    const UiRoute route = UiRouter::route(
        /*isIPad=*/true,
        /*availableShortSide=*/800,
        /*arguments=*/{},
        /*nativeUiEnv=*/{},
        /*layoutEnv=*/{},
        /*nativeUiPreference=*/false);
    QCOMPARE(route, UiRoute::QmlFull);
}

void UiRouterTests::iphoneNeverUsesNative()
{
    // 保证 iPhone 设备绝不进入原生界面，即使传入了强制原生参数或环境变量。
    const QStringList args = {QStringLiteral("--ipad-native-ui")};
    const UiRoute route = UiRouter::route(
        /*isIPad=*/false,
        /*availableShortSide=*/390,
        args,
        /*nativeUiEnv=*/"1",
        /*layoutEnv=*/{},
        /*nativeUiPreference=*/true);
    QCOMPARE(route, UiRoute::QmlCompanion);
}

void UiRouterTests::layoutEnvOverridesScreenSize()
{
    // 保证 POMODORO_TODO_LAYOUT 环境变量可以强制指定 companion 或 full 界面并覆盖屏幕尺寸推断。
    const UiRoute routeCompanion = UiRouter::route(
        /*isIPad=*/false,
        /*availableShortSide=*/800,
        /*arguments=*/{},
        /*nativeUiEnv=*/{},
        /*layoutEnv=*/"companion",
        /*nativeUiPreference=*/true);
    QCOMPARE(routeCompanion, UiRoute::QmlCompanion);

    const UiRoute routeFull = UiRouter::route(
        /*isIPad=*/false,
        /*availableShortSide=*/390,
        /*arguments=*/{},
        /*nativeUiEnv=*/{},
        /*layoutEnv=*/"full",
        /*nativeUiPreference=*/true);
    QCOMPARE(routeFull, UiRoute::QmlFull);
}

void UiRouterTests::screenShortSideBoundary()
{
    // 保证屏幕可用短边在 600pt 阈值边界（599 与 600）做出精准分发。
    const UiRoute route599 = UiRouter::route(
        /*isIPad=*/false,
        /*availableShortSide=*/599,
        /*arguments=*/{},
        /*nativeUiEnv=*/{},
        /*layoutEnv=*/{},
        /*nativeUiPreference=*/true);
    QCOMPARE(route599, UiRoute::QmlCompanion);

    const UiRoute route600 = UiRouter::route(
        /*isIPad=*/false,
        /*availableShortSide=*/600,
        /*arguments=*/{},
        /*nativeUiEnv=*/{},
        /*layoutEnv=*/{},
        /*nativeUiPreference=*/true);
    QCOMPARE(route600, UiRoute::QmlFull);
}

void UiRouterTests::invalidScreenUsesQmlFull()
{
    // 保证无法获取有效屏幕尺寸（短边 <= 0）时回退到 QML 完整界面而非伴侣页。
    const UiRoute routeNegative = UiRouter::route(
        /*isIPad=*/false,
        /*availableShortSide=*/-1,
        /*arguments=*/{},
        /*nativeUiEnv=*/{},
        /*layoutEnv=*/{},
        /*nativeUiPreference=*/true);
    QCOMPARE(routeNegative, UiRoute::QmlFull);

    const UiRoute routeZero = UiRouter::route(
        /*isIPad=*/false,
        /*availableShortSide=*/0,
        /*arguments=*/{},
        /*nativeUiEnv=*/{},
        /*layoutEnv=*/{},
        /*nativeUiPreference=*/true);
    QCOMPARE(routeZero, UiRoute::QmlFull);
}

void UiRouterTests::truthTableCombinations()
{
    // 保证计划真值表所列的多开关并发组合行为严格一致。
    // 1. iPad 同时带 --ipad-qml-ui 和 --ipad-native-ui -> QML 完整界面（--ipad-qml-ui 最先判断）
    {
        const QStringList args = {QStringLiteral("--ipad-qml-ui"), QStringLiteral("--ipad-native-ui")};
        const UiRoute r = UiRouter::route(true, 800, args, {}, {}, true);
        QCOMPARE(r, UiRoute::QmlFull);
    }

    // 2. iPad 强制原生（参数或环境变量为 1），同时 POMODORO_TODO_LAYOUT=companion -> 原生（布局开关只在不走原生时生效）
    {
        const QStringList args = {QStringLiteral("--ipad-native-ui")};
        const UiRoute r1 = UiRouter::route(true, 800, args, {}, "companion", true);
        QCOMPARE(r1, UiRoute::Native);

        const UiRoute r2 = UiRouter::route(true, 800, {}, "1", "companion", true);
        QCOMPARE(r2, UiRoute::Native);
    }

    // 3. iPad 强制 QML（--ipad-qml-ui），同时 POMODORO_TODO_LAYOUT=companion -> QML 伴侣页
    {
        const QStringList args = {QStringLiteral("--ipad-qml-ui")};
        const UiRoute r = UiRouter::route(true, 800, args, {}, "companion", true);
        QCOMPARE(r, UiRoute::QmlCompanion);
    }

    // 4. iPhone 带 --ipad-native-ui 或环境变量为 1 -> QML 伴侣页（不是 iPad 就不走原生）
    {
        const QStringList args = {QStringLiteral("--ipad-native-ui")};
        const UiRoute r1 = UiRouter::route(false, 390, args, {}, {}, true);
        QCOMPARE(r1, UiRoute::QmlCompanion);

        const UiRoute r2 = UiRouter::route(false, 390, {}, "1", {}, true);
        QCOMPARE(r2, UiRoute::QmlCompanion);
    }

    // 5. iPad 本机偏好为 false，环境变量为 1 -> 原生（环境变量先于偏好）
    {
        const UiRoute r = UiRouter::route(true, 800, {}, "1", {}, false);
        QCOMPARE(r, UiRoute::Native);
    }

    // 6. iPad 带 --ipad-native-ui，环境变量为 0 -> 原生（参数先于环境变量）
    {
        const QStringList args = {QStringLiteral("--ipad-native-ui")};
        const UiRoute r = UiRouter::route(true, 800, args, "0", {}, true);
        QCOMPARE(r, UiRoute::Native);
    }
}

QTEST_MAIN(UiRouterTests)
#include "UiRouterTests.moc"
