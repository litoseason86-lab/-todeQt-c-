#ifndef NATIVEPREFERENCEDOMAIN_H
#define NATIVEPREFERENCEDOMAIN_H

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QFile>
#include <QFileInfo>
#include <QSettings>
#include <QString>

// 用系统偏好（macOS 的 defaults 域）的测试共用：偏好域只在这里决定，并写到可执行文件旁的
// <可执行文件名>.prefdomain，测试退出后由 tests/run_native_preferences_test.py 读取并清理。
// 以前 Python 端把同一套摘要算法和域名表又写了一遍，两边改漏一边就会清不掉或删错域（062 A060）；
// 现在 Python 只读这个文件，再用白名单正则把关，绝不删正式应用的偏好。
namespace NativePreferenceDomain {

// 把已经生效的偏好域名写出来。域名取 Qt 实际使用的偏好文件名（去掉 .plist），不自己拼，
// 免得和 Qt 的命名规则（组织名转小写等）对不上。写不出时返回 false，测试应当失败。
inline bool publish(const QString& domain)
{
    // 没有 QCoreApplication 时 applicationFilePath() 是空串，文件会写到当前目录（ctest 下即构建目录根），
    // 清理脚本找不到它就不清理。所以要求测试用 QTEST_MAIN / QTEST_GUILESS_MAIN，这里直接判失败。
    if (!QCoreApplication::instance()) {
        return false;
    }
    QFile file(QCoreApplication::applicationFilePath() + QStringLiteral(".prefdomain"));
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        return false;
    }
    const QByteArray bytes = domain.toUtf8();
    return file.write(bytes) == bytes.size() && file.flush();
}

// 组织名带上构建目录路径的 SHA-1 前 8 位，让几个工作区（各自的构建目录）同时跑同一个测试时各用一份偏好，
// 互不改写日界、每日目标这类设置；同一构建目录跨运行沿用同一个域。必须在第一次构造 QSettings
// （含 AppSettings::instance()）之前调用。
//
// organizationPrefix 沿用各测试原来的值：KnowledgeGapServiceTests 历来用 PomodoroTodoTest-（少一个 s），
// 统一会让已经落在旧域里的偏好变成没人清理的孤儿，所以保留这个差异。
inline QString isolateByBuildDirectory(const QString& organizationPrefix, bool* published)
{
    const QByteArray buildDirDigest = QCryptographicHash::hash(
        QCoreApplication::applicationDirPath().toUtf8(), QCryptographicHash::Sha1).toHex().left(8);
    QCoreApplication::setOrganizationName(organizationPrefix + QString::fromLatin1(buildDirDigest));
    const QString domain = QFileInfo(QSettings().fileName()).completeBaseName();
    const bool ok = publish(domain);
    if (published) *published = ok;
    return domain;
}

} // namespace NativePreferenceDomain

#endif // NATIVEPREFERENCEDOMAIN_H
