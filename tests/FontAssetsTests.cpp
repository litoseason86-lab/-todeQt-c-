#include <QFile>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QtTest>

// 字体资源守门：QML 测试不经过 main.cpp、也不链 fonts.qrc，真机之外无人能发现
// qrc 别名写错、ttf 漏进资源、家族名与 Theme 令牌不符。这里用 GUI 实例 + id 作用域
// 校验，把这些盲区变成可测边界。offscreen 平台，无弹窗。
class FontAssetsTests : public QObject
{
    Q_OBJECT

private slots:
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
