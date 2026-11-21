#include "IosBackgroundTask.h"

#import <UIKit/UIKit.h>

#include <memory>
#include <mutex>

std::function<void()> beginIosBackgroundTask(const QString& name)
{
    // 「结束」可能从两处来：事情做完（同步引擎调用），或者系统给的时间到了（过期回调）。
    // 过期回调可能在 beginBackgroundTaskWithName: 返回前甚至内部同步触发：
    // 用互斥锁串行保护状态位与 identifier，且绝不在持锁状态下调用 UIApplication 接口，避免锁重入死锁与赋值竞态泄漏。
    struct Task {
        std::mutex mutex;
        bool endRequested = false;
        bool ended = false;
        UIBackgroundTaskIdentifier identifier = UIBackgroundTaskInvalid;
    };
    const auto task = std::make_shared<Task>();
    const auto end = [task] {
        UIBackgroundTaskIdentifier toEnd = UIBackgroundTaskInvalid;
        {
            const std::lock_guard<std::mutex> lock(task->mutex);
            task->endRequested = true;
            if (!task->ended && task->identifier != UIBackgroundTaskInvalid) {
                task->ended = true;
                toEnd = task->identifier;
            }
        }
        if (toEnd != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:toEnd];
        }
    };
    const UIBackgroundTaskIdentifier newId =
        [UIApplication.sharedApplication beginBackgroundTaskWithName:name.toNSString()
                                                   expirationHandler:^{
                                                       end();
                                                   }];
    UIBackgroundTaskIdentifier immediateEnd = UIBackgroundTaskInvalid;
    {
        const std::lock_guard<std::mutex> lock(task->mutex);
        if (task->endRequested && !task->ended && newId != UIBackgroundTaskInvalid) {
            task->ended = true;
            immediateEnd = newId;
        } else {
            task->identifier = newId;
        }
    }
    if (immediateEnd != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:immediateEnd];
    }
    return end;
}
