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
    Q_PROPERTY(QString rolloverIgnoredDate READ rolloverIgnoredDate WRITE setRolloverIgnoredDate NOTIFY rolloverIgnoredDateChanged)
    Q_PROPERTY(QString backgroundTheme READ backgroundTheme WRITE setBackgroundTheme NOTIFY backgroundThemeChanged)

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
    QString rolloverIgnoredDate() const;
    void setRolloverIgnoredDate(const QString& date);
    QString backgroundTheme() const;
    void setBackgroundTheme(const QString& themeId);

signals:
    void lastModeChanged();
    void workMinutesChanged();
    void breakMinutesChanged();
    void soundEnabledChanged();
    void rolloverIgnoredDateChanged();
    void backgroundThemeChanged();

private:
    QSettings* m_settings = nullptr;
};

#endif // APPSETTINGS_H
