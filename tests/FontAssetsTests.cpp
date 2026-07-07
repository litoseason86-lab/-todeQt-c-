#include <QFile>
#include <QFontDatabase>
#include <QFontInfo>
#include <QGuiApplication>
#include <QtTest>

// 字体资源守门：QML 测试不经过 main.cpp、也不链 fonts.qrc，真机之外无人能发现
// qrc 别名写错、ttf 漏进资源、家族名与 Theme 令牌不符。这里用 GUI 实例 + id 作用域
// 校验，把这些盲区变成可测边界。offscreen 平台，无弹窗。
class FontAssetsTests : public QObject
{
    Q_OBJECT

private slots:
    void spaceGroteskLightRegistersAsSpaceGroteskLight();
    void spaceGroteskMediumRegistersAsSpaceGrotesk();
    void spaceGroteskBoldRegistersAsSpaceGrotesk();
    void bricolageBoldRegistersAsBricolage();

private:
    // family 名取自打包的这个文件本身（applicationFontFamilies(id)），
    // 而非系统全局 families()，否则开发机若已装同名字体会假绿。
    void assertFontFamily(const QString& resourcePath, const QString& expectedFamily)
    {
        QVERIFY2(QFile(resourcePath).exists(),
                 qPrintable(QStringLiteral("资源不存在: ") + resourcePath));
        const int id = QFontDatabase::addApplicationFont(resourcePath);
        QVERIFY2(id != -1,
                 qPrintable(QStringLiteral("注册失败: ") + resourcePath));
        const QStringList families = QFontDatabase::applicationFontFamilies(id);
        QVERIFY2(families.contains(expectedFamily),
                 qPrintable(QStringLiteral("家族名不符，期望 ") + expectedFamily
                            + QStringLiteral("，实际 ") + families.join(QLatin1Char(','))));
    }
};

void FontAssetsTests::spaceGroteskLightRegistersAsSpaceGroteskLight()
{
    const QString resourcePath = QStringLiteral(":/fonts/SpaceGrotesk-Light.ttf");
    QVERIFY2(QFile(resourcePath).exists(),
             qPrintable(QStringLiteral("资源不存在: ") + resourcePath));

    const int id = QFontDatabase::addApplicationFont(resourcePath);
    QVERIFY2(id != -1,
             qPrintable(QStringLiteral("注册失败: ") + resourcePath));

    // 主证据 1：只信任刚注册资源自己的 family 名，避免开发机已装同名字体造成假绿。
    const QStringList families = QFontDatabase::applicationFontFamilies(id);
    QVERIFY2(families.contains(QStringLiteral("Space Grotesk")),
             qPrintable(QStringLiteral("family 名不符，实际 ")
                        + families.join(QLatin1Char(','))));

    // 主证据 2：请求 Light 字重时必须解析到细字重档，拦住 Regular/Medium 文件塞错别名。
    QFont requested(QStringLiteral("Space Grotesk"));
    requested.setWeight(QFont::Light);
    const int resolvedWeight = QFontInfo(requested).weight();
    QVERIFY2(resolvedWeight <= QFont::Normal,
             qPrintable(QStringLiteral("请求 Light 未解析到细字重，实际 weight=")
                        + QString::number(resolvedWeight)));

    // 辅助证据：styles() 查询全局家族，不能单独作为判断依据，但能给失败时更直接的诊断。
    const QStringList styles = QFontDatabase::styles(QStringLiteral("Space Grotesk"));
    QVERIFY2(styles.contains(QStringLiteral("Light")),
             qPrintable(QStringLiteral("styles 无 Light（仅辅助），实际 ")
                        + styles.join(QLatin1Char(','))));
}

void FontAssetsTests::spaceGroteskMediumRegistersAsSpaceGrotesk()
{
    assertFontFamily(QStringLiteral(":/fonts/SpaceGrotesk-Medium.ttf"),
                     QStringLiteral("Space Grotesk"));
}

void FontAssetsTests::spaceGroteskBoldRegistersAsSpaceGrotesk()
{
    assertFontFamily(QStringLiteral(":/fonts/SpaceGrotesk-Bold.ttf"),
                     QStringLiteral("Space Grotesk"));
}

void FontAssetsTests::bricolageBoldRegistersAsBricolage()
{
    assertFontFamily(QStringLiteral(":/fonts/BricolageGrotesque-Bold.ttf"),
                     QStringLiteral("Bricolage Grotesque"));
}

QTEST_MAIN(FontAssetsTests)
#include "FontAssetsTests.moc"
