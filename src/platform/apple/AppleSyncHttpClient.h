#ifndef APPLESYNCHTTPCLIENT_H
#define APPLESYNCHTTPCLIENT_H

#include "../../services/SyncHttpClient.h"

#include <memory>

// NSURLSession 实现的同步 HTTP。每次 send() 阻塞等工作线程上的 data task，
// cancelAll() 可以从任意线程取消当时仍在登记表中的任务。
class AppleSyncHttpClient final : public SyncHttpClient
{
public:
    AppleSyncHttpClient();
    ~AppleSyncHttpClient() override;

    Response send(const Request& request) override;
    void cancelAll() override;

private:
    struct State;
    std::unique_ptr<State> d;
};

#endif // APPLESYNCHTTPCLIENT_H
