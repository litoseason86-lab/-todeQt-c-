#include "IosFolderPicker.h"

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <memory>

@interface PomodoroSyncFolderPickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^completion)(NSURL* _Nullable url);
@end

@implementation PomodoroSyncFolderPickerDelegate
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls
{
    if (self.completion) {
        self.completion(urls.firstObject);
    }
    self.completion = nil;
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller
{
    if (self.completion) {
        self.completion(nil);
    }
    self.completion = nil;
}
@end

namespace {

// 选择器只弱引用它的代理对象，这里用一个静态的强引用把代理留到回调结束。
PomodoroSyncFolderPickerDelegate* g_pickerDelegate = nil;

UIViewController* topViewController()
{
    UIWindow* keyWindow = nil;
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow* window in static_cast<UIWindowScene*>(scene).windows) {
            if (window.isKeyWindow) {
                keyWindow = window;
                break;
            }
        }
        if (keyWindow != nil) {
            break;
        }
    }
    UIViewController* controller = keyWindow.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    return controller;
}

} // namespace

void presentSyncFolderPicker(std::function<void(const QByteArray& bookmark, const QString& message)> done)
{
    const auto callback = std::make_shared<std::function<void(const QByteArray&, const QString&)>>(std::move(done));
    UIViewController* presenter = topViewController();
    if (presenter == nil) {
        (*callback)(QByteArray(), QStringLiteral("找不到可以弹出文件选择器的界面"));
        return;
    }
    // 「打开」方式选文件夹：拿到的是原位置的访问权，不会把文件夹复制进应用自己的沙盒。
    UIDocumentPickerViewController* picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder]];
    g_pickerDelegate = [[PomodoroSyncFolderPickerDelegate alloc] init];
    g_pickerDelegate.completion = ^(NSURL* _Nullable url) {
        if (url == nil) {
            (*callback)(QByteArray(), QStringLiteral("已取消"));
            return;
        }
        // 先取得访问权再生成书签；之后由同步的工作线程凭书签重新取得访问权。
        const bool accessing = [url startAccessingSecurityScopedResource];
        NSError* error = nil;
        NSData* bookmark = [url bookmarkDataWithOptions:0
                         includingResourceValuesForKeys:nil
                                          relativeToURL:nil
                                                  error:&error];
        if (accessing) {
            [url stopAccessingSecurityScopedResource];
        }
        if (bookmark == nil) {
            (*callback)(QByteArray(), QStringLiteral("记不下这个文件夹的访问权：%1")
                                          .arg(QString::fromNSString(error.localizedDescription)));
            return;
        }
        (*callback)(QByteArray::fromNSData(bookmark), QString::fromNSString(url.path));
    };
    picker.delegate = g_pickerDelegate;
    [presenter presentViewController:picker animated:YES completion:nil];
}
