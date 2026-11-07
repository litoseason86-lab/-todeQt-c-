#include "AppleSyncHttpClient.h"

#import <Foundation/Foundation.h>

#include <dispatch/dispatch.h>

#include <cstdint>
#include <mutex>

// 任务表与取消代次由同一把锁保护。cancelAll() 取消调用发生时已经登记的请求；
// send() 在登记前捕获代次，若期间发生过取消则连任务都不启动，避免“刚发出就漏取消”。
@interface AppleSyncHttpTaskRegistry : NSObject {
@public
    std::mutex mutex;
    NSMutableSet<NSURLSessionDataTask*>* tasks;
    std::uint64_t cancellationEpoch;
}
@end

@implementation AppleSyncHttpTaskRegistry
- (instancetype)init
{
    self = [super init];
    if (self) {
        tasks = [NSMutableSet set];
        cancellationEpoch = 0;
    }
    return self;
}
@end

// 回调在 NSURLSession 自己的队列上写，send() 在同步线程读；二者只在完成信号
// 之后交接，因此不需要复制整份响应。
@interface AppleSyncHttpResult : NSObject {
@public
    NSData* body;
    NSURLResponse* response;
    NSError* error;
}
@end

@implementation AppleSyncHttpResult
@end

// 350 一类重定向必须交回调用方，防止鉴权头被带到另一台主机。
@interface AppleSyncHttpSessionDelegate
    : NSObject <NSURLSessionTaskDelegate>
@end

@implementation AppleSyncHttpSessionDelegate
- (void)URLSession:(NSURLSession*)session
                          task:(NSURLSessionTask*)task
    willPerformHTTPRedirection:(NSHTTPURLResponse*)response
                    newRequest:(NSURLRequest*)request
             completionHandler:(void (^)(NSURLRequest*))completionHandler
{
    (void)session;
    (void)task;
    (void)response;
    (void)request;
    completionHandler(nil);
}
@end

struct AppleSyncHttpClient::State {
    __strong AppleSyncHttpTaskRegistry* registry = nil;
    __strong NSURLSession* session = nil;
    __strong AppleSyncHttpSessionDelegate* delegate = nil;
};

namespace {

SyncHttpClient::Response failureResponse(SyncHttpClient::Failure failure,
                                         const QString& message)
{
    SyncHttpClient::Response response;
    response.failure = failure;
    response.message = message;
    return response;
}

SyncHttpClient::Response responseFromError(NSError* error)
{
    if (![error.domain isEqualToString:NSURLErrorDomain]) {
        return failureResponse(
            SyncHttpClient::Failure::Network,
            error ? QString::fromNSString(error.localizedDescription)
                  : QStringLiteral("网络请求失败"));
    }
    switch (error.code) {
    case NSURLErrorCancelled:
        return failureResponse(SyncHttpClient::Failure::Cancelled,
                               QStringLiteral("同步已取消"));
    case NSURLErrorTimedOut:
        return failureResponse(SyncHttpClient::Failure::Timeout,
                               QStringLiteral("同步服务器响应超时"));
    default:
        return failureResponse(
            SyncHttpClient::Failure::Network,
            QString::fromNSString(error.localizedDescription));
    }
}

} // namespace

AppleSyncHttpClient::AppleSyncHttpClient() : d(std::make_unique<State>())
{
    @autoreleasepool {
        NSURLSessionConfiguration* configuration
            = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.URLCache = nil;
        configuration.HTTPCookieStorage = nil;
        configuration.HTTPShouldSetCookies = NO;
        configuration.requestCachePolicy
            = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.waitsForConnectivity = NO;
        d->registry = [AppleSyncHttpTaskRegistry new];
        d->delegate = [AppleSyncHttpSessionDelegate new];
        d->session = [NSURLSession sessionWithConfiguration:configuration
                                                   delegate:d->delegate
                                              delegateQueue:nil];
    }
}

AppleSyncHttpClient::~AppleSyncHttpClient()
{
    @autoreleasepool {
        [d->session invalidateAndCancel];
        d->session = nil;
        d->delegate = nil;
        d->registry = nil;
    }
}

