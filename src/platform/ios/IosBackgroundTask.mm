#include "IosBackgroundTask.h"

#import <UIKit/UIKit.h>

#include <atomic>
#include <memory>

std::function<void()> beginIosBackgroundTask(const QString& name)
{
    // 「结束」可能从两处来：事情做完（同步引擎在主线程调用），或者系统给的时间到了（过期回调）。
    // 两处都会调用，所以用一个原子标记保证 endBackgroundTask 只调一次。
    struct Task {
        std::atomic<bool> ended{false};
        UIBackgroundTaskIdentifier identifier = UIBackgroundTaskInvalid;
    };
    const auto task = std::make_shared<Task>();
    const auto end = [task] {
        if (task->ended.exchange(true) || task->identifier == UIBackgroundTaskInvalid) {
            return;
        }
        [UIApplication.sharedApplication endBackgroundTask:task->identifier];
    };
    task->identifier = [UIApplication.sharedApplication beginBackgroundTaskWithName:name.toNSString()
                                                                  expirationHandler:^{
                                                                      end();
                                                                  }];
    return end;
}
