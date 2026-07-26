#ifndef PHASESOUNDSERVICE_H
#define PHASESOUNDSERVICE_H

#include <QObject>

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
};

#endif // PHASESOUNDSERVICE_H
