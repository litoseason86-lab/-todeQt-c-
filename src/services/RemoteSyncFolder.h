#ifndef REMOTESYNCFOLDER_H
#define REMOTESYNCFOLDER_H

#include "SyncCrypto.h"
#include "SyncFolder.h"
#include "SyncHttpClient.h"

#include <QByteArray>
#include <QHash>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QUrl>

#include <memory>

// 用自建服务器模拟一个同步目录。服务器只保存客户端封装后的密文，
// open() 缓存一次树清单，list() 只读缓存；read/write/remove 才发网络请求。
class RemoteSyncFolder final : public SyncFolder
{
public:
    struct Config {
        QUrl baseUrl;
        QString spaceId;
        QByteArray secret;
    };

    RemoteSyncFolder(Config config, std::shared_ptr<SyncHttpClient> http,
                     std::shared_ptr<SyncBlockCipher> cipher);

    // HTTPS 总是允许；明文 HTTP 只允许本机回环，方便测试和本机调试。
    static bool isAcceptableBaseUrl(const QUrl& url);

    bool open(Error* error) override;
    QString name() const override;
    QString displayPath() const override;
    QStringList list(const QString& relativeDir, Error* error) override;
    bool read(const QString& relativePath, QByteArray* data,
              Error* error) override;
    bool write(const QString& relativePath, const QByteArray& data,
               Error* error) override;
    bool remove(const QString& relativePath, Error* error) override;
    QString uploadProblem(const QString& relativePath) override;
    void cancelPendingIo() override;

private:
    QUrl endpointUrl(const QString& suffix) const;
    bool classifyResponse(const SyncHttpClient::Response& response,
                          bool fileRead, Error* error) const;
    void rememberFile(const QString& relativePath, qint64 encryptedSize);

    Config m_config;
    std::shared_ptr<SyncHttpClient> m_http;
    std::shared_ptr<SyncBlockCipher> m_cipher;
    SyncCrypto::Keys m_keys;
    QSet<QString> m_directories;
    QHash<QString, qint64> m_files;
};

#endif // REMOTESYNCFOLDER_H
