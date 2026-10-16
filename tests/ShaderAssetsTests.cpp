#include <QFile>
#include <QProcess>
#include <QTemporaryDir>
#include <QtTest>

// Shader 资源守门：Qt 6 的 ShaderEffect 只能读取预编译 QSB，缺失时折射层会静默失效。
class ShaderAssetsTests : public QObject
{
    Q_OBJECT

private slots:
    void liquidGlassShaderIsPackaged()
    {
        QFile shader(QStringLiteral(":/shaders/liquid_glass.frag.qsb"));
        QVERIFY2(shader.exists(), "液态玻璃 QSB 未打包进资源");
        QVERIFY2(shader.open(QIODevice::ReadOnly), "液态玻璃 QSB 无法读取");
        QVERIFY2(shader.size() > 128, "液态玻璃 QSB 内容异常或为空");
    }

    // 产品保证：实际打包的着色器来自当前源码，改了源码却忘记更新二进制不能通过验收。
    void packagedShaderMatchesCurrentSource()
    {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        const QString expectedPath = directory.filePath(QStringLiteral("expected.qsb"));
        QProcess baker;
        baker.start(QString::fromUtf8(POMODORO_SHADER_BAKER),
                    {QStringLiteral("--qt6"), QStringLiteral("-o"), expectedPath,
                     QString::fromUtf8(POMODORO_SHADER_SOURCE)});
        QVERIFY(baker.waitForStarted(5000));
        QVERIFY(baker.waitForFinished(20000));
        QCOMPARE(baker.exitStatus(), QProcess::NormalExit);
        QVERIFY2(baker.exitCode() == 0, baker.readAllStandardError().constData());
        QFile expected(expectedPath);
        QFile packaged(QStringLiteral(":/shaders/liquid_glass.frag.qsb"));
        QVERIFY(expected.open(QIODevice::ReadOnly));
        QVERIFY(packaged.open(QIODevice::ReadOnly));
        const QByteArray expectedBytes = expected.readAll();
        QVERIFY(expectedBytes.size() > 128);
        QCOMPARE(packaged.readAll(), expectedBytes);
    }
};

QTEST_APPLESS_MAIN(ShaderAssetsTests)
#include "ShaderAssetsTests.moc"
