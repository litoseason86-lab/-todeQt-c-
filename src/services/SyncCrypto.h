#ifndef SYNCCRYPTO_H
#define SYNCCRYPTO_H

#include <QByteArray>
#include <QString>

// 只抽象 AES-256-CBC 这一种平台原语。HKDF、校验值、封装格式与随机 IV 都留在
// 平台无关层，避免 Mac 与 iPad 各自实现一套容易漂移的密码学协议。
class SyncBlockCipher
{
public:
    virtual ~SyncBlockCipher() = default;

    virtual bool encrypt(const QByteArray& key, const QByteArray& iv,
                         const QByteArray& plain, QByteArray* out)
        = 0;
    virtual bool decrypt(const QByteArray& key, const QByteArray& iv,
                         const QByteArray& cipher, QByteArray* out)
        = 0;
};

namespace SyncCrypto {

// RFC 5869 的 HKDF-SHA256；length 超过协议允许的 255 个摘要块时返回空。
QByteArray hkdfSha256(const QByteArray& ikm, const QByteArray& salt,
                      const QByteArray& info, int length);

struct Keys {
    QByteArray authToken;
    QByteArray encKey;
    QByteArray macKey;
};

// 配对密钥必须正好 32 字节。派生用空间编号作 salt，三个用途各取独立的 32 字节。
Keys deriveKeys(const QByteArray& secret, const QString& spaceId);

// 服务器鉴权令牌的文本形式：无填充 base64url。
QString authTokenText(const Keys& keys);

// 密文格式："PTE1" | 16 字节随机 IV | CBC 密文 | 32 字节 HMAC-SHA256 校验值。
// 校验值把路径绑定进认证范围，服务器把 A 文件挪到 B 路径后也无法冒充 B。
bool seal(SyncBlockCipher& cipher, const Keys& keys,
          const QString& relativePath, const QByteArray& plain,
          QByteArray* sealed, QString* error);

// 先检查长度、magic 和校验值，全部通过后才调用平台解密原语。
bool open(SyncBlockCipher& cipher, const Keys& keys,
          const QString& relativePath, const QByteArray& sealed,
          QByteArray* plain, QString* error);

} // namespace SyncCrypto

#endif // SYNCCRYPTO_H
