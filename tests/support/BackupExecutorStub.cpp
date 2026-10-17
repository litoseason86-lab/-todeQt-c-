#include <QFile>

#include <cstdio>
#include <unistd.h>

int main()
{
    // 替身先读完请求再标记就绪，测试不能仅凭“已创建 PID”猜测它已经进入等待。
    for (int next = std::getc(stdin); next != '\n'; next = std::getc(stdin)) {
        if (next == EOF) return 2;
    }
    const auto mode = qgetenv("POMODORO_BACKUP_STUB_MODE");
    const auto diagnostic = qgetenv("POMODORO_BACKUP_STUB_STDERR");
    if (!diagnostic.isEmpty()) {
        std::fwrite(diagnostic.constData(), 1, static_cast<size_t>(diagnostic.size()), stderr);
        std::fflush(stderr);
    }
    const auto readyPath = qEnvironmentVariable("POMODORO_BACKUP_STUB_READY");
    if (!readyPath.isEmpty()) {
        QFile ready(readyPath);
        if (!ready.open(QIODevice::WriteOnly)) return 3;
        ready.write(QByteArray::number(::getpid()));
    }
    if (mode == "empty") return 0;
    if (mode == "malformed") {
        std::puts("not-json");
        return 0;
    }
    if (mode == "partial") {
        std::fputs("{\"success\":true,\"error\":\"\",\"committed\":true}", stdout);
        return 0;
    }
    if (mode == "abnormal") {
        std::puts("{\"success\":true,\"error\":\"\",\"committed\":true}");
        return 7;
    }
    if (mode == "no-info") {
        std::puts("{\"success\":true,\"error\":\"\",\"committed\":false}");
        return 0;
    }
    if (mode == "committed-hang") {
        std::puts("{\"success\":true,\"error\":\"\",\"committed\":true}");
        std::fflush(stdout);
    }
    // 故意不读停止行，也不因 stdin EOF 返回，用于验证产品后端会按期限结束子进程。
    for (;;) ::pause();
}
