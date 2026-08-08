#ifndef PHASESOUNDSERVICE_H
#define PHASESOUNDSERVICE_H

#include <QHash>
#include <QObject>
#include <QString>

class PhaseSoundService : public QObject
{
    Q_OBJECT

public:
    static PhaseSoundService* instance();
    explicit PhaseSoundService(QObject* parent = nullptr);

    Q_INVOKABLE bool playPhaseCompleteChime();
    Q_INVOKABLE bool playMilestoneChime();
    Q_INVOKABLE bool playGoalAchievedChime();

private:
    bool playSound(const QString& resourcePath, const QString& fileName) const;
    QString ensureSoundFile(const QString& resourcePath, const QString& fileName) const;

    // 已释放到临时目录的音频，键为资源路径。每次播放都重新 remove+copy 是
    // GUI 线程上的同步文件 I/O（40–64KB），而它恰好发生在庆祝触发的那一帧。
    // 「资源可能随版本更新」是跨版本的顾虑，而换版本必然是新进程，
    // 所以每个进程释放一次就够，缓存不需要失效策略。
    mutable QHash<QString, QString> m_extractedSounds;
};

#endif // PHASESOUNDSERVICE_H
