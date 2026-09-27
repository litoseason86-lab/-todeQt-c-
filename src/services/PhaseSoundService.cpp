#include "PhaseSoundService.h"

#include <QDir>
#include <QFile>
#include <QStandardPaths>
#include <QStringList>

// iOS 没有子进程能力，Qt 的 iOS 版本也不提供 QProcess 类；只在 macOS 包含它，
// 否则 iOS 构建会在这里直接报错。
#ifdef Q_OS_MACOS
#include <QProcess>
#endif

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
    return playSound(kPhaseCompleteResource, kPhaseCompleteFileName);
}

bool PhaseSoundService::playSound(const QString& resourcePath, const QString& fileName) const
{
#ifdef Q_OS_MACOS
    const QString soundFilePath = ensureSoundFile(resourcePath, fileName);
    if (soundFilePath.isEmpty()) {
        return false;
    }

    // QtMultimedia 在当前 Qt 安装中缺失；macOS 使用系统 afplay 播放短提示音。
    // 播放失败只影响声音提醒，不能阻断窗口置前和计时状态机。
    return QProcess::startDetached(QStringLiteral("/usr/bin/afplay"), QStringList{soundFilePath});
#else
    // 其它平台（目前是 iOS）还没有提示音后端，返回 false 让调用方按"未播放"处理。
    Q_UNUSED(resourcePath);
    Q_UNUSED(fileName);
    return false;
#endif
}

QString PhaseSoundService::ensureSoundFile(const QString& resourcePath,
                                           const QString& fileName) const
{
    const QString tempRoot = QStandardPaths::writableLocation(QStandardPaths::TempLocation);
    if (tempRoot.isEmpty()) {
        return QString();
    }

    const QString targetDir = QDir(tempRoot).filePath(QStringLiteral("pomodoro-todo"));
    if (!QDir().mkpath(targetDir)) {
        return QString();
    }

    const QString targetPath = QDir(targetDir).filePath(fileName);
    QFile source(resourcePath);
    if (!source.exists()) {
        return QString();
    }

    // 本进程已经释放过就直接复用。仍然校验文件还在——临时目录可能被系统
    // 或用户清理，那种情况下要重新释放而不是把不存在的路径交给 afplay。
    const auto cached = m_extractedSounds.constFind(resourcePath);
    if (cached != m_extractedSounds.constEnd() && QFile::exists(cached.value())) {
        return cached.value();
    }

    // 首次释放时覆盖同名旧文件：上个版本残留的提示音必须被换掉。
    QFile::remove(targetPath);
    if (!source.copy(targetPath)) {
        return QString();
    }
    m_extractedSounds.insert(resourcePath, targetPath);
    QFile::setPermissions(targetPath, QFile::ReadOwner | QFile::WriteOwner | QFile::ReadGroup | QFile::ReadOther);
    return targetPath;
}
