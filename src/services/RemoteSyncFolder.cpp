#include "RemoteSyncFolder.h"

#include "SyncFiles.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QJsonValue>
#include <QStringList>

#include <utility>

namespace {

void setError(SyncFolder::Error* target, SyncFolder::ErrorKind kind,
              const QString& message = {})
{
    if (target) {
        target->kind = kind;
        target->message = message;
    }
}

QString encodedSegment(const QString& value)
{
    return QString::fromLatin1(QUrl::toPercentEncoding(value));
}

QString encodedRelativePath(const QString& relativePath)
{
    const QStringList segments = relativePath.split(QLatin1Char('/'),
                                                     Qt::KeepEmptyParts);
    QStringList encoded;
    encoded.reserve(segments.size());
    for (const QString& segment : segments) {
        if (segment.isEmpty() || segment == QStringLiteral(".")
            || segment == QStringLiteral("..")) {
            return {};
        }
        encoded.append(encodedSegment(segment));
    }
    return encoded.join(QLatin1Char('/'));
}

QString parentOf(const QString& path)
{
    const qsizetype slash = path.lastIndexOf(QLatin1Char('/'));
    return slash < 0 ? QString() : path.left(slash);
}

QString baseNameOf(const QString& path)
{
    return path.mid(path.lastIndexOf(QLatin1Char('/')) + 1);
}

QString errorCodeFromBody(const QByteArray& body)
{
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(body, &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        return {};
    }
    return document.object().value(QStringLiteral("error")).toString();
}

bool validTreePath(const QString& path)
{
    if (path.isEmpty() || path.startsWith(QLatin1Char('/'))
        || path.endsWith(QLatin1Char('/'))
        || path.contains(QLatin1Char('\\'))) {
        return false;
    }
    const QStringList segments = path.split(QLatin1Char('/'));
    if (segments.isEmpty() || segments.size() > 4) {
        return false;
    }
    for (const QString& segment : segments) {
        if (segment.isEmpty() || segment == QStringLiteral(".")
            || segment == QStringLiteral("..")) {
            return false;
        }
    }
    return true;
}

void rememberParents(QSet<QString>* directories, const QString& relativePath)
{
    QString directory = parentOf(relativePath);
    while (!directory.isEmpty()) {
        directories->insert(directory);
        directory = parentOf(directory);
    }
}

} // namespace

RemoteSyncFolder::RemoteSyncFolder(
    Config config, std::shared_ptr<SyncHttpClient> http,
    std::shared_ptr<SyncBlockCipher> cipher)
    : m_config(std::move(config))
    , m_http(std::move(http))
    , m_cipher(std::move(cipher))
    , m_keys(SyncCrypto::deriveKeys(m_config.secret, m_config.spaceId))
{
    m_directories.insert(QString());
}

bool RemoteSyncFolder::isAcceptableBaseUrl(const QUrl& url)
{
    if (!url.isValid() || url.isRelative() || url.host().isEmpty()) {
        return false;
    }
    const QString scheme = url.scheme().toLower();
    if (scheme == QStringLiteral("https")) {
        return true;
    }
    if (scheme != QStringLiteral("http")) {
        return false;
    }
    const QString host = url.host().toLower();
    return host == QStringLiteral("127.0.0.1")
        || host == QStringLiteral("::1")
        || host == QStringLiteral("localhost");
}

QUrl RemoteSyncFolder::endpointUrl(const QString& suffix) const
{
    QUrl url = m_config.baseUrl;
    QString path = url.path(QUrl::FullyEncoded);
    while (path.endsWith(QLatin1Char('/'))) {
        path.chop(1);
    }
    path += QStringLiteral("/v1/spaces/")
        + encodedSegment(m_config.spaceId) + suffix;
    url.setPath(path, QUrl::StrictMode);
    url.setQuery(QString());
    url.setFragment(QString());
    return url;
}

