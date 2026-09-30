#include "ProviderInstances.h"

#include <QRegularExpression>

namespace ProviderInstances {

QJsonObject of(const QJsonObject& settings, const QString& id, const QString& driver) {
  const QJsonObject instances = settings.value(QLatin1String("providerInstances")).toObject();
  if (instances.contains(id)) return instances.value(id).toObject();
  QJsonObject instance{{QStringLiteral("driver"), driver}};
  if (id != driver) return instance;
  QJsonObject config = settings.value(QLatin1String("providers")).toObject().value(driver).toObject();
  if (config.contains(QLatin1String("enabled"))) instance.insert(QStringLiteral("enabled"), config.take(QStringLiteral("enabled")));
  if (!config.isEmpty()) instance.insert(QStringLiteral("config"), config);
  return instance;
}

QJsonObject with(QJsonObject settings, const QString& id, const QJsonObject& instance) {
  QJsonObject instances = settings.value(QLatin1String("providerInstances")).toObject();
  if (instance.isEmpty()) instances.remove(id);
  else instances.insert(id, instance);
  settings.insert(QStringLiteral("providerInstances"), instances);
  return settings;
}

QJsonObject withConfig(QJsonObject instance, const QString& key, const QJsonValue& value) {
  QJsonObject config = instance.value(QLatin1String("config")).toObject();
  if (value.isNull() || value.isUndefined() || (value.isString() && value.toString().trimmed().isEmpty())) config.remove(key);
  else config.insert(key, value.isString() ? QJsonValue(value.toString().trimmed()) : value);
  if (config.isEmpty()) instance.remove(QStringLiteral("config"));
  else instance.insert(QStringLiteral("config"), config);
  return instance;
}

QSet<QString> taken(const QJsonObject& settings, const QJsonArray& providers) {
  QSet<QString> ids{QStringLiteral("codex"), QStringLiteral("claudeAgent")};
  for (const QString& id : settings.value(QLatin1String("providerInstances")).toObject().keys()) ids.insert(id);
  for (const QString& id : settings.value(QLatin1String("providers")).toObject().keys()) ids.insert(id);
  for (const QJsonValue& provider : providers) ids.insert(provider.toObject().value(QLatin1String("instanceId")).toString());
  ids.remove(QString());
  return ids;
}

QString accent(const QString& color) {
  static const QRegularExpression hex(QStringLiteral("^#[0-9a-fA-F]{6}$"));
  const QString trimmed = color.trimmed();
  return hex.match(trimmed).hasMatch() ? trimmed.toLower() : QString();
}

bool validVariableName(const QString& name) {
  static const QRegularExpression pattern(QStringLiteral("^[a-zA-Z_][a-zA-Z0-9_]*$"));
  return pattern.match(name).hasMatch();
}

}  // namespace ProviderInstances
