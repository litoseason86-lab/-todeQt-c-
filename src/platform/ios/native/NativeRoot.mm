#include "NativeRoot.h"
#include "IPadUiPreferences.h"
#import "../bridge/PTLifecycleBridge.h"
#import <UIKit/UIKit.h>
#include <QCoreApplication>
#include <QSettings>

// Swift 用 C 入口返回 +1 引用计数的控制器，由本文件接管所有权。
extern "C" void *PTMakeNativeRootViewController(void);
namespace {
UIWindow *nativeWindow = nil;
id<NSObject> sceneObserver = nil;

void mount(UIWindowScene *scene)
{
    NSCAssert(NSThread.isMainThread, @"根视图只能在主线程挂载");
    if (nativeWindow) return;
    UIViewController *controller = (__bridge_transfer UIViewController *)PTMakeNativeRootViewController();
    nativeWindow = [[UIWindow alloc] initWithWindowScene:scene];
    nativeWindow.rootViewController = controller;
    [nativeWindow makeKeyAndVisible];
}
}

bool isIPadDevice() { return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad; }


void installNativeRoot()
{
    NSCAssert(NSThread.isMainThread, @"根视图只能在主线程安装");
    if (nativeWindow || sceneObserver) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            mount(static_cast<UIWindowScene *>(scene));
            return;
        }
    }
    // Qt 6.10.3 实测：main 在完成启动通知里执行，窗口场景尚未连接；不加载 QML 时 QUIWindow 保持隐藏。
    // 只登记一次场景通知，下一轮主队列在同一场景新建原生主窗口，不接管 Qt 的私有控制器。
    sceneObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:UISceneWillConnectNotification object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *notification) {
            if (![notification.object isKindOfClass:UIWindowScene.class]) return;
            [NSNotificationCenter.defaultCenter removeObserver:sceneObserver];
            sceneObserver = nil;
            UIWindowScene *scene = static_cast<UIWindowScene *>(notification.object);
            dispatch_async(dispatch_get_main_queue(), ^{ mount(scene); });
        }];
}

void flushNativeEdits() { [PTLifecycleBridge flush]; }