bool RemoteSyncFolder::classifyResponse(
    const SyncHttpClient::Response& response, bool fileRead,
    Error* error) const
{
    if (response.failure == SyncHttpClient::Failure::Cancelled) {
        setError(error, ErrorKind::Io, QStringLiteral("同步已取消"));
        return false;
    }
    if (response.failure == SyncHttpClient::Failure::Timeout) {
        setError(error, ErrorKind::Io,
                 QStringLiteral("同步服务器响应超时"));
        return false;
    }
    if (response.failure == SyncHttpClient::Failure::Network) {
        const QString detail = response.message.isEmpty()
            ? QStringLiteral("网络错误")
            : response.message;
        setError(error, ErrorKind::Io,
                 QStringLiteral("连不上同步服务器：%1").arg(detail));
        return false;
    }

    if (response.status == 200) {
        setError(error, ErrorKind::None);
        return true;
    }
    if (response.status == 401 || response.status == 403) {
        setError(error, ErrorKind::Unavailable,
                 QStringLiteral("同步服务器拒绝了这台设备的配对，请重新配对"));
        return false;
    }
    if (response.status == 404) {
        const QString code = errorCodeFromBody(response.body);
        if (code == QStringLiteral("space_not_found")) {
            setError(error, ErrorKind::Unavailable,
                     QStringLiteral("同步服务器上找不到这个同步空间"));
            return false;
        }
        if (fileRead && code == QStringLiteral("file_not_found")) {
            setError(error, ErrorKind::NotFound);
            return false;
        }
    }
    if (response.status == 413 || response.status == 507) {
        setError(error, ErrorKind::NoSpace,
                 QStringLiteral("同步服务器空间已满或文件过大"));
        return false;
    }
    if (response.status >= 300 && response.status < 400) {
        setError(error, ErrorKind::Unavailable,
                 QStringLiteral("同步服务器地址发生了跳转，没有跟随"));
        return false;
    }
    if (response.status >= 400) {
        setError(error, ErrorKind::Io,
                 QStringLiteral("同步服务器出错（HTTP %1）")
                     .arg(response.status));
        return false;
    }
    setError(error, ErrorKind::Io,
             QStringLiteral("同步服务器返回了意外状态（HTTP %1）")
                 .arg(response.status));
    return false;
}

bool RemoteSyncFolder::open(Error* error)
{
    m_directories.clear();
    m_files.clear();
    if (!isAcceptableBaseUrl(m_config.baseUrl)) {
        setError(error, ErrorKind::Unavailable,
                 QStringLiteral("同步服务器地址不可用：只接受 HTTPS，"
                                "或本机回环地址的 HTTP"));
        return false;
    }
    if (m_config.spaceId.isEmpty()) {
        setError(error, ErrorKind::Unavailable,
                 QStringLiteral("同步空间编号为空"));
        return false;
    }
    if (m_keys.encKey.size() != 32 || m_keys.macKey.size() != 32
        || m_keys.authToken.size() != 32) {
        setError(error, ErrorKind::Unavailable,
                 QStringLiteral("同步配对密钥无效"));
        return false;
    }
    if (!m_http || !m_cipher) {
        setError(error, ErrorKind::Unavailable,
                 QStringLiteral("同步网络或加密组件未配置"));
        return false;
    }

    SyncHttpClient::Request request;
    request.method = QByteArrayLiteral("GET");
    request.url = endpointUrl(QStringLiteral("/tree"));
    request.timeoutMs = 20000;
    request.headers = {
        {QByteArrayLiteral("Authorization"),
         QByteArrayLiteral("Bearer ") + SyncCrypto::authTokenText(m_keys).toUtf8()},
        {QByteArrayLiteral("User-Agent"),
         QByteArrayLiteral("PomodoroTodo-sync/1")},
    };
    const SyncHttpClient::Response response = m_http->send(request);
    if (!classifyResponse(response, false, error)) {
        return false;
    }

    QJsonParseError parseError;
    const QJsonDocument document
        = QJsonDocument::fromJson(response.body, &parseError);
    if (parseError.error != QJsonParseError::NoError
        || !document.isObject()) {
        setError(error, ErrorKind::Io,
                 QStringLiteral("同步服务器返回的目录清单不是 JSON"));
        return false;
    }
    const QJsonValue entriesValue
        = document.object().value(QStringLiteral("entries"));
    if (!entriesValue.isArray()) {
        setError(error, ErrorKind::Io,
                 QStringLiteral("同步服务器返回的目录清单缺少 entries"));
        return false;
    }

    QSet<QString> directories;
    directories.insert(QString());
    QHash<QString, qint64> files;
    for (const QJsonValue& value : entriesValue.toArray()) {
        if (!value.isObject()) {
            setError(error, ErrorKind::Io,
                     QStringLiteral("同步服务器返回的目录项不合法"));
            return false;
        }
        const QJsonObject entry = value.toObject();
        const QString path = entry.value(QStringLiteral("path")).toString();
        const QString type = entry.value(QStringLiteral("type")).toString();
        if (!validTreePath(path)) {
            setError(error, ErrorKind::Io,
                     QStringLiteral("同步服务器返回了非法路径"));
            return false;
        }
        rememberParents(&directories, path);
        if (type == QStringLiteral("dir")) {
            directories.insert(path);
        } else if (type == QStringLiteral("file")) {
            const QJsonValue sizeValue = entry.value(QStringLiteral("size"));
            if (!sizeValue.isDouble() || sizeValue.toDouble() < 0) {
                setError(error, ErrorKind::Io,
                         QStringLiteral("同步服务器返回的文件大小不合法"));
                return false;
            }
            files.insert(path, static_cast<qint64>(sizeValue.toDouble()));
        } else {
            setError(error, ErrorKind::Io,
                     QStringLiteral("同步服务器返回了未知目录项类型"));
            return false;
        }
    }
    m_directories = directories;
    m_files = files;
    setError(error, ErrorKind::None);
    return true;
}

