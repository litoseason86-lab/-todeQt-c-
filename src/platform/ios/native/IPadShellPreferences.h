#ifndef IPADSHELLPREFERENCES_H
#define IPADSHELLPREFERENCES_H

#include <QString>

// iPad 外壳只属于本机的偏好；存储与兼容旧键由 C++ 处理，桥接只转换值和转发通知。
class IPadShellPreferences final
{
public:
    struct Snapshot {
        bool useWallpaper = false;
        QString appearance = QStringLiteral("system");
        QString selectedPage = QStringLiteral("dashboard");
    };

    static Snapshot readSnapshot();
    static bool setUseWallpaper(bool value, QString* error = nullptr);
    static bool setAppearance(const QString& mode, QString* error = nullptr);
    // 主题服务仍在主线程使用；needsRefresh 表示成功后服务没有发主题变化信号，外壳要补一次刷新。
    static bool selectTheme(const QString& theme, QString* error = nullptr, bool* needsRefresh = nullptr);
    static bool setSelectedPage(const QString& page, QString* error = nullptr);
};

#endif // IPADSHELLPREFERENCES_H
