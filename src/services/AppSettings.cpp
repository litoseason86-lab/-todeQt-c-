#include "AppSettings.h"

namespace {
const auto kLastModeKey = QStringLiteral("focus/lastMode");
const auto kWorkMinutesKey = QStringLiteral("focus/workMinutes");
const auto kBreakMinutesKey = QStringLiteral("focus/breakMinutes");
const auto kSoundEnabledKey = QStringLiteral("focus/soundEnabled");
}

AppSettings* AppSettings::instance()
{
    static AppSettings settings;
    return &settings;
}

AppSettings::AppSettings(const QString& settingsFilePath, QObject* parent)
    : QObject(parent)
    , m_settings(settingsFilePath.isEmpty()
                     ? new QSettings(this)
                     : new QSettings(settingsFilePath, QSettings::IniFormat, this))
{
}

int AppSettings::lastMode() const
{
    return m_settings->value(kLastModeKey, 0).toInt();
}

void AppSettings::setLastMode(int mode)
{
    if (lastMode() == mode) {
        return;
    }
    m_settings->setValue(kLastModeKey, mode);
    // 偏好写入后立即落盘，避免应用被强制退出时丢掉用户刚选择的启动模式。
    m_settings->sync();
    emit lastModeChanged();
}

int AppSettings::workMinutes() const
{
    return m_settings->value(kWorkMinutesKey, 25).toInt();
}

void AppSettings::setWorkMinutes(int minutes)
{
    if (workMinutes() == minutes) {
        return;
    }
    m_settings->setValue(kWorkMinutesKey, minutes);
    m_settings->sync();
    emit workMinutesChanged();
}

int AppSettings::breakMinutes() const
{
    return m_settings->value(kBreakMinutesKey, 5).toInt();
}

void AppSettings::setBreakMinutes(int minutes)
{
    if (breakMinutes() == minutes) {
        return;
    }
    m_settings->setValue(kBreakMinutesKey, minutes);
    m_settings->sync();
    emit breakMinutesChanged();
}

bool AppSettings::soundEnabled() const
{
    return m_settings->value(kSoundEnabledKey, true).toBool();
}

void AppSettings::setSoundEnabled(bool enabled)
{
    if (soundEnabled() == enabled) {
        return;
    }
    m_settings->setValue(kSoundEnabledKey, enabled);
    m_settings->sync();
    emit soundEnabledChanged();
}
