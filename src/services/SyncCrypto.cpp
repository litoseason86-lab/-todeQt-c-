#include "SyncCrypto.h"

#include <QCryptographicHash>
#include <QMessageAuthenticationCode>
#include <QRandomGenerator>

#include <cstring>
#include <limits>

namespace {

constexpr int kKeyBytes = 32;
constexpr int kIvBytes = 16;
constexpr int kTagBytes = 32;
constexpr int kMagicBytes = 4;
constexpr int kMinimumSealedBytes
    = kMagicBytes + kIvBytes + 16 + kTagBytes;
const QByteArray kMagic = QByteArrayLiteral("PTE1");

void setError(QString* target, const QString& message)
{
    if (target) {
        *target = message;
    }
}

bool hasValidKeys(const SyncCrypto::Keys& keys)
{
    return keys.authToken.size() == kKeyBytes
        && keys.encKey.size() == kKeyBytes
        && keys.macKey.size() == kKeyBytes;
}

QByteArray hmacSha256(const QByteArray& key, const QByteArray& data)
{
    return QMessageAuthenticationCode::hash(
        data, key, QCryptographicHash::Sha256);
}

QByteArray authenticationInput(const QString& relativePath,
                               const QByteArray& iv,
                               const QByteArray& ciphertext)
{
    const QByteArray path = relativePath.toUtf8();
    if (path.size() > std::numeric_limits<quint32>::max()) {
        return {};
    }
    const quint32 pathLength = static_cast<quint32>(path.size());
    QByteArray input;
    input.reserve(kMagicBytes + 4 + path.size() + iv.size()
                  + ciphertext.size());
    input.append(kMagic);
    input.append(static_cast<char>((pathLength >> 24) & 0xff));
    input.append(static_cast<char>((pathLength >> 16) & 0xff));
    input.append(static_cast<char>((pathLength >> 8) & 0xff));
    input.append(static_cast<char>(pathLength & 0xff));
    input.append(path);
    input.append(iv);
    input.append(ciphertext);
    return input;
}

bool constantTimeEqual(const QByteArray& left, const QByteArray& right)
{
    if (left.size() != right.size()) {
        return false;
    }
    unsigned char difference = 0;
    for (int index = 0; index < left.size(); ++index) {
        difference |= static_cast<unsigned char>(left.at(index))
            ^ static_cast<unsigned char>(right.at(index));
    }
    return difference == 0;
}

QByteArray randomIv()
{
    QByteArray iv(kIvBytes, Qt::Uninitialized);
    QRandomGenerator* generator = QRandomGenerator::system();
    for (int offset = 0; offset < kIvBytes; offset += 4) {
        const quint32 value = generator->generate();
        const char bytes[4] = {
            static_cast<char>((value >> 24) & 0xff),
            static_cast<char>((value >> 16) & 0xff),
            static_cast<char>((value >> 8) & 0xff),
            static_cast<char>(value & 0xff),
        };
        std::memcpy(iv.data() + offset, bytes, sizeof(bytes));
    }
    return iv;
}

} // namespace

