#include "AppleSyncBlockCipher.h"

#import <CommonCrypto/CommonCryptor.h>

#include <vector>

namespace {

constexpr int kAesKeyBytes = 32;
constexpr int kAesBlockBytes = kCCBlockSizeAES128;

bool runCipher(CCOperation operation, const QByteArray& key,
               const QByteArray& iv, const QByteArray& input,
               QByteArray* output)
{
    if (output) {
        output->clear();
    }
    if (!output || key.size() != kAesKeyBytes
        || iv.size() != kAesBlockBytes
        || (operation == kCCDecrypt
            && (input.isEmpty() || input.size() % kAesBlockBytes != 0))) {
        return false;
    }

    // CCCrypt 的 PKCS#7 可能让加密多出一个完整块，解密则最多回收一个块；
    // 预留一个额外块可以避免把输出长度限制误判成失败。
    std::vector<unsigned char> buffer(
        static_cast<size_t>(input.size()) + kAesBlockBytes);
    size_t moved = 0;
    const CCCryptorStatus status = CCCrypt(
        operation,
        kCCAlgorithmAES,
        kCCOptionPKCS7Padding,
        key.constData(),
        static_cast<size_t>(key.size()),
        iv.constData(),
        input.constData(),
        static_cast<size_t>(input.size()),
        buffer.data(),
        buffer.size(),
        &moved);
    if (status != kCCSuccess || moved > buffer.size()) {
        return false;
    }
    *output = QByteArray(
        reinterpret_cast<const char*>(buffer.data()),
        static_cast<int>(moved));
    return true;
}

} // namespace

bool AppleSyncBlockCipher::encrypt(const QByteArray& key, const QByteArray& iv,
                                   const QByteArray& plain, QByteArray* out)
{
    return runCipher(kCCEncrypt, key, iv, plain, out);
}

bool AppleSyncBlockCipher::decrypt(const QByteArray& key, const QByteArray& iv,
                                   const QByteArray& cipher, QByteArray* out)
{
    return runCipher(kCCDecrypt, key, iv, cipher, out);
}
