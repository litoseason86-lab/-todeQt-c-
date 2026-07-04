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

private:
    QString ensurePhaseCompleteFile() const;
};

#endif // PHASESOUNDSERVICE_H
