#ifndef CATEGORYMANAGER_H
#define CATEGORYMANAGER_H

#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

class QSqlQuery;

class CategoryManager : public QObject
{
    Q_OBJECT

public:
    static CategoryManager* instance();

    // 科目列表给任务弹窗、科目管理弹窗和统计页面共用。
    Q_INVOKABLE QVariantList getAllCategories() const;
    Q_INVOKABLE QVariantList getPresetCategories() const;
    Q_INVOKABLE QVariantList getCustomCategories() const;
    Q_INVOKABLE QVariantMap getCategoryById(int id) const;

    // 预设科目不能改名或删除，自定义科目才允许增删改。
    Q_INVOKABLE int addCategory(const QString& name, const QString& color);
    Q_INVOKABLE bool updateCategory(int id, const QString& name, const QString& color);
    Q_INVOKABLE bool deleteCategory(int id);

    // canDeleteCategory 只表示 UI 是否显示删除入口；真正删除时仍会再次校验。
    Q_INVOKABLE bool canDeleteCategory(int id) const;
    Q_INVOKABLE bool categoryNameExists(const QString& name, int excludeId = -1) const;

signals:
    void categoriesChanged();
    void operationFailed(const QString& message);

private:
    explicit CategoryManager(QObject* parent = nullptr);

    // 下面这些辅助函数只服务数据库读取和输入校验，不暴露给 QML。
    QVariantMap categoryFromQuery(const QSqlQuery& query) const;
    QVariantList queryCategories(const QString& sql) const;
    bool isValidColor(const QString& color) const;
    void reportFailure(const QString& message) const;
};

#endif // CATEGORYMANAGER_H
