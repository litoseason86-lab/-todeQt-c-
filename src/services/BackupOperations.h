#ifndef BACKUPOPERATIONS_H
#define BACKUPOPERATIONS_H

#include "BackupOperationControl.h"

#include <QByteArray>
#include <QJsonValue>
#include <QMap>
#include <QString>
#include <QVariantMap>

#include <cmath>
#include <memory>

class QSettings;

namespace BackupOperations {

// 外部备份包含本机历史、同步日志和索引，独立于同步快照预算；超限必须拒绝，不能截断。
inline constexpr qint64 kMaxBackupFileBytes = 512LL * 1024 * 1024;
inline constexpr qint64 kMaxBackupRows = 5'000'000;
inline constexpr qint64 kMaxBackupCellBytes = 16LL * 1024 * 1024;

// 每日目标历史每天最多一个键，约 365 个/年；40000 项可容纳约 100 年历史及几十项普通偏好。
inline constexpr int kMaxSettingEntries = 40000;
// 单值按序列化后的字节计量，沿用旧格式上限，避免外部长度字段引起过量分配。
inline constexpr int kMaxSettingValueBytes = 64 * 1024;
// 自有键的 UTF-8 字节与序列化值合计；限制外部文件解析内存，不作为业务输入限制。
inline constexpr qint64 kMaxSettingsTotalBytes = 8LL * 1024 * 1024;

// 平台字段只用于显示与排查；按运行时产品类型映射，避免服务层引入编译期平台分支。
// macOS 保持旧备份的显示值，其余未识别产品类型原样保留。
QString platformDisplayName(const QString& productType);

// 打开偏好存储：路径为空时是生产用的 macOS 原生偏好，否则是 ini 文件（测试用）。
// 原生偏好默认开启回退，allKeys() 会连系统全局域的键（文本替换词典、语言、地区……）
// 一起列出来；这里一律关掉回退，只看本应用自己的偏好域。
std::unique_ptr<QSettings> openSettings(const QString& settingsFilePath);

// 本机偏好快照要覆盖的键：本应用拥有的分组，加上只属于这台设备的自动备份策略（backup/）。
// 回滚和「保留本机备份策略」都只处理这些键，别的键既不读也不写。
bool isLocalSettingKey(const QString& key);

struct OperationResult
{
    bool success = false;
    QString error;
    // 原子提交已发生时保留事实；提交后取消不能让调用方误判为原目标未动。
    bool committed = false;
};

struct EmbeddedSettingsResult
{
    bool success = false;
    QString error;
    QVariantMap values;
};

// 请求只带已经序列化的应用偏好；执行器不接触主进程的偏好域。
using OwnedSettings = QMap<QString, QByteArray>;

// 捕获、协议及文件读取共用预算；只计本应用拥有的键，不截断或删除历史。
bool checkSettingsBudget(const OwnedSettings& values, QString* reason);
// 校验输出路径（备份或 CSV 导出）不得覆盖主库、SQLite 附属文件、同步状态文件或当前偏好文件。
bool checkProtectedOutputPath(const QString& destinationPath,
                              const QString& sourceDatabasePath,
                              const QString& effectiveSettingsPath,
                              const QString& targetLabel,
                              QString* reason);

struct CapturedSettingsResult
{
    bool success = false;
    QString error;
    OwnedSettings values;
    QString effectiveSettingsPath;
};

struct SnapshotRequest
{
    QString sourceDatabasePath;
    QString destinationPath;
    QString stagingDirectory;
    QString effectiveSettingsPath;
    QString kind;
    int currentSchemaVersion = 0;
    OwnedSettings settings;
};

CapturedSettingsResult captureOwnedSettings(const QString& settingsFilePath,
                                            const BackupOperation& operation = {});
OperationResult createSnapshot(const SnapshotRequest& request,
                               const BackupOperation& operation = {});
OperationResult createSnapshot(const QString& sourceDatabasePath,
                               const QString& settingsFilePath,
                               const QString& destinationPath,
                               const QString& kind,
                               int currentSchemaVersion,
                               const BackupOperation& operation = {},
                               const QString& stagingDirectory = {});
QVariantMap inspectBackup(const QString& sourcePath, int currentSchemaVersion,
                          const BackupOperation& operation = {});
EmbeddedSettingsResult readEmbeddedSettings(const QString& sourcePath,
                                            const BackupOperation& operation = {});
// 外部暂存和发布备份必须传同源预算；本地可信回滚沿用负值，不因新支持上限丢失回滚能力。
OperationResult atomicCopy(const QString& sourcePath, const QString& destinationPath,
                           qint64 maxBytes = -1, const BackupOperation& operation = {});

// ── 业务值域校验（与 validateBusinessValues 的 SQLite 契约逐项同源，供废纸篓恢复等上游入库拦截复用） ──

// JSON 数字转精确整数：排除 NaN/Inf、小数以及超出 IEEE 754 双精度精确整数上限（2^53）的数值。
inline bool strictJsonInt(const QJsonValue& value, qint64* out)
{
    constexpr double kMaxExactInteger = 9007199254740992.0;
    if (!value.isDouble()) {
        return false;
    }
    const double number = value.toDouble();
    if (!std::isfinite(number) || std::trunc(number) != number
        || number < -kMaxExactInteger || number > kMaxExactInteger) {
        return false;
    }
    if (out) {
        *out = static_cast<qint64>(number);
    }
    return true;
}

// 规范业务日期：严格 10 字符 YYYY-MM-DD 公历有效日期，且拒绝公元 0000 年（与 SQLite date(x, '+0 days') IS x 同口径）。
inline bool isValidBusinessDate(const QString& text)
{
    if (text.size() != 10 || text.at(4) != QLatin1Char('-') || text.at(7) != QLatin1Char('-')) {
        return false;
    }
    const auto isAsciiDigit = [](QChar c) {
        return c.unicode() >= '0' && c.unicode() <= '9';
    };
    for (int i : {0, 1, 2, 3, 5, 6, 8, 9}) {
        if (!isAsciiDigit(text.at(i))) {
            return false;
        }
    }
    const int year = text.left(4).toInt();
    const int month = text.mid(5, 2).toInt();
    const int day = text.mid(8, 2).toInt();
    if (year < 1 || month < 1 || month > 12 || day < 1) {
        return false;
    }
    static constexpr int kDaysInMonth[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    int maxDay = kDaysInMonth[month - 1];
    if (month == 2 && ((year % 4 == 0 && year % 100 != 0) || (year % 400 == 0))) {
        maxDay = 29;
    }
    return day <= maxDay;
}

// 规范业务日期时间：前 10 位是有效 YYYY-MM-DD 公历日期，且整体符合 SQLite datetime() 可解析的 ISO 时间语法。
inline bool isValidBusinessDateTime(const QString& text)
{
    if (text.size() < 10 || !isValidBusinessDate(text.left(10))) {
        return false;
    }
    if (text.size() == 10) {
        return true;
    }
    const QChar sep = text.at(10);
    if (sep != QLatin1Char(' ') && sep != QLatin1Char('T')) {
        return false;
    }
    const auto isAsciiDigit = [](QChar c) {
        return c.unicode() >= '0' && c.unicode() <= '9';
    };
    // 至少包含 HH:MM（总长 >= 16）
    if (text.size() < 16 || !isAsciiDigit(text.at(11)) || !isAsciiDigit(text.at(12))
        || text.at(13) != QLatin1Char(':') || !isAsciiDigit(text.at(14)) || !isAsciiDigit(text.at(15))) {
        return false;
    }
    const int hour = text.mid(11, 2).toInt();
    const int minute = text.mid(14, 2).toInt();
    if (hour > 24 || minute > 59) {
        return false;
    }
    int pos = 16;
    int second = 0;
    bool nonZeroFraction = false;
    if (pos < text.size() && text.at(pos) == QLatin1Char(':')) {
        if (pos + 2 >= text.size() || !isAsciiDigit(text.at(pos + 1)) || !isAsciiDigit(text.at(pos + 2))) {
            return false;
        }
        second = text.mid(pos + 1, 2).toInt();
        if (second > 59) {
            return false;
        }
        pos += 3;
        if (pos < text.size() && text.at(pos) == QLatin1Char('.')) {
            ++pos;
            const int fracStart = pos;
            while (pos < text.size() && isAsciiDigit(text.at(pos))) {
                if (text.at(pos) != QLatin1Char('0')) {
                    nonZeroFraction = true;
                }
                ++pos;
            }
            if (pos == fracStart) {
                return false;
            }
        }
    }
    if (hour == 24 && (minute != 0 || second != 0 || nonZeroFraction)) {
        return false;
    }
    if (pos == text.size()) {
        return true;
    }
    if (pos + 1 == text.size() && (text.at(pos) == QLatin1Char('Z') || text.at(pos) == QLatin1Char('z'))) {
        return true;
    }
    if (pos + 6 == text.size() && (text.at(pos) == QLatin1Char('+') || text.at(pos) == QLatin1Char('-'))
        && isAsciiDigit(text.at(pos + 1)) && isAsciiDigit(text.at(pos + 2))
        && text.at(pos + 3) == QLatin1Char(':')
        && isAsciiDigit(text.at(pos + 4)) && isAsciiDigit(text.at(pos + 5))) {
        const int tzHour = text.mid(pos + 1, 2).toInt();
        const int tzMin = text.mid(pos + 4, 2).toInt();
        return tzMin <= 59 && (tzHour * 60 + tzMin) <= 14 * 60;
    }
    return false;
}

} // namespace BackupOperations

#endif // BACKUPOPERATIONS_H
