#include "SyncPairing.h"

#include "RemoteSyncFolder.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QJsonValue>
#include <QRandomGenerator>
#include <QRegularExpression>

#include <cstring>

namespace {

const QLatin1String kPrefix("ptsync1.");
const QRegularExpression kSpacePattern(
    QStringLiteral("^[A-Za-z0-9_-]{16,64}$"));

QByteArray randomBytes(int size)
{
    QByteArray result(size, Qt::Uninitialized);
    QRandomGenerator* generator = QRandomGenerator::system();
    for (int offset = 0; offset < size; offset += 4) {
        const quint32 value = generator->generate();
        const char bytes[4] = {
            static_cast<char>((value >> 24) & 0xff),
            static_cast<char>((value >> 16) & 0xff),
            static_cast<char>((value >> 8) & 0xff),
            static_cast<char>(value & 0xff),
        };
        const int count = qMin(4, size - offset);
        std::memcpy(result.data() + offset, bytes, count);
    }
    return result;
}

void setError(QString* target, const QString& message)
{
    if (target) {
        *target = message;
    }
}

QString compactWhitespace(const QString& text)
{
    QString result;
    result.reserve(text.size());
    for (const QChar character : text) {
        if (!character.isSpace()) {
            result.append(character);
        }
    }
    return result;
}

QByteArray decodeBase64Url(const QString& text)
{
    return QByteArray::fromBase64(
        text.toLatin1(),
        QByteArray::Base64UrlEncoding
            | QByteArray::AbortOnBase64DecodingErrors);
}

} // namespace

namespace SyncPairing {

QString encode(const Info& info)
{
    const QJsonObject object{
        {QStringLiteral("u"),
         info.baseUrl.toString(QUrl::FullyEncoded)},
        {QStringLiteral("s"), info.spaceId},
        {QStringLiteral("k"),
         QString::fromLatin1(
             info.secret.toBase64(QByteArray::Base64UrlEncoding
                                 | QByteArray::OmitTrailingEquals))},
    };
    return QString(kPrefix)
        + QString::fromLatin1(
            QJsonDocument(object)
                .toJson(QJsonDocument::Compact)
                .toBase64(QByteArray::Base64UrlEncoding
                          | QByteArray::OmitTrailingEquals));
}

bool decode(const QString& text, Info* info, QString* error)
{
    const QString compact = compactWhitespace(text);
    if (!compact.startsWith(kPrefix)) {
        setError(error, QStringLiteral("这不是番茄Todo 的配对码"));
        return false;
    }
    const QString encoded = compact.mid(kPrefix.size());
    const QByteArray jsonBytes = decodeBase64Url(encoded);
    QJsonParseError parseError;
    const QJsonDocument document
        = QJsonDocument::fromJson(jsonBytes, &parseError);
    if (parseError.error != QJsonParseError::NoError
        || !document.isObject()) {
        setError(error,
                 QStringLiteral("配对码不完整或已损坏，请在 Mac 上重新复制"));
        return false;
    }

    const QJsonObject object = document.object();
    const QString urlText
        = object.value(QStringLiteral("u")).toString();
    const QString spaceId
        = object.value(QStringLiteral("s")).toString();
    const QString secretText
        = object.value(QStringLiteral("k")).toString();
    if (urlText.isEmpty() || spaceId.isEmpty() || secretText.isEmpty()) {
        setError(error,
                 QStringLiteral("配对码不完整或已损坏，请在 Mac 上重新复制"));
        return false;
    }

    const QUrl url(urlText);
    if (!RemoteSyncFolder::isAcceptableBaseUrl(url)) {
        setError(error,
                 QStringLiteral("配对码里的服务器地址不安全（必须是 https）"));
        return false;
    }
    if (kSpacePattern.match(spaceId).hasMatch() == false) {
        setError(error,
                 QStringLiteral("配对码不完整或已损坏，请在 Mac 上重新复制"));
        return false;
    }
    const QByteArray secret = decodeBase64Url(secretText);
    if (secret.size() != 32) {
        setError(error,
                 QStringLiteral("配对码不完整或已损坏，请在 Mac 上重新复制"));
        return false;
    }

    if (info) {
        *info = {url, spaceId, secret};
    }
    setError(error, {});
    return true;
}

QString newSpaceId()
{
    return QString::fromLatin1(randomBytes(16).toHex());
}

QByteArray newSecret()
{
    return randomBytes(32);
}

} // namespace SyncPairing
