#include "../src/services/SyncCrypto.h"

#include <QByteArray>
#include <QTest>

#include <algorithm>

namespace {

// 测试替身只保证可逆和 16 字节块边界，不模拟 AES；真实 AES 由 Apple 层测试与
// RemoteSyncFolderTests 覆盖。这里要验证的是格式、校验顺序和“失败时不调用解密”。
class RecordingBlockCipher final : public SyncBlockCipher
{
public:
    bool encrypt(const QByteArray& key, const QByteArray& iv,
                 const QByteArray& plain, QByteArray* out) override
    {
        ++encryptCalls;
        if (key.size() != 32 || iv.size() != 16) {
            return false;
        }
        QByteArray padded = plain;
        const char padding = static_cast<char>(16 - (plain.size() % 16));
        padded.append(QByteArray(padding, padding));
        for (int index = 0; index < padded.size(); ++index) {
            padded[index] = static_cast<char>(
                padded.at(index) ^ key.at(index % key.size())
                ^ iv.at(index % iv.size()));
        }
        *out = padded;
        return true;
    }

    bool decrypt(const QByteArray& key, const QByteArray& iv,
                 const QByteArray& cipher, QByteArray* out) override
    {
        ++decryptCalls;
        if (key.size() != 32 || iv.size() != 16 || cipher.isEmpty()
            || cipher.size() % 16 != 0) {
            return false;
        }
        QByteArray padded = cipher;
        for (int index = 0; index < padded.size(); ++index) {
            padded[index] = static_cast<char>(
                padded.at(index) ^ key.at(index % key.size())
                ^ iv.at(index % iv.size()));
        }
        const int padding = static_cast<unsigned char>(padded.back());
        if (padding <= 0 || padding > 16 || padding > padded.size()) {
            return false;
        }
        padded.chop(padding);
        *out = padded;
        return true;
    }

    int encryptCalls = 0;
    int decryptCalls = 0;
};

QByteArray secret(char value = 'A')
{
    return QByteArray(32, value);
}

} // namespace

class SyncCryptoTests : public QObject
{
    Q_OBJECT

private slots:
    void hkdfMatchesRfc5869();
    void keyDerivationSeparatesPurposes();
    void sealRoundTripsAndUsesRandomIv();
    void openRejectsMalformedInputBeforeDecrypting();
};

// 保证 HKDF-SHA256 与 RFC 5869 三个标准测试向量逐字节一致。
void SyncCryptoTests::hkdfMatchesRfc5869()
{
    struct Vector {
        const char* name;
        QByteArray ikm;
        QByteArray salt;
        QByteArray info;
        int length;
        QByteArray expected;
    };
    const QList<Vector> vectors = {
        {
            "case 1",
            QByteArray::fromHex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"
                                "0b0b0b0b0b0b"),
            QByteArray::fromHex("000102030405060708090a0b0c"),
            QByteArray::fromHex("f0f1f2f3f4f5f6f7f8f9"),
            42,
            QByteArray::fromHex(
                "3cb25f25faacd57a90434f64d0362f2a"
                "2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
                "34007208d5b887185865"),
        },
        {
            "case 2",
            QByteArray::fromHex(
                "000102030405060708090a0b0c0d0e0f"
                "101112131415161718191a1b1c1d1e1f"
                "202122232425262728292a2b2c2d2e2f"
                "303132333435363738393a3b3c3d3e3f"
                "404142434445464748494a4b4c4d4e4f"),
            QByteArray::fromHex(
                "606162636465666768696a6b6c6d6e6f"
                "707172737475767778797a7b7c7d7e7f"
                "808182838485868788898a8b8c8d8e8f"
                "909192939495969798999a9b9c9d9e9f"
                "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"),
            QByteArray::fromHex(
                "b0b1b2b3b4b5b6b7b8b9babbbcbdbebf"
                "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"
                "d0d1d2d3d4d5d6d7d8d9dadbdcdddedf"
                "e0e1e2e3e4e5e6e7e8e9eaebecedeeef"
                "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"),
            82,
            QByteArray::fromHex(
                "b11e398dc80327a1c8e7f78c596a4934"
                "4f012eda2d4efad8a050cc4c19afa97c"
                "59045a99cac7827271cb41c65e590e09"
                "da3275600c2f09b8367793a9aca3db71"
                "cc30c58179ec3e87c14c01d5c1f3434f"
                "1d87"),
        },
        {
            "case 3",
            QByteArray::fromHex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"
                                "0b0b0b0b0b0b"),
            {},
            {},
            42,
            QByteArray::fromHex(
                "8da4e775a563c18f715f802a063c5a31"
                "b8a11f5c5ee1879ec3454e5f3c738d2d"
                "9d201395faa4b61a96c8"),
        },
    };

    for (const Vector& vector : vectors) {
        QCOMPARE(SyncCrypto::hkdfSha256(
                     vector.ikm, vector.salt, vector.info, vector.length),
                 vector.expected);
    }
}

