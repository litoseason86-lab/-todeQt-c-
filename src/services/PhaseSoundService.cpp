#include "PhaseSoundService.h"

#include <QDir>
#include <QFile>
#include <QProcess>
#include <QStandardPaths>
#include <QStringList>

namespace {
const auto kPhaseCompleteResource = QStringLiteral(":/sounds/phase-complete.wav");
const auto kPhaseCompleteFileName = QStringLiteral("pomodoro-todo-phase-complete.wav");
}

PhaseSoundService* PhaseSoundService::instance()
{
    static PhaseSoundService service;
    return &service;
}

PhaseSoundService::PhaseSoundService(QObject* parent)
    : QObject(parent)
{
}

bool PhaseSoundService::playPhaseCompleteChime()
{
#ifdef Q_OS_MACOS
    const QString soundFilePath = ensurePhaseCompleteFile();
    if (soundFilePath.isEmpty()) {
        return false;
    }

    // QtMultimedia 在当前 Qt 安装中缺失；macOS 使用系统 afplay 播放短提示音。
    // 播放失败只影响声音提醒，不能阻断窗口置前和计时状态机。
    return QProcess::startDetached(QStringLiteral("/usr/bin/afplay"), QStringList{soundFilePath});
#else
    return false;
#endif
}

QString PhaseSoundService::ensurePhaseCompleteFile() const
{
    const QString tempRoot = QStandardPaths::writableLocation(QStandardPaths::TempLocation);
    if (tempRoot.isEmpty()) {
        return QString();
    }

    const QString targetDir = QDir(tempRoot).filePath(QStringLiteral("pomodoro-todo"));
    if (!QDir().mkpath(targetDir)) {
        return QString();
    }

    const QString targetPath = QDir(targetDir).filePath(kPhaseCompleteFileName);
    QFile source(kPhaseCompleteResource);
    if (!source.exists()) {
        return QString();
    }

    // 资源可能随版本更新；每次覆盖临时文件，避免旧提示音长期残留。
    QFile::remove(targetPath);
    if (!source.copy(targetPath)) {
        return QString();
    }
    QFile::setPermissions(targetPath, QFile::ReadOwner | QFile::WriteOwner | QFile::ReadGroup | QFile::ReadOther);
    return targetPath;
}
