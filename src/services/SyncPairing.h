#ifndef SYNCPAIRING_H
#define SYNCPAIRING_H

#include <QByteArray>
#include <QString>
#include <QUrl>

// 服务器同步空间的配对码：服务器地址、空间编号和 32 字节端到端密钥。
// 纯函数，不读设置、不碰网络，便于控制器的界面层和测试共用。
namespace SyncPairing {

struct Info {
    QUrl baseUrl;
    QString spaceId;
    QByteArray secret;
};

QString encode(const Info& info);
bool decode(const QString& text, Info* info, QString* error);

// 32 位小写十六进制编号与 32 字节随机密钥。
QString newSpaceId();
QByteArray newSecret();

} // namespace SyncPairing

#endif // SYNCPAIRING_H
