#include <QFile>
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
};

QTEST_APPLESS_MAIN(ShaderAssetsTests)
#include "ShaderAssetsTests.moc"
