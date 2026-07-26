#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QtTest>

// QML 清单守门：测试直接 import 源码目录，应用则从 qrc:/ 加载。
// 只有双向比对才能让“新文件漏登记”与“已删文件留幽灵条目”在打包前立即失败。
class QmlResourceManifestTests : public QObject
{
    Q_OBJECT

private slots:
    void everyQmlSourceFileIsInTheResourceManifest()
    {
        const QDir sourceRoot(QStringLiteral(QML_SOURCE_DIR));
        QDirIterator sourceFiles(sourceRoot.absolutePath(),
                                 QStringList{QStringLiteral("*.qml"), QStringLiteral("*.js")},
                                 QDir::Files,
                                 QDirIterator::Subdirectories);
        while (sourceFiles.hasNext()) {
            const QString sourcePath = sourceFiles.next();
            const QString relativePath = sourceRoot.relativeFilePath(sourcePath);
            const QString resourcePath = QStringLiteral(":/qml/%1").arg(relativePath);
            QVERIFY2(QFile::exists(resourcePath),
                     qPrintable(QStringLiteral("QML 源文件未登记进 resources/qml.qrc：%1")
                                    .arg(relativePath)));
        }
    }

    void everyManifestEntryHasASourceFile()
    {
        const QDir sourceRoot(QStringLiteral(QML_SOURCE_DIR));
        const QDir resourceRoot(QStringLiteral(":/qml"));
        QDirIterator resources(resourceRoot.absolutePath(), QDir::Files, QDirIterator::Subdirectories);
        while (resources.hasNext()) {
            const QString resourcePath = resources.next();
            const QString relativePath = resourceRoot.relativeFilePath(resourcePath);
            const QString sourcePath = sourceRoot.filePath(relativePath);
            QVERIFY2(QFileInfo::exists(sourcePath) && QFileInfo(sourcePath).isFile(),
                     qPrintable(QStringLiteral("resources/qml.qrc 登记了不存在的源文件：%1")
                                    .arg(relativePath)));
        }
    }
};

QTEST_APPLESS_MAIN(QmlResourceManifestTests)
#include "QmlResourceManifestTests.moc"
