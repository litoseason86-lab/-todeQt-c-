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
    // 自由计时超过该小时数后，结束时必须确认记录或丢弃；默认 8 小时。
    Q_PROPERTY(int freeTimerWarningHours READ freeTimerWarningHours WRITE setFreeTimerWarningHours NOTIFY freeTimerWarningHoursChanged)
    Q_PROPERTY(bool soundEnabled READ soundEnabled WRITE setSoundEnabled NOTIFY soundEnabledChanged)
    Q_PROPERTY(bool reduceMotion READ reduceMotion WRITE setReduceMotion NOTIFY reduceMotionChanged)
    Q_PROPERTY(bool slimClockFont READ slimClockFont WRITE setSlimClockFont NOTIFY slimClockFontChanged)
    Q_PROPERTY(QString rolloverIgnoredDate READ rolloverIgnoredDate WRITE setRolloverIgnoredDate NOTIFY rolloverIgnoredDateChanged)
    Q_PROPERTY(QString backgroundTheme READ backgroundTheme WRITE setBackgroundTheme NOTIFY backgroundThemeChanged)
    Q_PROPERTY(int dayStartHour READ dayStartHour WRITE setDayStartHour NOTIFY dayStartHourChanged)
    Q_PROPERTY(QString nickname READ nickname WRITE setNickname NOTIFY nicknameChanged)
    // 侧栏展开态：跨启动记忆，与 macOS 应用侧边栏习惯一致。
    Q_PROPERTY(bool sidebarVisible READ sidebarVisible WRITE setSidebarVisible NOTIFY sidebarVisibleChanged)
    // 仪表盘右侧专注计时面板的展开态：跨启动记忆，与侧栏同一套收起习惯。
    Q_PROPERTY(bool dashboardTimerVisible READ dashboardTimerVisible WRITE setDashboardTimerVisible NOTIFY dashboardTimerVisibleChanged)
    // 长期目标页的列表/网格偏好；非法值统一回退到列表。
    Q_PROPERTY(QString goalViewMode READ goalViewMode WRITE setGoalViewMode NOTIFY goalViewModeChanged)
    // 关闭毛玻璃、改用不透明面板（省电/更清晰，呼应 macOS “减少透明度”）。
    Q_PROPERTY(bool reduceTransparency READ reduceTransparency WRITE setReduceTransparency NOTIFY reduceTransparencyChanged)
    // 阶段结束时把窗口带到最前；关掉后仅靠提示音提醒，不打断当前操作。
    Q_PROPERTY(bool raiseOnPhaseComplete READ raiseOnPhaseComplete WRITE setRaiseOnPhaseComplete NOTIFY raiseOnPhaseCompleteChanged)
    // 关闭主窗口时隐藏到菜单栏而非退出；默认关闭，避免标准关闭操作留下不可见进程。
    Q_PROPERTY(bool closeToTray READ closeToTray WRITE setCloseToTray NOTIFY closeToTrayChanged)
    // 是否已展示过“关闭即隐藏到菜单栏”的首次提示；只提示一次，避免每次关闭都打扰。
    Q_PROPERTY(bool closeToTrayHintShown READ closeToTrayHintShown WRITE setCloseToTrayHintShown NOTIFY closeToTrayHintShownChanged)
    // v8 迁移后的完整番茄计数规则说明；只在已有数据库的升级启动时确认一次。
    Q_PROPERTY(bool naturalCompletionNoticeShown READ naturalCompletionNoticeShown WRITE setNaturalCompletionNoticeShown NOTIFY naturalCompletionNoticeShownChanged)
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
    int freeTimerWarningHours() const;
    void setFreeTimerWarningHours(int hours);
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
    bool dashboardTimerVisible() const;
    void setDashboardTimerVisible(bool visible);
    QString goalViewMode() const;
    void setGoalViewMode(const QString& mode);
    bool reduceTransparency() const;
    void setReduceTransparency(bool enabled);
    bool raiseOnPhaseComplete() const;
    void setRaiseOnPhaseComplete(bool enabled);
    bool closeToTray() const;
    void setCloseToTray(bool enabled);
    bool closeToTrayHintShown() const;
    void setCloseToTrayHintShown(bool shown);
    bool naturalCompletionNoticeShown() const;
    void setNaturalCompletionNoticeShown(bool shown);
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

    // 快捷键自定义：按动作 id 存 QKeySequence 的 PortableText（如 "Ctrl+1"）。
    // 三种状态必须能区分开：键不存在 = 用代码里的默认键位；键存在且非空 = 用户改过；
    // 键存在但为空串 = 用户主动停用了这个动作。默认键位本身不落盘，
    // 这样以后调整默认值对没自定义过的用户能直接生效。
    Q_INVOKABLE bool hasShortcutOverride(const QString& actionId) const;
    Q_INVOKABLE QString shortcutOverride(const QString& actionId) const;
    Q_INVOKABLE bool setShortcutOverride(const QString& actionId, const QString& portableSequence);
    Q_INVOKABLE bool clearShortcutOverride(const QString& actionId);
    Q_INVOKABLE bool clearAllShortcutOverrides();
    // 从磁盘重新读取全部偏好并广播变更信号。数据恢复覆盖设置文件后调用，
    // 让 QML 绑定即时刷新，无需重启。
    Q_INVOKABLE void reload();

signals:
    void lastModeChanged();
    void workMinutesChanged();
    void breakMinutesChanged();
    void freeTimerWarningHoursChanged();
    void soundEnabledChanged();
    void reduceMotionChanged();
    void slimClockFontChanged();
    void rolloverIgnoredDateChanged();
    void backgroundThemeChanged();
    void dayStartHourChanged();
    void nicknameChanged();
    void sidebarVisibleChanged();
    void dashboardTimerVisibleChanged();
    void goalViewModeChanged();
    void reduceTransparencyChanged();
    void raiseOnPhaseCompleteChanged();
    void closeToTrayChanged();
    void closeToTrayHintShownChanged();
    void naturalCompletionNoticeShownChanged();
    void autoStartBreakChanged();
    void autoStartNextPomodoroChanged();
    void longBreakEnabledChanged();
    void longBreakMinutesChanged();
    void longBreakIntervalChanged();
    void dailyFocusGoalChanged();
    // 任意一处快捷键覆盖值变化（含批量恢复默认与数据恢复后的重读）。
    void shortcutOverridesChanged();
    void settingsWriteSucceeded(const QString& key);
    void settingsWriteFailed(const QString& key, const QString& message);

private:
    static int normalizeWorkMinutes(int minutes);
    static int normalizeBreakMinutes(int minutes);
    static int normalizeFreeTimerWarningHours(int hours);
    static int normalizeDayStartHour(int hour);
    static int normalizeLongBreakMinutes(int minutes);
    static int normalizeLongBreakInterval(int count);
    static QString shortcutKey(const QString& actionId);
    void recreateSettingsBackend();
    bool writeValue(const QString& key, const QVariant& value);
    // 删除同样要检查落盘状态：权限问题下 remove 也会静默失败，
    // 「恢复默认」不能在设置文件没变的情况下告诉用户已经改回去了。
    bool removeValue(const QString& key);
    QString m_settingsFilePath;
    QSettings* m_settings = nullptr;
};

#endif // APPSETTINGS_H
