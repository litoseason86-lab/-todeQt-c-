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

    Q_INVOKABLE QVariantList getAllCategories() const;
    Q_INVOKABLE QVariantList getPresetCategories() const;
    Q_INVOKABLE QVariantList getCustomCategories() const;
    Q_INVOKABLE QVariantMap getCategoryById(int id) const;

    Q_INVOKABLE int addCategory(const QString& name, const QString& color);
    Q_INVOKABLE bool updateCategory(int id, const QString& name, const QString& color);
    Q_INVOKABLE bool deleteCategory(int id);

    Q_INVOKABLE bool canDeleteCategory(int id) const;
    Q_INVOKABLE bool categoryNameExists(const QString& name, int excludeId = -1) const;

signals:
    void categoriesChanged();

private:
    explicit CategoryManager(QObject* parent = nullptr);

    QVariantMap categoryFromQuery(const QSqlQuery& query) const;
    QVariantList queryCategories(const QString& sql) const;
    bool isValidColor(const QString& color) const;
};

#endif // CATEGORYMANAGER_H
