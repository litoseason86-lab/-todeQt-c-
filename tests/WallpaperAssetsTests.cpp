#include <QFile>
#include <QImage>
#include <QtTest>

// 壁纸资源守门：七张主题壁纸必须打包进 qrc、可解码、尺寸 1536×1024。
class WallpaperAssetsTests : public QObject
{
    Q_OBJECT

private slots:
    void wallpaperAssets_data()
    {
        QTest::addColumn<QString>("path");
        const char* names[] = { "warm", "pink", "jiangnan", "sword", "starry", "rainy", "moon" };
        for (const char* name : names) {
            QTest::newRow(name)
                << QStringLiteral(":/resources/wallpapers/%1.png").arg(QLatin1String(name));
        }
    }

    void wallpaperAssets()
    {
        QFETCH(QString, path);
        QVERIFY2(QFile::exists(path), qPrintable(path + QStringLiteral(" 不在 qrc 里")));
        QImage image(path);
        QVERIFY2(!image.isNull(), qPrintable(path + QStringLiteral(" 无法解码")));
        QCOMPARE(image.size(), QSize(1536, 1024));
    }
};

QTEST_MAIN(WallpaperAssetsTests)
#include "WallpaperAssetsTests.moc"
