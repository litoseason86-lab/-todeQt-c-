#ifndef APPSETTINGS_H
#define APPSETTINGS_H

#include <QObject>
#include <QSettings>

// 用户偏好的唯一入口：QSettings 薄封装。
// 测试传入独立 ini 文件路径实现隔离；应用运行时用默认构造，读取 main.cpp 设置的组织名和应用名。
class AppSettings : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int lastMode READ lastMode WRITE setLastMode NOTIFY lastModeChanged)
    Q_PROPERTY(int workMinutes READ workMinutes WRITE setWorkMinutes NOTIFY workMinutesChanged)
    Q_PROPERTY(int breakMinutes READ breakMinutes WRITE setBreakMinutes NOTIFY breakMinutesChanged)
    Q_PROPERTY(bool soundEnabled READ soundEnabled WRITE setSoundEnabled NOTIFY soundEnabledChanged)
    Q_PROPERTY(bool reduceMotion READ reduceMotion WRITE setReduceMotion NOTIFY reduceMotionChanged)
    Q_PROPERTY(bool slimClockFont READ slimClockFont WRITE setSlimClockFont NOTIFY slimClockFontChanged)
    Q_PROPERTY(QString rolloverIgnoredDate READ rolloverIgnoredDate WRITE setRolloverIgnoredDate NOTIFY rolloverIgnoredDateChanged)
    Q_PROPERTY(QString backgroundTheme READ backgroundTheme WRITE setBackgroundTheme NOTIFY backgroundThemeChanged)
    Q_PROPERTY(int dayStartHour READ dayStartHour WRITE setDayStartHour NOTIFY dayStartHourChanged)
    Q_PROPERTY(QString nickname READ nickname WRITE setNickname NOTIFY nicknameChanged)
    // 侧栏展开态：跨启动记忆，与 macOS 应用侧边栏习惯一致。
    Q_PROPERTY(bool sidebarVisible READ sidebarVisible WRITE setSidebarVisible NOTIFY sidebarVisibleChanged)

public:
    static AppSettings* instance();
    explicit AppSettings(const QString& settingsFilePath = QString(), QObject* parent = nullptr);

    int lastMode() const;
    void setLastMode(int mode);
    int workMinutes() const;
    void setWorkMinutes(int minutes);
    int breakMinutes() const;
    void setBreakMinutes(int minutes);
    bool soundEnabled() const;
    void setSoundEnabled(bool enabled);
    bool reduceMotion() const;
    void setReduceMotion(bool enabled);
    bool slimClockFont() const;
    void setSlimClockFont(bool enabled);
    QString rolloverIgnoredDate() const;
    void setRolloverIgnoredDate(const QString& date);
    QString backgroundTheme() const;
    void setBackgroundTheme(const QString& themeId);
    int dayStartHour() const;
    void setDayStartHour(int hour);
    QString nickname() const;
    void setNickname(const QString& name);
    bool sidebarVisible() const;
    void setSidebarVisible(bool visible);

signals:
    void lastModeChanged();
    void workMinutesChanged();
    void breakMinutesChanged();
    void soundEnabledChanged();
    void reduceMotionChanged();
    void slimClockFontChanged();
    void rolloverIgnoredDateChanged();
    void backgroundThemeChanged();
    void dayStartHourChanged();
    void nicknameChanged();
    void sidebarVisibleChanged();

private:
    static int normalizeDayStartHour(int hour);

    QSettings* m_settings = nullptr;
};

#endif // APPSETTINGS_H
