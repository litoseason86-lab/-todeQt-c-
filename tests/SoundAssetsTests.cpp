#include <QFile>
#include <QStringList>
#include <QtTest>

// 音效资源守门：PhaseSoundService 按字面量路径读取 wav，rcc 只能发现源文件缺失，
// 无法发现 C++ 路径与 qrc alias 不一致。下列路径必须与服务中的常量逐字符一致。
class SoundAssetsTests : public QObject
{
    Q_OBJECT

private:
    const QStringList m_soundPaths{
        QStringLiteral(":/sounds/phase-complete.wav"),
        QStringLiteral(":/sounds/milestone.wav"),
        QStringLiteral(":/sounds/goal-achieved.wav"),
    };

    void verifyPackagedSound(int index)
    {
        QFile sound(m_soundPaths.at(index));
        QVERIFY2(sound.exists(), qPrintable(QStringLiteral("音效资源未打包：%1").arg(sound.fileName())));
        QVERIFY2(sound.open(QIODevice::ReadOnly),
                 qPrintable(QStringLiteral("音效资源无法读取：%1").arg(sound.fileName())));
        QVERIFY2(sound.size() > 1024,
                 qPrintable(QStringLiteral("音效资源内容异常或为空：%1").arg(sound.fileName())));
    }

private slots:
    void phaseCompleteSoundIsPackaged() { verifyPackagedSound(0); }
    void milestoneSoundIsPackaged() { verifyPackagedSound(1); }
    void goalAchievedSoundIsPackaged() { verifyPackagedSound(2); }

    void allSoundsAreValidWavContainers()
    {
        for (const QString &path : m_soundPaths) {
            QFile sound(path);
            QVERIFY2(sound.open(QIODevice::ReadOnly),
                     qPrintable(QStringLiteral("音效资源无法读取：%1").arg(path)));
            const QByteArray header = sound.read(12);
            // 同时校验 RIFF/WAVE 头，防止 Git LFS 指针、截断文件或改名的其它格式混入资源。
            QVERIFY2(header.size() == 12 && header.first(4) == "RIFF" && header.sliced(8, 4) == "WAVE",
                     qPrintable(QStringLiteral("音效不是有效的 WAVE 容器：%1").arg(path)));
        }
    }
};

QTEST_APPLESS_MAIN(SoundAssetsTests)
#include "SoundAssetsTests.moc"