QString RemoteSyncFolder::name() const
{
    return SyncFiles::defaultFolderName();
}

QString RemoteSyncFolder::displayPath() const
{
    return m_config.baseUrl.host();
}

QStringList RemoteSyncFolder::list(const QString& relativeDir, Error* error)
{
    QString directory = relativeDir;
    while (directory.endsWith(QLatin1Char('/'))) {
        directory.chop(1);
    }
    if (!m_directories.contains(directory)) {
        setError(error, ErrorKind::NotFound,
                 QStringLiteral("同步目录不存在：%1").arg(relativeDir));
        return {};
    }

    QSet<QString> names;
    for (const QString& path : m_directories) {
        if (!path.isEmpty() && parentOf(path) == directory) {
            names.insert(baseNameOf(path));
        }
    }
    for (auto it = m_files.cbegin(); it != m_files.cend(); ++it) {
        if (parentOf(it.key()) == directory) {
            names.insert(baseNameOf(it.key()));
        }
    }
    setError(error, ErrorKind::None);
    return names.values();
}

bool RemoteSyncFolder::read(const QString& relativePath, QByteArray* data,
                            Error* error)
{
    if (data) {
        data->clear();
    }
    if (!m_http || !m_cipher) {
        setError(error, ErrorKind::Io,
                 QStringLiteral("同步网络或加密组件未配置"));
        return false;
    }
    const QString encodedPath = encodedRelativePath(relativePath);
    if (encodedPath.isEmpty()) {
        setError(error, ErrorKind::Io,
                 QStringLiteral("同步文件路径无效"));
        return false;
    }
    const qint64 budget = SyncFiles::maxBudgetForPath(relativePath);
    if (budget <= 0) {
        setError(error, ErrorKind::Io,
                 QStringLiteral("拒绝读取未知同步文件: %1").arg(relativePath));
        return false;
    }

    SyncHttpClient::Request request;
    request.method = QByteArrayLiteral("GET");
    request.url = endpointUrl(QStringLiteral("/files/") + encodedPath);
    request.timeoutMs = 45000;
    request.headers = {
        {QByteArrayLiteral("Authorization"),
         QByteArrayLiteral("Bearer ") + SyncCrypto::authTokenText(m_keys).toUtf8()},
        {QByteArrayLiteral("User-Agent"),
         QByteArrayLiteral("PomodoroTodo-sync/1")},
    };
    const SyncHttpClient::Response response = m_http->send(request);
    if (!classifyResponse(response, true, error)) {
        return false;
    }
    if (static_cast<qint64>(response.body.size())
        > budget + 4 + 16 + 16 + 32) {
        setError(error, ErrorKind::Io,
                 QStringLiteral("文件大小超出预算上限: %1").arg(relativePath));
        return false;
    }

    QByteArray plain;
    QString cryptoError;
    if (!SyncCrypto::open(*m_cipher, m_keys, relativePath, response.body,
                          &plain, &cryptoError)) {
        setError(error, ErrorKind::Io,
                 QStringLiteral("同步文件校验不通过：%1").arg(relativePath));
        return false;
    }
    if (static_cast<qint64>(plain.size()) > budget) {
        setError(error, ErrorKind::Io,
                 QStringLiteral("文件大小超出预算上限: %1").arg(relativePath));
        return false;
    }
    if (data) {
        *data = plain;
    }
    setError(error, ErrorKind::None);
    return true;
}