namespace SyncCrypto {

QByteArray hkdfSha256(const QByteArray& ikm, const QByteArray& salt,
                      const QByteArray& info, int length)
{
    if (length <= 0 || length > 255 * kKeyBytes) {
        return {};
    }

    const QByteArray pseudoRandomKey = hmacSha256(salt, ikm);
    QByteArray output;
    output.reserve(length);
    QByteArray previous;
    for (quint8 counter = 1; output.size() < length; ++counter) {
        QByteArray input = previous;
        input.append(info);
        input.append(static_cast<char>(counter));
        previous = hmacSha256(pseudoRandomKey, input);
        const qsizetype remaining = length - output.size();
        output.append(previous.constData(),
                      qMin(remaining, previous.size()));
    }
    return output;
}

Keys deriveKeys(const QByteArray& secret, const QString& spaceId)
{
    if (secret.size() != kKeyBytes) {
        return {};
    }
    const QByteArray salt = spaceId.toUtf8();
    Keys keys;
    keys.authToken = hkdfSha256(
        secret, salt, QByteArrayLiteral("pt-sync auth v1"), kKeyBytes);
    keys.encKey = hkdfSha256(
        secret, salt, QByteArrayLiteral("pt-sync enc v1"), kKeyBytes);
    keys.macKey = hkdfSha256(
        secret, salt, QByteArrayLiteral("pt-sync mac v1"), kKeyBytes);
    if (!hasValidKeys(keys)) {
        return {};
    }
    return keys;
}

QString authTokenText(const Keys& keys)
{
    if (!hasValidKeys(keys)) {
        return {};
    }
    return QString::fromLatin1(
        keys.authToken.toBase64(QByteArray::Base64UrlEncoding
                                | QByteArray::OmitTrailingEquals));
}

bool seal(SyncBlockCipher& cipher, const Keys& keys,
          const QString& relativePath, const QByteArray& plain,
          QByteArray* sealed, QString* error)
{
    if (sealed) {
        sealed->clear();
    }
    if (!hasValidKeys(keys)) {
        setError(error, QStringLiteral("同步密钥无效"));
        return false;
    }
    if (relativePath.isEmpty()
        || relativePath.toUtf8().size()
            > std::numeric_limits<quint32>::max()) {
        setError(error, QStringLiteral("同步文件路径无效"));
        return false;
    }

    const QByteArray iv = randomIv();
    QByteArray ciphertext;
    if (!cipher.encrypt(keys.encKey, iv, plain, &ciphertext)
        || ciphertext.isEmpty()
        || ciphertext.size() % 16 != 0) {
        setError(error, QStringLiteral("同步文件加密失败"));
        return false;
    }

    const QByteArray tag = hmacSha256(
        keys.macKey,
        authenticationInput(relativePath, iv, ciphertext));
    QByteArray result;
    result.reserve(kMagicBytes + iv.size() + ciphertext.size()
                   + tag.size());
    result.append(kMagic);
    result.append(iv);
    result.append(ciphertext);
    result.append(tag);
    if (sealed) {
        *sealed = result;
    }
    setError(error, {});
    return true;
}

bool open(SyncBlockCipher& cipher, const Keys& keys,
          const QString& relativePath, const QByteArray& sealed,
          QByteArray* plain, QString* error)
{
    if (plain) {
        plain->clear();
    }
    if (!hasValidKeys(keys)) {
        setError(error, QStringLiteral("同步密钥无效"));
        return false;
    }
    if (sealed.size() < kMinimumSealedBytes) {
        setError(error, QStringLiteral("同步文件格式不完整"));
        return false;
    }
    if (sealed.left(kMagicBytes) != kMagic) {
        setError(error, QStringLiteral("同步文件版本不认识"));
        return false;
    }

    const QByteArray iv = sealed.mid(kMagicBytes, kIvBytes);
    const qsizetype tagOffset = sealed.size() - kTagBytes;
    const QByteArray ciphertext
        = sealed.mid(kMagicBytes + kIvBytes,
                     tagOffset - kMagicBytes - kIvBytes);
    if (ciphertext.isEmpty() || ciphertext.size() % 16 != 0) {
        setError(error, QStringLiteral("同步文件密文长度不合法"));
        return false;
    }
    const QByteArray actualTag = sealed.right(kTagBytes);
    const QByteArray expectedTag = hmacSha256(
        keys.macKey,
        authenticationInput(relativePath, iv, ciphertext));
    if (!constantTimeEqual(actualTag, expectedTag)) {
        setError(error, QStringLiteral("同步文件校验不通过"));
        return false;
    }

    QByteArray decrypted;
    if (!cipher.decrypt(keys.encKey, iv, ciphertext, &decrypted)) {
        setError(error, QStringLiteral("同步文件解密失败"));
        return false;
    }
    if (plain) {
        *plain = decrypted;
    }
    setError(error, {});
    return true;
}

} // namespace SyncCrypto
