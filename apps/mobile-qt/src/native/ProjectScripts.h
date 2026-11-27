#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QString>

// A project's actions as an environment's settings resolve them:
// the project's own list (its `defaultProjectScripts` override), else the scripts its row carries, else
// the environment's `defaultProjectScripts`.
namespace projectScripts {

inline QJsonValue overrideOf(const QJsonObject& settings, const QString& projectId) {
  const QJsonObject entry = settings.value(QLatin1String("projectSettingsOverrides")).toObject().value(projectId).toObject();
  return entry.contains(QLatin1String("defaultProjectScripts")) ? entry.value(QLatin1String("defaultProjectScripts"))
                                                                : QJsonValue(QJsonValue::Undefined);
}

inline QJsonArray resolve(const QJsonObject& settings, const QString& projectId, const QJsonArray& own) {
  const QJsonValue override = overrideOf(settings, projectId);
  if (override.isArray()) return override.toArray();
  const QJsonArray defaults = settings.value(QLatin1String("defaultProjectScripts")).toArray();
  if (settings.value(QLatin1String("projectSettingsFolded")).toBool()) return defaults;
  return own.isEmpty() ? defaults : own;
}

// Whether the project has no list of its own.
inline bool inherits(const QJsonObject& settings, const QString& projectId, const QJsonArray& own) {
  if (overrideOf(settings, projectId).isArray()) return false;
  return settings.value(QLatin1String("projectSettingsFolded")).toBool() || own.isEmpty();
}

}  // namespace projectScripts