bool RemoteSyncFolder::write(const QString& relativePath,
                             const QByteArray& data, Error* error)
{
    if (!m_http || !m_cipher) {
        setError(error, ErrorKind::Io,
                 QStringLiteral("同步网络或加密组件未配置"));
        return false;
    }
    const QString encodedPath = encodedRelativePath(relativePath);
    if (encodedPath.isEmpty()) {
        setError(error, ErrorKind::Io,
                 QStringLiteral("同步文件路径无效"));
        return false;
    }
    QByteArray sealed;
    QString cryptoError;
    if (!SyncCrypto::seal(*m_cipher, m_keys, relativePath, data,
                          &sealed, &cryptoError)) {
        setError(error, ErrorKind::Io, cryptoError);
        return false;
    }

    SyncHttpClient::Request request;
    request.method = QByteArrayLiteral("PUT");
    request.url = endpointUrl(QStringLiteral("/files/") + encodedPath);
    request.timeoutMs = 45000;
    request.body = sealed;
    request.headers = {
        {QByteArrayLiteral("Authorization"),
         QByteArrayLiteral("Bearer ") + SyncCrypto::authTokenText(m_keys).toUtf8()},
        {QByteArrayLiteral("User-Agent"),
         QByteArrayLiteral("PomodoroTodo-sync/1")},
        {QByteArrayLiteral("Content-Type"),
         QByteArrayLiteral("application/octet-stream")},
    };
    const SyncHttpClient::Response response = m_http->send(request);
    if (!classifyResponse(response, false, error)) {
        return false;
    }
    rememberFile(relativePath, sealed.size());
    return true;
}

bool RemoteSyncFolder::remove(const QString& relativePath, Error* error)
{
    if (!m_http || !m_cipher) {
        setError(error, ErrorKind::Io,
                 QStringLiteral("同步网络或加密组件未配置"));
        return false;
    }
    const QString encodedPath = encodedRelativePath(relativePath);
    if (encodedPath.isEmpty()) {
        setError(error, ErrorKind::Io,
                 QStringLiteral("同步文件路径无效"));
        return false;
    }

    SyncHttpClient::Request request;
    request.method = QByteArrayLiteral("DELETE");
    request.url = endpointUrl(QStringLiteral("/files/") + encodedPath);
    request.timeoutMs = 45000;
    request.headers = {
        {QByteArrayLiteral("Authorization"),
         QByteArrayLiteral("Bearer ") + SyncCrypto::authTokenText(m_keys).toUtf8()},
        {QByteArrayLiteral("User-Agent"),
         QByteArrayLiteral("PomodoroTodo-sync/1")},
    };
    const SyncHttpClient::Response response = m_http->send(request);
    if (!classifyResponse(response, false, error)) {
        // 服务器对不存在的文件通常返回 200；若未来改成 file_not_found，
        // 删除的既有语义仍然是把“已经不在了”当作成功。
        if (error && error->kind == ErrorKind::NotFound) {
            m_files.remove(relativePath);
            setError(error, ErrorKind::None);
            return true;
        }
        return false;
    }
    m_files.remove(relativePath);
    return true;
}

QString RemoteSyncFolder::uploadProblem(const QString& relativePath)
{
    Q_UNUSED(relativePath);
    return {};
}

void RemoteSyncFolder::cancelPendingIo()
{
    if (m_http) {
        m_http->cancelAll();
    }
}

void RemoteSyncFolder::rememberFile(const QString& relativePath,
                                    qint64 encryptedSize)
{
    m_files.insert(relativePath, encryptedSize);
    rememberParents(&m_directories, relativePath);
}
