#include "AppleUbiquitousItem.h"

#import <Foundation/Foundation.h>

namespace AppleUbiquitousItem {

QString uploadProblem(const QString& absolutePath)
{
    @autoreleasepool {
        // 每次新建 URL：NSURL 会缓存查过的资源值，复用同一个对象就一直看到第一次查的结果。
        NSURL* url = [NSURL fileURLWithPath:absolutePath.toNSString()];
        NSError* uploadError = nil;
        NSError* queryError = nil;
        if (![url getResourceValue:&uploadError forKey:NSURLUbiquitousItemUploadingErrorKey error:&queryError]
            || uploadError == nil) {
            return {};
        }
        return QString::fromNSString(uploadError.localizedDescription);
    }
}

} // namespace AppleUbiquitousItem