SyncHttpClient::Response AppleSyncHttpClient::send(const Request& request)
{
    @autoreleasepool {
        if (request.method.isEmpty() || !request.url.isValid()) {
            return failureResponse(Failure::Network,
                                   QStringLiteral("同步请求地址或方法不合法"));
        }
        const QString urlText = QString::fromUtf8(
            request.url.toEncoded(QUrl::FullyEncoded));
        NSURL* url = [NSURL URLWithString:urlText.toNSString()];
        if (url == nil) {
            return failureResponse(Failure::Network,
                                   QStringLiteral("同步请求地址不合法"));
        }

        NSMutableURLRequest* nativeRequest
            = [NSMutableURLRequest requestWithURL:url];
        nativeRequest.HTTPMethod
            = QString::fromLatin1(request.method).toNSString();
        const int timeoutMs = qMax(1, request.timeoutMs);
        nativeRequest.timeoutInterval = timeoutMs / 1000.0;
        nativeRequest.cachePolicy
            = NSURLRequestReloadIgnoringLocalCacheData;
        for (const auto& header : request.headers) {
            const QString name = QString::fromLatin1(header.first);
            const QString value = QString::fromUtf8(header.second);
            [nativeRequest setValue:value.toNSString()
                 forHTTPHeaderField:name.toNSString()];
        }
        const bool hasBodyMethod = request.method == "POST"
            || request.method == "PUT";
        if (hasBodyMethod || !request.body.isEmpty()) {
            const char* bytes = request.body.isEmpty()
                ? ""
                : request.body.constData();
            nativeRequest.HTTPBody = [NSData dataWithBytes:bytes
                                                    length:request.body.size()];
        }

        AppleSyncHttpTaskRegistry* registry = d->registry;
        std::uint64_t epoch = 0;
        {
            const std::lock_guard<std::mutex> lock(registry->mutex);
            epoch = registry->cancellationEpoch;
        }

        dispatch_semaphore_t completed = dispatch_semaphore_create(0);
        AppleSyncHttpResult* result = [AppleSyncHttpResult new];
        // 不能用强引用的 __block：data task 保留 completion block，block 再强留
        // task 会形成环。任务在回调执行期间由 NSURLSession 持有，弱指针足够用来注销。
        __block __unsafe_unretained NSURLSessionDataTask* task = nil;
        task = [d->session
            dataTaskWithRequest:nativeRequest
              completionHandler:^(NSData* body, NSURLResponse* response,
                                  NSError* error) {
            result->body = body;
            result->response = response;
            result->error = error;
            if (task != nil) {
                const std::lock_guard<std::mutex> lock(registry->mutex);
                [registry->tasks removeObject:task];
            }
            dispatch_semaphore_signal(completed);
        }];
        if (task == nil) {
            return failureResponse(Failure::Network,
                                   QStringLiteral("无法创建同步请求"));
        }

        bool cancelledBeforeStart = false;
        {
            const std::lock_guard<std::mutex> lock(registry->mutex);
            if (registry->cancellationEpoch != epoch) {
                cancelledBeforeStart = true;
            } else {
                [registry->tasks addObject:task];
                [task resume];
            }
        }
        if (cancelledBeforeStart) {
            [task cancel];
            return failureResponse(Failure::Cancelled,
                                   QStringLiteral("同步已取消"));
        }

        // 系统 timeout 可能略晚触发；多等两秒后由客户端兜底取消，防止工作线程永久挂住。
        const int waitMs = timeoutMs + 2000;
        const dispatch_time_t deadline = dispatch_time(
            DISPATCH_TIME_NOW, static_cast<int64_t>(waitMs) * NSEC_PER_MSEC);
        if (dispatch_semaphore_wait(completed, deadline) != 0) {
            [task cancel];
            return failureResponse(Failure::Timeout,
                                   QStringLiteral("同步服务器响应超时"));
        }

        if (result->error != nil) {
            return responseFromError(result->error);
        }
        if (![result->response isKindOfClass:[NSHTTPURLResponse class]]) {
            return failureResponse(Failure::Network,
                                   QStringLiteral("同步服务器响应不是 HTTP"));
        }
        Response response;
        response.status = static_cast<int>(
            static_cast<NSHTTPURLResponse*>(result->response).statusCode);
        response.body = QByteArray::fromNSData(result->body ?: [NSData data]);
        return response;
    }
}

void AppleSyncHttpClient::cancelAll()
{
    @autoreleasepool {
        NSArray<NSURLSessionDataTask*>* snapshot = nil;
        {
            const std::lock_guard<std::mutex> lock(d->registry->mutex);
            ++d->registry->cancellationEpoch;
            snapshot = d->registry->tasks.allObjects;
        }
        for (NSURLSessionDataTask* task in snapshot) {
            [task cancel];
        }
    }
}
