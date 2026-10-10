#pragma once
#include <QObject>
#include <QSettings>
#include <QStringList>

// iPad 界面选择只写本机偏好，不经过 AppSettings 或同步设置白名单；两个界面入口共用此键。
class IPadUiPreferences final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool isIPad READ isIPad CONSTANT)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
public:
    explicit IPadUiPreferences(bool isIPad, QObject *parent = nullptr) : QObject(parent), m_isIPad(isIPad) {}
    bool isIPad() const { return m_isIPad; }
    QString error() const { return m_error; }
    static bool shouldUseNative(bool isIPad, const QStringList &arguments, const QByteArray &forced) {
        if (!isIPad) return false;
        if (arguments.contains(QStringLiteral("--ipad-qml-ui"))) return false;
        if (arguments.contains(QStringLiteral("--ipad-native-ui"))) return true;
        if (forced == "0") return false;
        if (forced == "1") return true;
        return QSettings().value(QStringLiteral("ipad/nativeUI"), true).toBool();
    }
    static bool writeNativeUI(bool value, QString *error = nullptr) {
        QSettings settings;
        const QString key = QStringLiteral("ipad/nativeUI");
        const bool existed = settings.contains(key);
        const QVariant previous = settings.value(key);
        settings.setValue(key, value);
        settings.sync();
        if (settings.status() == QSettings::NoError) return true;
        // 写失败时还原内存偏好，避免界面宣告下次切换但磁盘仍留着旧值。
        if (existed) settings.setValue(key, previous); else settings.remove(key);
        settings.sync();
        if (error) *error = QStringLiteral("界面设置保存失败，请重试");
        return false;
    }
    Q_INVOKABLE bool setNativeUI(bool value) {
        if (!m_isIPad) return false;
        m_error.clear();
        const bool saved = writeNativeUI(value, &m_error);
        emit errorChanged();
        return saved;
    }
signals:
    void errorChanged();
private:
    bool m_isIPad;
    QString m_error;
};
