#ifndef APPLESYNCBLOCKCIPHER_H
#define APPLESYNCBLOCKCIPHER_H

#include "../../services/SyncCrypto.h"

// Apple 两端共用的 AES-256-CBC + PKCS#7 原语。密钥派生、格式和 HMAC 都在
// PTCore 的 SyncCrypto 中完成，这个类只负责把一段合法块交给 CommonCrypto。
class AppleSyncBlockCipher final : public SyncBlockCipher
{
public:
    bool encrypt(const QByteArray& key, const QByteArray& iv,
                 const QByteArray& plain, QByteArray* out) override;
    bool decrypt(const QByteArray& key, const QByteArray& iv,
                 const QByteArray& cipher, QByteArray* out) override;
};

#endif // APPLESYNCBLOCKCIPHER_H