// 保证 32 字节配对密钥派生出三把互不相同、长度固定的用途密钥，错误长度直接拒绝。
void SyncCryptoTests::keyDerivationSeparatesPurposes()
{
    const SyncCrypto::Keys keys
        = SyncCrypto::deriveKeys(secret(), QStringLiteral("space-1234567890ab"));
    QCOMPARE(keys.authToken.size(), 32);
    QCOMPARE(keys.encKey.size(), 32);
    QCOMPARE(keys.macKey.size(), 32);
    QVERIFY(keys.authToken != keys.encKey);
    QVERIFY(keys.authToken != keys.macKey);
    QVERIFY(keys.encKey != keys.macKey);

    const QString tokenText = SyncCrypto::authTokenText(keys);
    QVERIFY(!tokenText.isEmpty());
    QVERIFY(!tokenText.contains(QLatin1Char('=')));
    QVERIFY(!tokenText.contains(QLatin1Char('+')));
    QVERIFY(!tokenText.contains(QLatin1Char('/')));

    QVERIFY(SyncCrypto::deriveKeys(
                QByteArray(31, 'A'), QStringLiteral("space")).authToken.isEmpty());
    QVERIFY(SyncCrypto::deriveKeys(
                QByteArray(33, 'A'), QStringLiteral("space")).encKey.isEmpty());
    QVERIFY(SyncCrypto::deriveKeys(
                secret(), QStringLiteral("space-a")).macKey
            != SyncCrypto::deriveKeys(
                secret(), QStringLiteral("space-b")).macKey);
}

// 保证同一明文可解封回原内容，且两次封装因随机 IV 不同而产生不同密文。
void SyncCryptoTests::sealRoundTripsAndUsesRandomIv()
{
    RecordingBlockCipher cipher;
    const SyncCrypto::Keys keys
        = SyncCrypto::deriveKeys(secret(), QStringLiteral("space-1234567890ab"));
    const QByteArray plain
        = QByteArrayLiteral("任务、备忘录与同步批次都不能出现在服务器密文里");
    QByteArray first;
    QByteArray second;
    QString error;
    QVERIFY2(SyncCrypto::seal(
                 cipher, keys, QStringLiteral("devices/id/cursor.json"),
                 plain, &first, &error),
             qPrintable(error));
    QVERIFY2(SyncCrypto::seal(
                 cipher, keys, QStringLiteral("devices/id/cursor.json"),
                 plain, &second, &error),
             qPrintable(error));
    QVERIFY(first.startsWith("PTE1"));
    QVERIFY(second.startsWith("PTE1"));
    QVERIFY(first != second);

    QByteArray opened;
    QVERIFY2(SyncCrypto::open(
                 cipher, keys, QStringLiteral("devices/id/cursor.json"),
                 first, &opened, &error),
             qPrintable(error));
    QCOMPARE(opened, plain);
}

// 保证长度、magic、块边界、校验值、路径或密钥任一不符都失败，且不会调用解密。
void SyncCryptoTests::openRejectsMalformedInputBeforeDecrypting()
{
    RecordingBlockCipher cipher;
    const QByteArray mainSecret = secret();
    const SyncCrypto::Keys keys
        = SyncCrypto::deriveKeys(mainSecret, QStringLiteral("space-1234567890ab"));
    const QString path = QStringLiteral("devices/id/changes/0000-00000001.json");
    const QByteArray plain = QByteArrayLiteral("payload");
    QByteArray sealed;
    QString error;
    QVERIFY2(SyncCrypto::seal(cipher, keys, path, plain, &sealed, &error),
             qPrintable(error));
    const int baselineDecryptCalls = cipher.decryptCalls;

    const auto expectRejected = [&](const QByteArray& candidate,
                                    const SyncCrypto::Keys& candidateKeys,
                                    const QString& candidatePath) {
        QByteArray opened = QByteArrayLiteral("must stay empty");
        QString candidateError;
        QVERIFY2(!SyncCrypto::open(
                     cipher, candidateKeys, candidatePath, candidate,
                     &opened, &candidateError),
                 "畸形密文不应通过认证");
        QVERIFY(!candidateError.isEmpty());
        QVERIFY(opened.isEmpty());
        QCOMPARE(cipher.decryptCalls, baselineDecryptCalls);
    };

    expectRejected(sealed.left(20), keys, path);

    QByteArray wrongMagic = sealed;
    wrongMagic[0] = 'X';
    expectRejected(wrongMagic, keys, path);

    QByteArray wrongBlock = sealed;
    wrongBlock.remove(4 + 16, 1);
    expectRejected(wrongBlock, keys, path);

    QByteArray wrongTag = sealed;
    wrongTag[wrongTag.size() - 1] = static_cast<char>(
        wrongTag.at(wrongTag.size() - 1) ^ 1);
    expectRejected(wrongTag, keys, path);

    expectRejected(sealed, keys, path + QStringLiteral(".other"));

    const SyncCrypto::Keys otherKeys = SyncCrypto::deriveKeys(
        secret('B'), QStringLiteral("space-1234567890ab"));
    expectRejected(sealed, otherKeys, path);
}

QTEST_GUILESS_MAIN(SyncCryptoTests)
#include "SyncCryptoTests.moc"
