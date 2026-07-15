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
    // 关闭毛玻璃、改用不透明面板（省电/更清晰，呼应 macOS “减少透明度”）。
    Q_PROPERTY(bool reduceTransparency READ reduceTransparency WRITE setReduceTransparency NOTIFY reduceTransparencyChanged)
    // 阶段结束时把窗口带到最前；关掉后仅靠提示音提醒，不打断当前操作。
    Q_PROPERTY(bool raiseOnPhaseComplete READ raiseOnPhaseComplete WRITE setRaiseOnPhaseComplete NOTIFY raiseOnPhaseCompleteChanged)
    // 番茄自动衔接：专注结束自动进入休息、休息结束自动开始下一个番茄（默认关，避免打断）。
    Q_PROPERTY(bool autoStartBreak READ autoStartBreak WRITE setAutoStartBreak NOTIFY autoStartBreakChanged)
    Q_PROPERTY(bool autoStartNextPomodoro READ autoStartNextPomodoro WRITE setAutoStartNextPomodoro NOTIFY autoStartNextPomodoroChanged)
    // 长休息：每完成 N 个番茄后休息更久。
    Q_PROPERTY(bool longBreakEnabled READ longBreakEnabled WRITE setLongBreakEnabled NOTIFY longBreakEnabledChanged)
    Q_PROPERTY(int longBreakMinutes READ longBreakMinutes WRITE setLongBreakMinutes NOTIFY longBreakMinutesChanged)
    Q_PROPERTY(int longBreakInterval READ longBreakInterval WRITE setLongBreakInterval NOTIFY longBreakIntervalChanged)

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
    bool reduceTransparency() const;
    void setReduceTransparency(bool enabled);
    bool raiseOnPhaseComplete() const;
    void setRaiseOnPhaseComplete(bool enabled);
    bool autoStartBreak() const;
    void setAutoStartBreak(bool enabled);
    bool autoStartNextPomodoro() const;
    void setAutoStartNextPomodoro(bool enabled);
    bool longBreakEnabled() const;
    void setLongBreakEnabled(bool enabled);
    int longBreakMinutes() const;
    void setLongBreakMinutes(int minutes);
    int longBreakInterval() const;
    void setLongBreakInterval(int count);
    Q_INVOKABLE int dailyFocusGoalMinutesForDate(const QString& isoDate) const;
    Q_INVOKABLE bool setDailyFocusGoal(const QString& isoDate, int minutes);

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
    void reduceTransparencyChanged();
    void raiseOnPhaseCompleteChanged();
    void autoStartBreakChanged();
    void autoStartNextPomodoroChanged();
    void longBreakEnabledChanged();
    void longBreakMinutesChanged();
    void longBreakIntervalChanged();
    void dailyFocusGoalChanged();
    void settingsWriteSucceeded(const QString& key);
    void settingsWriteFailed(const QString& key, const QString& message);

private:
    static int normalizeWorkMinutes(int minutes);
    static int normalizeBreakMinutes(int minutes);
    static int normalizeDayStartHour(int hour);
    static int normalizeLongBreakMinutes(int minutes);
    static int normalizeLongBreakInterval(int count);
    void recreateSettingsBackend();
    bool writeValue(const QString& key, const QVariant& value);
    QString m_settingsFilePath;
    QSettings* m_settings = nullptr;
};

#endif // APPSETTINGS_H
